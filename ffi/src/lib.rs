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

use std::collections::VecDeque;
use std::ffi::{c_char, CStr, CString};
use std::os::raw::c_void;
use std::ptr;
use std::sync::{Arc, Mutex, OnceLock};

use futures::StreamExt;
use serde::Deserialize;
use tokio::runtime::Runtime;
use tokio::task::JoinHandle;

use chromiumoxide::cdp::js_protocol::runtime::{AddBindingParams, EventBindingCalled};
use chromiumoxide::Browser;

// ── shared runtime + thread-local strings ─────────────────────────────────────

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

// ── event row + pure (browser-independent) helpers ────────────────────────────

/// One captured event, shim-internal (Mojo gets the TSV form).
#[derive(Debug, Clone, PartialEq)]
struct Row {
    kind: String,
    target: String,
    role: String,
    name: String,
    value: String,
    redacted: bool,
    ts_ms: i64,
}

/// The JSON the injected `__rec` binding sends per event.
#[derive(Deserialize)]
struct Wire {
    kind: String,
    #[serde(default)]
    target: String,
    #[serde(default)]
    role: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    value: String,
    #[serde(default)]
    redacted: bool,
    #[serde(default)]
    ts: i64,
}

/// Parse one binding payload (`{kind,target,role,name,value,redacted,ts}`) to a
/// `Row`. Returns None on malformed JSON. Defence-in-depth: even if the JS missed
/// it, blank out the value of anything still flagged `redacted`.
fn json_to_row(json: &str) -> Option<Row> {
    let w: Wire = serde_json::from_str(json).ok()?;
    let value = if w.redacted { String::new() } else { w.value };
    Some(Row {
        kind: w.kind,
        target: w.target,
        role: w.role,
        name: w.name,
        value,
        redacted: w.redacted,
        ts_ms: w.ts,
    })
}

/// Render one `Row` as a TSV line (trailing `\n`). Tabs/newlines inside fields
/// become spaces so the row framing the Mojo parser relies on stays intact.
fn row_to_tsv(r: &Row) -> String {
    let clean = |s: &str| s.replace(['\t', '\n', '\r'], " ");
    format!(
        "{}\t{}\t{}\t{}\t{}\t{}\t{}\n",
        clean(&r.kind),
        clean(&r.target),
        clean(&r.role),
        clean(&r.name),
        clean(&r.value),
        if r.redacted { "1" } else { "0" },
        r.ts_ms,
    )
}

fn push_json(queue: &Arc<Mutex<VecDeque<Row>>>, json: &str) {
    if let Some(row) = json_to_row(json) {
        if let Ok(mut q) = queue.lock() {
            q.push_back(row);
        }
    }
}

// ── the recorder handle ───────────────────────────────────────────────────────

/// Live recording session. Holds the CDP connection alive (`_browser`) and the
/// background tasks (the CDP handler pump + the binding-event drain). The
/// queue is shared with the drain task; `rec_poll` empties it.
struct Recorder {
    queue: Arc<Mutex<VecDeque<Row>>>,
    _browser: Browser,
    tasks: Vec<JoinHandle<()>>,
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

    let built = rt().block_on(async move { connect_and_capture(&url, q).await });

    match built {
        Ok((browser, tasks)) => Box::into_raw(Box::new(Recorder {
            queue,
            _browser: browser,
            tasks,
        })) as *mut c_void,
        Err(e) => {
            set_err(format!("rec_start: {e}"));
            ptr::null_mut()
        }
    }
}

