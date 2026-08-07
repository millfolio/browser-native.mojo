"""record — the recorder seam: observe the *user's* actions, emit replayable jobs.

`browser_native`'s command modes DRIVE a browser (you → page). Recording is the
opposite direction (page → you): a live stream of the human's own click / type /
navigate events, captured from a session the user is operating by hand (e.g. a
bank login, completing MFA themselves). The captured stream maps onto the SAME
`JobStep` vocabulary the `job` mode already replays — so this module is the
"record" half of record-once / replay-many, the recorder whose output is the job
format we already execute.

How the events arrive
---------------------
The upstream `agent-browser` engine is one-way (it drives + streams pixels, but
never reports the user's input). So the live-event channel is a thin Rust
`cdylib` — `ffi/` in this repo — that attaches to the same Chrome over CDP,
injects a capture-phase JS listener, and hands structured events across a C ABI.
This Mojo side is the FFI binding (mirrors the lancedb.mojo shim pattern) plus
the PURE event→JobStep mapping and the capture-time redaction policy.

Wire contract (Rust `rec_poll` → Mojo), one event per line, tab-separated:

    kind <TAB> target <TAB> role <TAB> name <TAB> value <TAB> redacted(0|1) <TAB> ts_ms <NL>

`value` is ALREADY masked by the shim for sensitive fields (`redacted=1`); the
Mojo side reinforces that policy in `redact_event` (defence in depth — never let
a typed password/OTP/account number out of the recorder).
"""

from std.ffi import OwnedDLHandle
from std.os import getenv
from std.memory import UnsafePointer

from browser_native.request import JobStep
from browser_native.redact import is_sensitive_key, REDACTED

# ── event vocabulary ──────────────────────────────────────────────────────────

comptime EV_CLICK: String = "click"
comptime EV_INPUT: String = "input"  # a settled value typed into a field
comptime EV_NAVIGATE: String = "navigate"  # the user went to a URL
comptime EV_SUBMIT: String = "submit"  # a form submit
comptime EV_SELECT: String = "select"  # an <option> chosen
comptime EV_KEY: String = "key"  # a notable keypress (Enter/Tab); usually noise

# Sentinel placed in a redacted fill's `input`: the replay layer must NOT type
# this — it signals "prompt the human for this field at replay time" (passwords,
# OTPs). Keeps the recorded job free of secrets while marking where they go.
comptime REDACTED_FILL: String = "<redacted:prompt-at-replay>"


@fieldwise_init
struct Event(Copyable, Movable):
    """One observed user action.

    `kind`     — one of EV_*.
    `target`   — a stable element ref/selector the replay can re-resolve.
    `role`     — accessibility role (button / textbox / link / …).
    `name`     — accessible name / visible text ("Download statement"), or the
                 URL for EV_NAVIGATE.
    `value`    — typed value / chosen option; already masked when `redacted`.
    `redacted` — True when `value` was withheld (sensitive field).
    `ts_ms`    — capture timestamp (ms), for ordering / debounce.
    """

    var kind: String
    var target: String
    var role: String
    var name: String
    var value: String
    var redacted: Bool
    var ts_ms: Int


# ── pure: wire parsing ────────────────────────────────────────────────────────


def _atoi(s: String) -> Int:
    """Lenient non-negative integer parse (digits only; junk → 0)."""
    var n = 0
    var any = False
    for cp in s.codepoint_slices():
        var ch = String(cp)
        if ch >= "0" and ch <= "9":
            n = n * 10 + (ord(ch) - ord("0"))
            any = True
        else:
            break
    return n if any else 0


def parse_events(wire: String) -> List[Event]:
    """Parse the shim's TSV batch (see module docstring) into `Event`s. Blank
    lines and malformed rows (<7 fields) are skipped."""
    var out = List[Event]()
    var lines = wire.split("\n")
    for i in range(len(lines)):
        var line = String(lines[i])
        if line.byte_length() == 0:
            continue
        var f = line.split("\t")
        if len(f) < 7:
            continue
        out.append(
            Event(
                kind=String(f[0]),
                target=String(f[1]),
                role=String(f[2]),
                name=String(f[3]),
                value=String(f[4]),
                redacted=String(f[5]) == "1",
                ts_ms=_atoi(String(f[6])),
            )
        )
    return out^


# ── pure: capture-time redaction (defence in depth) ───────────────────────────


def is_sensitive_field(e: Event) -> Bool:
    """True if this field looks like it holds a secret — password / OTP / CVV /
    SSN / account number — by role or accessible name. Reuses the redaction key
    list and adds the input-specific tells."""
    if e.role == "password":
        return True
    var n = e.name.strip().lower()
    if (
        n.find("otp") != -1
        or n.find("one-time") != -1
        or n.find("passcode") != -1
        or n.find("cvv") != -1
        or n.find("cvc") != -1
        or n.find("ssn") != -1
        or n.find("social security") != -1
        or n.find("account number") != -1
        or n.find("card number") != -1
        or n.find("routing") != -1
    ):
        return True
    return is_sensitive_key(e.name)


def redact_event(e: Event) -> Event:
    """Return `e` with its value masked if the field is sensitive (even when the
    shim didn't already flag it). The recorder must never surface secrets."""
    if e.kind != EV_INPUT and e.kind != EV_SELECT:
        return e.copy()
    if e.redacted or is_sensitive_field(e):
        return Event(
            kind=e.kind,
            target=e.target,
            role=e.role,
            name=e.name,
            value=REDACTED,
            redacted=True,
            ts_ms=e.ts_ms,
        )
    return e.copy()


# ── pure: event → JobStep mapping ─────────────────────────────────────────────


def _locator(e: Event) -> String:
    """Pick the replay locator: prefer the stable ref/selector the shim emitted,
    fall back to the visible name."""
    if e.target != "":
        return e.target
    return e.name


