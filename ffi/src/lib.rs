//! C-ABI CDP recorder shim for the browser-native.mojo recorder seam.
//!
//! agent-browser is a one-way driver: it DRIVES Chrome over CDP and can stream
//! pixels out, but never reports the human's own input. This shim closes that
//! gap. It attaches to the same Chrome (a second CDP client, via chromiumoxide),
//! injects a capture-phase JS listener on every document, and turns the user's
//! click / type / navigate actions into structured rows that Mojo drains over a
//! tiny synchronous C ABI:
//!
//!   void* rec_start(const char* cdp_url)   // attach + inject; 0 on failure
//!   char* rec_poll (void* handle)          // drain queued events as TSV (UTF-8,
//!                                           //   NUL-terminated, shim-owned)
//!   void  rec_stop (void* handle)          // detach + free
//!   char* rec_last_error(void)             // thread-local diagnostic
//!
//! TSV row (matches browser_native.record.parse_events), one event per line:
//!   kind \t target \t role \t name \t value \t redacted(0|1) \t ts_ms \n
//!
//! PRIVACY: redaction happens at CAPTURE. The injected JS never sends the value
//! of a sensitive field (type=password, autocomplete one-time-code, etc.) — it
//! sets redacted=1 and an empty value. Mojo's redact_event reinforces this.
//!
//! STATUS: skeleton. The C ABI + JS contract are final; the chromiumoxide calls
//! marked `TODO(api)` need pinning to the exact crate version. Build opt-in via
//! `pixi run ffi` (first build pulls chromiumoxide; needs a Chrome to exercise).

use std::collections::VecDeque;
use std::ffi::{c_char, CStr, CString};
use std::os::raw::c_void;
use std::ptr;
use std::sync::{Arc, Mutex, OnceLock};

use tokio::runtime::Runtime;

// ── shared runtime + thread-local last error ──────────────────────────────────

fn rt() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

thread_local! {
    static LAST_ERR: std::cell::RefCell<CString> =
        std::cell::RefCell::new(CString::new("").unwrap());
    // rec_poll returns a pointer into this; valid until the next poll on the
    // same thread (the Mojo side copies it immediately).
    static POLL_BUF: std::cell::RefCell<CString> =
        std::cell::RefCell::new(CString::new("").unwrap());
}

fn set_err(msg: impl Into<String>) {
    let s = msg.into();
    LAST_ERR.with(|e| {
        *e.borrow_mut() = CString::new(s).unwrap_or_else(|_| CString::new("err").unwrap());
    });
}

/// NUL-terminated message for the most recent failure on this thread. Do not free.
#[no_mangle]
pub extern "C" fn rec_last_error() -> *const c_char {
    LAST_ERR.with(|e| e.borrow().as_ptr())
}

// ── the recorder handle ───────────────────────────────────────────────────────

/// One captured event, shim-internal (Mojo gets the TSV form).
struct Row {
    kind: String,
    target: String,
    role: String,
    name: String,
    value: String,
    redacted: bool,
    ts_ms: i64,
}

/// Live recording session. The background task pushes `Row`s into `queue`;
/// `rec_poll` drains it.
struct Recorder {
    queue: Arc<Mutex<VecDeque<Row>>>,
    // Kept so Drop tears the CDP attachment + task down.
    task: Option<tokio::task::JoinHandle<()>>,
}

/// The capture-phase listener injected into every document. It computes a stable
/// target, the accessible name/role, withholds sensitive values, and ships each
/// event to the native side through the `__rec` binding (CDP Runtime.addBinding).
const INJECT_JS: &str = r#"
(() => {
  if (window.__recInstalled) return; window.__recInstalled = true;
  const SENSITIVE = el => {
    const t = (el.type || '').toLowerCase();
    if (t === 'password') return true;
    const ac = (el.getAttribute && el.getAttribute('autocomplete') || '').toLowerCase();
    if (ac.includes('one-time-code') || ac.includes('cc-csc')) return true;
    const hint = ((el.name||'') + ' ' + (el.getAttribute&&el.getAttribute('aria-label')||'')).toLowerCase();
    return /pass|otp|cvv|cvc|ssn|account number|card number|routing/.test(hint);
  };
  // A short, reasonably-stable selector for replay (id > name > nth-of-type path).
  const sel = el => {
    if (!el || el.nodeType !== 1) return '';
    if (el.id) return '#' + el.id;
    if (el.name) return el.tagName.toLowerCase() + '[name="' + el.name + '"]';
    let p = el, parts = [];
    while (p && p.nodeType === 1 && parts.length < 4) {
      let s = p.tagName.toLowerCase();
      const sibs = p.parentNode ? [...p.parentNode.children].filter(c => c.tagName === p.tagName) : [];
      if (sibs.length > 1) s += ':nth-of-type(' + (sibs.indexOf(p)+1) + ')';
      parts.unshift(s); p = p.parentElement;
    }
    return parts.join(' > ');
  };
  const name = el => (el.getAttribute && (el.getAttribute('aria-label') || el.getAttribute('placeholder')))
                  || (el.innerText || el.value || '').trim().slice(0, 80) || '';
  const role = el => (el.getAttribute && el.getAttribute('role'))
                  || ({INPUT:(el.type||'textbox'), A:'link', BUTTON:'button', SELECT:'select'}[el.tagName] || el.tagName.toLowerCase());
  const send = (kind, el, rawValue) => {
    const sensitive = el && el.tagName === 'INPUT' && SENSITIVE(el);
    window.__rec(JSON.stringify({
      kind, target: sel(el), role: el ? role(el) : '', name: el ? name(el) : location.href,
      value: sensitive ? '' : (rawValue || ''), redacted: !!sensitive, ts: Date.now()
    }));
  };
  document.addEventListener('click', e => send('click', e.target), true);
  document.addEventListener('change', e => {
    const el = e.target;
    if (el.tagName === 'SELECT') send('select', el, el.value);
    else send('input', el, el.value);
  }, true);
  document.addEventListener('submit', e => send('submit', e.target), true);
  // Initial navigation marker.
  window.__rec(JSON.stringify({kind:'navigate', target:'', role:'', name: location.href, value:'', redacted:false, ts: Date.now()}));
})();
"#;