/// Connect to the running Chrome, add the `__rec` binding, inject the capture
/// script into the current + future documents, and spawn the pumps. Returns the
/// live `Browser` (kept alive by the caller) and the background task handles.
async fn connect_and_capture(
    url: &str,
    queue: Arc<Mutex<VecDeque<Row>>>,
) -> Result<(Browser, Vec<JoinHandle<()>>), String> {
    let (browser, mut handler) = Browser::connect(url).await.map_err(|e| e.to_string())?;

    // Drive the CDP connection: the handler future must be polled for anything
    // (commands, events) to make progress.
    let handler_task = tokio::spawn(async move { while handler.next().await.is_some() {} });

    // Attach to whatever page is open (the session the user is operating).
    let pages = browser.pages().await.map_err(|e| e.to_string())?;
    let page = pages.into_iter().next().ok_or("no open page in target")?;

    // Runtime.addBinding("__rec") exposes window.__rec(json) -> a bindingCalled event.
    page.execute(AddBindingParams::new("__rec"))
        .await
        .map_err(|e| e.to_string())?;
    // Inject for future navigations AND the current document.
    page.evaluate_on_new_document(INJECT_JS)
        .await
        .map_err(|e| e.to_string())?;
    let _ = page.evaluate(INJECT_JS).await; // best-effort for the live doc

    // Drain bindingCalled events into the queue.
    let mut events = page
        .event_listener::<EventBindingCalled>()
        .await
        .map_err(|e| e.to_string())?;
    let drain_task = tokio::spawn(async move {
        while let Some(ev) = events.next().await {
            if ev.name == "__rec" {
                push_json(&queue, &ev.payload);
            }
        }
    });

    Ok((browser, vec![handler_task, drain_task]))
}

/// Drain queued events into a TSV batch (NUL-terminated, shim-owned). Empty when
/// nothing is pending.
///
/// # Safety
/// `handle` must be a live pointer from `rec_start`.
#[no_mangle]
pub unsafe extern "C" fn rec_poll(handle: *mut c_void) -> *const c_char {
    let mut out = String::new();
    if let Some(rec) = (handle as *mut Recorder).as_ref() {
        if let Ok(mut q) = rec.queue.lock() {
            while let Some(r) = q.pop_front() {
                out.push_str(&row_to_tsv(&r));
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
    let rec = Box::from_raw(handle as *mut Recorder);
    for t in &rec.tasks {
        t.abort();
    }
    // `rec` (and the Browser it owns) drops here, tearing down the CDP attachment.
}

// ── unit tests for the pure, browser-independent logic ────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_to_row_parses_a_click() {
        let r = json_to_row(
            r#"{"kind":"click","target":"@e7","role":"link","name":"Statements","value":"","redacted":false,"ts":200}"#,
        )
        .unwrap();
        assert_eq!(r.kind, "click");
        assert_eq!(r.target, "@e7");
        assert_eq!(r.name, "Statements");
        assert_eq!(r.ts_ms, 200);
        assert!(!r.redacted);
    }

    #[test]
    fn json_to_row_blanks_redacted_value() {
        // Defence in depth: a redacted=true row must never carry a value, even
        // if one slipped through.
        let r = json_to_row(
            r##"{"kind":"input","target":"#p","role":"password","name":"Password","value":"hunter2","redacted":true,"ts":1}"##,
        )
        .unwrap();
        assert!(r.redacted);
        assert_eq!(r.value, "");
    }

    #[test]
    fn json_to_row_rejects_garbage() {
        assert!(json_to_row("not json").is_none());
        assert!(json_to_row("{}").is_none()); // missing required `kind`
    }

    #[test]
    fn row_to_tsv_is_framed_and_clean() {
        let r = Row {
            kind: "input".into(),
            target: "#e".into(),
            role: "textbox".into(),
            name: "Sea\trch\nbox".into(), // embedded tab/newline must be neutralised
            value: "a@b.com".into(),
            redacted: false,
            ts_ms: 42,
        };
        let line = row_to_tsv(&r);
        assert!(line.ends_with('\n'));
        assert_eq!(line.matches('\t').count(), 6, "exactly 6 field separators");
        assert!(!line[..line.len() - 1].contains('\n'), "no stray newlines");
        assert!(line.contains("Sea rch box"));
        assert!(line.contains("\t0\t42\n"), "redacted flag + ts tail");
    }

    #[test]
    fn push_json_enqueues_valid_only() {
        let q: Arc<Mutex<VecDeque<Row>>> = Arc::new(Mutex::new(VecDeque::new()));
        push_json(&q, r#"{"kind":"submit","ts":5}"#);
        push_json(&q, "garbage");
        assert_eq!(q.lock().unwrap().len(), 1);
        assert_eq!(q.lock().unwrap()[0].kind, "submit");
    }
}
