"""request — the structured input a caller hands to `browser_native`.

The upstream `agent-browser` CLI is flexible but stringly-typed: every call is a
bare argv that an agent has to assemble (and mis-assemble) by hand. This module
gives that surface a *typed* face. A caller picks exactly one of five input
modes and the rest of the pipeline (`compile` → `run` → `categorize`) turns it
into a single upstream invocation:

  * **args**     — direct CLI passthrough (the most flexible escape hatch).
  * **semantic** — one role/text/label/selector-targeted action.
  * **job**      — a constrained multi-step workflow (open/click/fill/…).
  * **qa**       — a URL smoke-check (open, assert text, screenshot).
  * **electron** — desktop-app lifecycle (discover/launch/attach/cleanup).

Mirrors the input-mode contract of fitchmultz/pi-agent-browser-native, ported to
Mojo. Build a request with one of the `*_request` factories rather than poking
the fields directly.
"""


# ── input-mode payloads ───────────────────────────────────────────────────────


@fieldwise_init
struct SemanticAction(Copyable, Movable):
    """One stable-locator browser action.

    `action`  — click | fill | hover | select | press | check
    `locator` — text | role | label | placeholder | selector | ref
    `value`   — the locator's target (the visible text, role name, css
                selector, or an `@eN` snapshot ref)
    `input`   — only for fill/select/press: the text to type, the option to
                select, or the key to press. Empty otherwise.
    """

    var action: String
    var locator: String
    var value: String
    var input: String


@fieldwise_init
struct JobStep(Copyable, Movable):
    """One step of a constrained `job` workflow.

    `op`    — open | click | fill | wait | assert | screenshot
    `arg`   — url (open) / text-or-ref (click) / selector (fill) / ms (wait) /
              expected text (assert) / path (screenshot)
    `input` — the text to type for `fill`; empty for every other op.
    """

    var op: String
    var arg: String
    var input: String


@fieldwise_init
struct QaCheck(Copyable, Movable):
    """A one-shot smoke check: open `url`, assert `expected_text` is present (if
    given), and capture a screenshot to `screenshot_path` (if given)."""

    var url: String
    var expected_text: String
    var screenshot_path: String


@fieldwise_init
struct ElectronAction(Copyable, Movable):
    """Desktop-app lifecycle.

    `action`   — discover | launch | attach | cleanup
    `app_name` — the app to launch/attach (e.g. "Visual Studio Code"); empty for
                 discover/cleanup.
    """

    var action: String
    var app_name: String


# ── the request ───────────────────────────────────────────────────────────────


struct BrowserRequest(Copyable, Movable):
    """A single typed `browser_native` call. Exactly one of the five modes is
    active; `mode` names which. The shared fields (`session_mode`, `profile`,
    `stdin`, `output_path`) apply across modes."""

    var mode: String  # "args" | "semantic" | "job" | "qa" | "electron"
    var args: List[String]  # mode == "args": verbatim upstream argv
    var semantic: SemanticAction  # mode == "semantic"
    var job: List[JobStep]  # mode == "job"
    var qa: QaCheck  # mode == "qa"
    var electron: ElectronAction  # mode == "electron"
    var session_mode: String  # "auto" | "fresh"
    var profile: String  # browser profile name; "" == default
    var stdin: String  # piped to upstream stdin (passwords, eval src, batch)
    var output_path: String  # where results/artifacts should land; "" == none

    def __init__(out self, mode: String):
        """An empty request in `mode`; the factories below fill in the rest."""
        self.mode = mode
        self.args = List[String]()
        self.semantic = SemanticAction("", "", "", "")
        self.job = List[JobStep]()
        self.qa = QaCheck("", "", "")
        self.electron = ElectronAction("", "")
        self.session_mode = "auto"
        self.profile = ""
        self.stdin = ""
        self.output_path = ""


# ── factories ─────────────────────────────────────────────────────────────────


def args_request(
    args: List[String], stdin: String = "", session_mode: String = "auto"
) -> BrowserRequest:
    """Direct upstream passthrough: run `agent-browser <args...>` verbatim."""
    var r = BrowserRequest("args")
    r.args = args.copy()
    r.stdin = stdin
    r.session_mode = session_mode
    return r^


def semantic_request(
    action: String, locator: String, value: String, input: String = ""
) -> BrowserRequest:
    """A single stable-locator action, e.g. click the element whose text is
    "Learn", or fill the `#email` selector with "a@b.com"."""
    var r = BrowserRequest("semantic")
    r.semantic = SemanticAction(action, locator, value, input)
    return r^


def job_request(steps: List[JobStep]) -> BrowserRequest:
    """A constrained multi-step workflow compiled to a single upstream batch."""
    var r = BrowserRequest("job")
    r.job = steps.copy()
    return r^


def qa_request(
    url: String, expected_text: String = "", screenshot_path: String = ""
) -> BrowserRequest:
    """A URL smoke check: open, optionally assert text, optionally screenshot.
    """
    var r = BrowserRequest("qa")
    r.qa = QaCheck(url, expected_text, screenshot_path)
    return r^


def electron_request(action: String, app_name: String = "") -> BrowserRequest:
    """Desktop-app lifecycle (discover/launch/attach/cleanup)."""
    var r = BrowserRequest("electron")
    r.electron = ElectronAction(action, app_name)
    return r^