/// Attach to the Chrome at `cdp_url` (the WebSocket debugger URL of the browser
/// agent-browser launched), inject the recorder, and start capturing.
///
/// # Safety
/// `cdp_url` must be a valid NUL-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn rec_start(cdp_url: *const c_char) -> *mut c_void {
    if cdp_url.is_null() {
        set_err("rec_start: null cdp_url");
        return ptr::null_mut();
    }
    let url = match CStr::from_ptr(cdp_url).to_str() {
        Ok(s) => s.to_owned(),
        Err(_) => {
            set_err("rec_start: cdp_url not UTF-8");
            return ptr::null_mut();
        }
    };

    let queue: Arc<Mutex<VecDeque<Row>>> = Arc::new(Mutex::new(VecDeque::new()));
    let q = queue.clone();

    // Connect + wire up the capture pipeline on the shared runtime. The async
    // body returns a JoinHandle for the event pump.
    let task = rt().block_on(async move {
        // TODO(api): exact chromiumoxide calls depend on the crate version.
        //   let (browser, mut handler) = Browser::connect(&url).await?;
        //   tokio::spawn(async move { while handler.next().await.is_some() {} });
        //   let page = browser.pages().await?.into_iter().next()...;
        //   page.execute(AddScriptToEvaluateOnNewDocumentParams { source: INJECT_JS, .. }).await?;
        //   page.execute(AddBindingParams { name: "__rec".into(), .. }).await?;   // Runtime.addBinding
        //   page.evaluate(INJECT_JS).await?;                                       // inject into the live page too
        //   let mut binding_events = page.event_listener::<EventBindingCalled>().await?;
        //   tokio::spawn(async move {
        //       while let Some(ev) = binding_events.next().await {
        //           if ev.name == "__rec" { push_json(&q, &ev.payload); }
        //       }
        //   })
        let _ = (&url, INJECT_JS); // silence unused until the calls above land
        let _ = &q;
        set_err("rec_start: chromiumoxide wiring is a skeleton — fill the TODO(api) block");
        tokio::spawn(async {})
    });

    let rec = Box::new(Recorder {
        queue,
        task: Some(task),
    });
    Box::into_raw(rec) as *mut c_void
}

/// Map the JSON `{kind,target,role,name,value,redacted,ts}` the JS binding sent
/// into a `Row`. (Hand-rolled extraction keeps the dep tree tiny; swap for
/// serde_json if you'd rather.)
#[allow(dead_code)]
fn push_json(queue: &Arc<Mutex<VecDeque<Row>>>, _json: &str) {
    // TODO: parse `_json` (serde_json::from_str) into a Row and push.
    let _ = queue;
}

/// Drain queued events into a TSV batch (NUL-terminated, shim-owned). Empty when
/// nothing is pending. Tabs/newlines in field text are replaced with spaces so
/// the row framing stays intact.
///
/// # Safety
/// `handle` must be a live pointer from `rec_start`.
#[no_mangle]
pub unsafe extern "C" fn rec_poll(handle: *mut c_void) -> *const c_char {
    let clean = |s: &str| s.replace(['\t', '\n', '\r'], " ");
    let mut out = String::new();
    if let Some(rec) = (handle as *mut Recorder).as_ref() {
        if let Ok(mut q) = rec.queue.lock() {
            while let Some(r) = q.pop_front() {
                out.push_str(&format!(
                    "{}\t{}\t{}\t{}\t{}\t{}\t{}\n",
                    clean(&r.kind),
                    clean(&r.target),
                    clean(&r.role),
                    clean(&r.name),
                    clean(&r.value),
                    if r.redacted { "1" } else { "0" },
                    r.ts_ms,
                ));
            }
        }
    }
    POLL_BUF.with(|b| {
        *b.borrow_mut() = CString::new(out).unwrap_or_else(|_| CString::new("").unwrap());
        b.borrow().as_ptr()
    })
}

/// Detach and free the session.
///
/// # Safety
/// `handle` must be a live pointer from `rec_start`, not used afterwards.
#[no_mangle]
pub unsafe extern "C" fn rec_stop(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    let mut rec = Box::from_raw(handle as *mut Recorder);
    if let Some(t) = rec.task.take() {
        t.abort();
    }
    // Browser/connection drop here tears down the CDP attachment.
}
