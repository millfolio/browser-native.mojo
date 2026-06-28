"""result — turn raw upstream output into a bounded, agent-friendly verdict.

An agent branching on free-form CLI text is brittle. This module collapses an
`agent-browser` run into a small, *closed* set of categories so the calling
agent can switch on `result_category` / `failure_category` reliably, plus a
short prose `summary` (with recovery guidance on failure) and a redacted,
size-bounded `details` body.

The category vocabulary is intentionally tiny and fixed — adding a new outcome
is a deliberate edit here, never an emergent string the agent has to guess at.

Ported from the results/error-categorization layer of
fitchmultz/pi-agent-browser-native.
"""

from browser_native.redact import redact
from browser_native.proc import ProcOutput

# ── bounded categories ────────────────────────────────────────────────────────

# result_category — set when the run succeeded (ok == True).
comptime CAT_SNAPSHOT: String = "snapshot"  # a page snapshot / dom read
comptime CAT_NAVIGATION: String = "navigation"  # open / goto / back
comptime CAT_ACTION: String = "action"  # click / fill / hover / press
comptime CAT_ARTIFACT: String = "artifact"  # screenshot / download / record
comptime CAT_INFO: String = "info"  # anything else with output
comptime CAT_EMPTY: String = "empty"  # succeeded but produced nothing

# failure_category — set when the run failed (ok == False).
comptime FAIL_NOT_INSTALLED: String = "not_installed"  # binary missing on PATH
comptime FAIL_TIMEOUT: String = "timeout"
comptime FAIL_STALE_REF: String = "stale_ref"  # @eN ref no longer valid
comptime FAIL_NAVIGATION: String = "navigation_error"
comptime FAIL_USAGE: String = "usage_error"  # bad args / unknown command
comptime FAIL_EXEC: String = "exec_error"  # nonzero exit, uncategorized

# Body cap (bytes). Beyond this the details are head+tail trimmed and `spilled`
# is set — the agent gets the shape without drowning its context window.
comptime BODY_LIMIT: Int = 8000
comptime BODY_HEAD: Int = 6000
comptime BODY_TAIL: Int = 1500


@fieldwise_init
struct BrowserResult(Copyable, Movable):
    """The bounded verdict of one `browser_native` run."""

    var ok: Bool
    var result_category: String  # one of CAT_*; "" on failure
    var failure_category: String  # one of FAIL_*; "" on success
    var summary: String  # one-line, model-facing, with recovery guidance
    var details: String  # redacted + size-bounded body
    var spilled: Bool  # body was trimmed (oversized)
    var exit_code: Int


# ── helpers ───────────────────────────────────────────────────────────────────


def _subcommand(argv: List[String]) -> String:
    """The first non-flag token of `argv` — the upstream subcommand that drives
    the success category (open/snapshot/click/…)."""
    for i in range(len(argv)):
        if not argv[i].startswith("-"):
            return argv[i]
    return ""


def success_category(argv: List[String], body_len: Int) -> String:
    """Pick a CAT_* for a zero-exit run from the subcommand it ran."""
    if body_len == 0:
        return CAT_EMPTY
    var cmd = _subcommand(argv)
    if cmd == "snapshot" or cmd == "dom" or cmd == "eval" or cmd == "read":
        return CAT_SNAPSHOT
    if cmd == "open" or cmd == "goto" or cmd == "back" or cmd == "forward":
        return CAT_NAVIGATION
    if (
        cmd == "click"
        or cmd == "fill"
        or cmd == "hover"
        or cmd == "press"
        or cmd == "select"
        or cmd == "check"
        or cmd == "type"
    ):
        return CAT_ACTION
    if (
        cmd == "screenshot"
        or cmd == "download"
        or cmd == "record"
        or cmd == "pdf"
    ):
        return CAT_ARTIFACT
    return CAT_INFO


