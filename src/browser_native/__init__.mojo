"""browser_native — a native, agent-friendly wrapper around `agent-browser`.

A Mojo port of fitchmultz/pi-agent-browser-native. The upstream
[`agent-browser`](https://agent-browser.dev/) CLI drives a real browser; this
package gives it a typed, agent-shaped face: a caller builds one of five
structured requests, and the pipeline compiles it to a single upstream
invocation, runs it, redacts any secrets out of the output, and folds the result
into a small *bounded* set of categories an agent can branch on.

    from browser_native import args_request, semantic_request, run

    var r = run(args_request(["open", "https://example.com"]))
    print(r.summary)          # "agent_browser open ok (navigation)"
    print(r.result_category)  # "navigation"

    var s = run(semantic_request("click", "text", "Learn"))
    if not s.ok:
        print(s.failure_category, s.summary)   # e.g. "stale_ref … take a fresh snapshot"

The stages are public too — `compile_plan` (request → argv+stdin), `run_shell`
(execute), `categorize` (output → verdict) — and the first and third are pure,
so the whole front and back of the wrapper is testable without `agent-browser`
installed.
"""

# Input modes + factories.
from browser_native.request import (
    BrowserRequest,
    SemanticAction,
    JobStep,
    QaCheck,
    ElectronAction,
    args_request,
    semantic_request,
    job_request,
    qa_request,
    electron_request,
)

# Compilation (request → upstream Plan) + shell rendering.
from browser_native.compile import (
    Plan,
    compile_plan,
    semantic_argv,
    electron_argv,
    build_batch_json,
    json_escape,
    shell_quote,
    shell_command,
)

# Secret redaction.
from browser_native.redact import redact, is_sensitive_key, REDACTED

# Execution.
from browser_native.proc import ProcOutput, run_shell

# Result categorization (+ the bounded category vocabulary).
from browser_native.result import (
    BrowserResult,
    categorize,
    success_category,
    failure_category,
    trim_body,
    CAT_SNAPSHOT,
    CAT_NAVIGATION,
    CAT_ACTION,
    CAT_ARTIFACT,
    CAT_INFO,
    CAT_EMPTY,
    FAIL_NOT_INSTALLED,
    FAIL_TIMEOUT,
    FAIL_STALE_REF,
    FAIL_NAVIGATION,
    FAIL_USAGE,
    FAIL_EXEC,
)

# The end-to-end pipeline.
from browser_native.run import run, DEFAULT_BIN

# Recorder seam (observe the user's actions → replayable job). The pure parsing /
# mapping / redaction is usable without the FFI shim; `Recorder` needs `ffi/`.
from browser_native.record import (
    Event,
    Recorder,
    parse_events,
    record_to_job,
    event_to_step,
    is_sensitive_field,
    redact_event,
    EV_CLICK,
    EV_INPUT,
    EV_NAVIGATE,
    EV_SUBMIT,
    EV_SELECT,
    EV_KEY,
    REDACTED_FILL,
)