def event_to_step(e_in: Event) -> List[JobStep]:
    """Map one (redacted) event to 0+ replay `JobStep`s. Returns a list because
    some events (noise keys) map to nothing."""
    var e = redact_event(e_in)
    var steps = List[JobStep]()
    if e.kind == EV_NAVIGATE:
        var url = e.name if e.name != "" else e.value
        steps.append(JobStep("open", url, ""))
    elif e.kind == EV_CLICK or e.kind == EV_SUBMIT:
        steps.append(JobStep("click", _locator(e), ""))
    elif e.kind == EV_INPUT or e.kind == EV_SELECT:
        # A redacted field round-trips as a marker: replay prompts the human
        # instead of typing a stored secret.
        var fill_value = REDACTED_FILL if e.redacted else e.value
        steps.append(JobStep("fill", _locator(e), fill_value))
    # EV_KEY and unknown kinds: dropped as noise.
    return steps^


def record_to_job(events: List[Event]) -> List[JobStep]:
    """Fold a captured event stream into a replayable `job` (the same step list
    `compile_plan` turns into an upstream `batch`). Consecutive duplicate fills
    on the same target are coalesced to the last (debounce keystroke spam)."""
    var steps = List[JobStep]()
    for i in range(len(events)):
        var produced = event_to_step(events[i])
        for j in range(len(produced)):
            var s = produced[j].copy()
            # Coalesce: a fill that re-targets the same field as the previous
            # step replaces it (settle on the final typed value).
            var n = len(steps)
            if (
                s.op == "fill"
                and n > 0
                and steps[n - 1].op == "fill"
                and steps[n - 1].arg == s.arg
            ):
                steps[n - 1] = s^
            else:
                steps.append(s^)
    return steps^


# ── FFI: the live recorder over the Rust CDP shim ─────────────────────────────
#
# Mirrors the lancedb.mojo OwnedDLHandle pattern. The shim (ffi/, a chromiumoxide
# cdylib) exposes a tiny C ABI:
#   int*  rec_start(const char* cdp_url)      -> opaque session handle, 0 on fail
#   char* rec_poll(void* handle)              -> NUL-terminated TSV batch (drains)
#   void  rec_stop(void* handle)
#   char* rec_last_error(void)                -> thread-local diagnostic
# The recorder ATTACHES to the same Chrome `agent-browser` already drives (a
# second CDP client), so driving/replay and observation share one browser.


def _find_lib() -> String:
    """Path to the recorder cdylib: `$CONDA_PREFIX/lib` (built by ffi/build.sh),
    else `build/` for a bare checkout. Mirrors lancedb.mojo._find_lib."""
    var ext = String("dylib")  # ffi/build.sh emits .so on Linux
    var prefix = getenv("CONDA_PREFIX", "")
    if prefix == "":
        return String("build/libbrowsernativerec.") + ext
    return prefix + "/lib/libbrowsernativerec." + ext


def _cstr(s: String) -> List[UInt8]:
    """A NUL-terminated byte buffer for `s`, to pass as a C `const char*`."""
    var b = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        b.append(src[i])
    b.append(0)
    return b^


def _read_cstr(p: UnsafePointer[UInt8, MutAnyOrigin]) -> String:
    """Copy a NUL-terminated C string (shim-owned, valid until next poll)."""
    var out = String("")
    var i = 0
    while p[i] != 0 and i < (1 << 22):  # 4 MiB cap
        out += chr(Int(p[i]))
        i += 1
    return out^


struct Recorder(Movable):
    """A live capture of one human-operated browser session, over the Rust CDP
    shim. Construct with the CDP endpoint of the Chrome `agent-browser` launched
    (e.g. `ws://127.0.0.1:<port>/...` or its `--session` socket); poll for the
    user's actions; `to_job()` when done. Requires the shim (`pixi run ffi`)."""

    var lib: OwnedDLHandle
    var handle: Int  # *mut c_void session; 0 once stopped
    var events: List[Event]

    def __init__(out self, cdp_url: String) raises:
        self.lib = OwnedDLHandle(_find_lib())
        self.events = List[Event]()
        var url_c = _cstr(cdp_url)
        var start = self.lib.get_function[Int]("rec_start")
        self.handle = start(Int(url_c.unsafe_ptr()))
        _ = url_c^  # keep the buffer mapped across the C call
        if self.handle == 0:
            raise Error("recorder.start: " + _last_error(self.lib))

    def poll(mut self) raises -> Int:
        """Drain newly-captured events from the shim into `self.events`; returns
        how many were appended. Call on a cadence while the user works."""
        var f = self.lib.get_function[UnsafePointer[UInt8, MutAnyOrigin]](
            "rec_poll"
        )
        var batch = parse_events(_read_cstr(f(self.handle)))
        var added = len(batch)
        for i in range(added):
            self.events.append(batch[i])
        return added

    def to_job(self) -> List[JobStep]:
        """The replayable `job` for everything captured so far."""
        return record_to_job(self.events)

    def stop(mut self) raises:
        if self.handle != 0:
            var f = self.lib.get_function[NoneType]("rec_stop")
            f(self.handle)
            self.handle = 0

    def __del__(deinit self):
        # Free the session while `self.lib` is still mapped.
        # get_function raises if the symbol is missing; a destructor can't
        # propagate that, so treat a missing symbol as a no-op.
        if self.handle != 0:
            var f = self.lib.get_function[NoneType]("rec_stop")
            f(self.handle)


def _last_error(read lib: OwnedDLHandle) -> String:
    var func = lib.get_function[UnsafePointer[UInt8, MutAnyOrigin]](
        "rec_last_error"
    )
    return _read_cstr(func())