def failure_category(body: String) -> String:
    """Classify a nonzero-exit run by scanning its (lowercased) output for the
    telltale phrase of each known failure mode."""
    var b = body.lower()
    # popen runs through /bin/sh, so a missing binary surfaces here (exit 127)
    # rather than as a NULL popen — fold it back to the not-installed category.
    if b.find("command not found") != -1 or b.find("no such file") != -1:
        return FAIL_NOT_INSTALLED
    if b.find("timeout") != -1 or b.find("timed out") != -1:
        return FAIL_TIMEOUT
    if (
        b.find("stale") != -1
        or b.find("no element") != -1
        or b.find("element not found") != -1
        or b.find("ref not found") != -1
        or b.find("not found for ref") != -1
    ):
        return FAIL_STALE_REF
    if (
        b.find("net::") != -1
        or b.find("navigation") != -1
        or b.find("err_") != -1
    ):
        return FAIL_NAVIGATION
    if (
        b.find("usage:") != -1
        or b.find("unknown command") != -1
        or b.find("unknown option") != -1
        or b.find("invalid argument") != -1
    ):
        return FAIL_USAGE
    return FAIL_EXEC


def _recovery_hint(fail: String) -> String:
    """A short, fixed recovery suggestion per failure category."""
    if fail == FAIL_NOT_INSTALLED:
        return (
            " — install the upstream `agent-browser` CLI and ensure it is on"
            " PATH (see https://agent-browser.dev/)."
        )
    if fail == FAIL_TIMEOUT:
        return " — the page never settled; retry, or `wait` for a later state."
    if fail == FAIL_STALE_REF:
        return (
            " — `@eN` refs are tied to a snapshot; take a fresh `snapshot -i`"
            " and re-target."
        )
    if fail == FAIL_NAVIGATION:
        return " — the navigation failed; check the URL and connectivity."
    if fail == FAIL_USAGE:
        return (
            " — the upstream rejected the arguments; check the command shape."
        )
    return " — the command exited nonzero; inspect details."


def trim_body(body: String) -> String:
    """Cap an oversized body to head+tail with an elision marker between."""
    if body.byte_length() <= BODY_LIMIT:
        return body
    var head = String(body[byte=:BODY_HEAD])
    var tail = String(body[byte = body.byte_length() - BODY_TAIL :])
    var dropped = body.byte_length() - BODY_HEAD - BODY_TAIL
    return (
        head
        + "\n… ["
        + String(dropped)
        + " bytes elided — full output spilled] …\n"
        + tail
    )


# ── the entry point ───────────────────────────────────────────────────────────


def categorize(argv: List[String], proc: ProcOutput) -> BrowserResult:
    """Fold a finished process into a bounded `BrowserResult`."""
    # The binary never even ran (popen failed → not on PATH).
    if not proc.ran:
        return BrowserResult(
            ok=False,
            result_category="",
            failure_category=FAIL_NOT_INSTALLED,
            summary=(
                "agent_browser could not run"
                + _recovery_hint(FAIL_NOT_INSTALLED)
            ),
            details="",
            spilled=False,
            exit_code=-1,
        )

    var body = redact(proc.stdout)
    var spilled = body.byte_length() > BODY_LIMIT
    var details = trim_body(body)

    if proc.exit_code == 0:
        var cat = success_category(argv, body.byte_length())
        var summary = "agent_browser " + _subcommand(argv) + " ok (" + cat + ")"
        if cat == CAT_EMPTY:
            summary += " — no output"
        return BrowserResult(
            ok=True,
            result_category=cat,
            failure_category="",
            summary=summary,
            details=details,
            spilled=spilled,
            exit_code=0,
        )

    var fail = failure_category(body)
    var summary = (
        "agent_browser "
        + _subcommand(argv)
        + " failed ["
        + fail
        + "]"
        + _recovery_hint(fail)
    )
    return BrowserResult(
        ok=False,
        result_category="",
        failure_category=fail,
        summary=summary,
        details=details,
        spilled=spilled,
        exit_code=proc.exit_code,
    )
