"""compile — turn a typed `BrowserRequest` into one upstream invocation.

The output is a `Plan`: the argv to hand the `agent-browser` binary plus the
bytes (if any) to pipe to its stdin. Every input mode collapses to this one
shape, so `run` has a single thing to execute regardless of how the caller
phrased the request.

The compilation is a *pure* function of the request — no process is spawned, no
filesystem touched — which is what makes the whole front half of the wrapper
unit-testable without `agent-browser` installed.

Ported from the runtime/argv-planning layer of
fitchmultz/pi-agent-browser-native.
"""

from browser_native.request import (
    BrowserRequest,
    SemanticAction,
    JobStep,
    QaCheck,
    ElectronAction,
)


@fieldwise_init
struct Plan(Copyable, Movable):
    """A fully-resolved upstream invocation: `argv` (excluding the program name)
    plus `stdin` ("" when nothing is piped)."""

    var argv: List[String]
    var stdin: String


# ── shared flags (profile / session) ──────────────────────────────────────────


def _session_flags(req: BrowserRequest) -> List[String]:
    """The `--profile` / `--fresh` prefix common to every mode."""
    var flags = List[String]()
    if req.profile != "":
        flags.append("--profile")
        flags.append(req.profile)
    if req.session_mode == "fresh":
        flags.append("--fresh")
    return flags^


# ── semantic action → argv ────────────────────────────────────────────────────


def _locator_flag(locator: String) -> String:
    """Map a semantic locator name to its upstream `--flag`. An unknown locator
    falls back to `--selector` (the css escape hatch)."""
    if locator == "text":
        return "--text"
    if locator == "role":
        return "--role"
    if locator == "label":
        return "--label"
    if locator == "placeholder":
        return "--placeholder"
    if locator == "ref":
        return "--ref"
    return "--selector"


def semantic_argv(a: SemanticAction) -> List[String]:
    """Compile one `SemanticAction` to argv, e.g.
    `click --text Learn` or `fill --selector #email a@b.com`."""
    var argv = List[String]()
    argv.append(a.action)
    argv.append(_locator_flag(a.locator))
    argv.append(a.value)
    # fill/select/press carry a trailing payload (the text/option/key).
    if a.input != "":
        argv.append(a.input)
    return argv^


# ── job / qa → batch JSON (piped to stdin) ────────────────────────────────────


def json_escape(s: String) -> String:
    """Escape a String for embedding inside a JSON string literal."""
    var out = String("")
    for cp in s.codepoint_slices():
        var ch = String(cp)
        if ch == '"':
            out += '\\"'
        elif ch == "\\":
            out += "\\\\"
        elif ch == "\n":
            out += "\\n"
        elif ch == "\r":
            out += "\\r"
        elif ch == "\t":
            out += "\\t"
        else:
            out += ch
    return out^


def _json_array(items: List[String]) -> String:
    """Render `items` as a JSON array of strings."""
    var out = String("[")
    for i in range(len(items)):
        if i > 0:
            out += ","
        out += '"' + json_escape(items[i]) + '"'
    out += "]"
    return out^


def _job_step_argv(step: JobStep) -> List[String]:
    """One job step as an upstream argv fragment (the inner array of a batch).
    """
    var argv = List[String]()
    argv.append(step.op)
    if step.op == "fill":
        # fill targets a selector (arg) and types a value (input).
        argv.append(step.arg)
        argv.append(step.input)
    elif step.arg != "":
        argv.append(step.arg)
    return argv^


def build_batch_json(steps: List[JobStep]) -> String:
    """Render a job as the JSON `[[op, ...], ...]` that upstream `batch` reads
    from stdin."""
    var out = String("[")
    for i in range(len(steps)):
        if i > 0:
            out += ","
        out += _json_array(_job_step_argv(steps[i]))
    out += "]"
    return out^


def _qa_steps(qa: QaCheck) -> List[JobStep]:
    """Lower a QA smoke check to the job steps it stands for: open, wait for
    readiness, assert the expected text, screenshot."""
    var steps = List[JobStep]()
    steps.append(JobStep("open", qa.url, ""))
    steps.append(JobStep("wait", "load", ""))
    if qa.expected_text != "":
        steps.append(JobStep("assert", qa.expected_text, ""))
    if qa.screenshot_path != "":
        steps.append(JobStep("screenshot", qa.screenshot_path, ""))
    return steps^


# ── electron → argv ───────────────────────────────────────────────────────────


def electron_argv(e: ElectronAction) -> List[String]:
    """Compile an electron lifecycle action, e.g. `electron launch "VS Code"`.
    """
    var argv = List[String]()
    argv.append("electron")
    argv.append(e.action)
    if e.app_name != "":
        argv.append(e.app_name)
    return argv^


# ── the entry point ───────────────────────────────────────────────────────────


def compile_plan(req: BrowserRequest) raises -> Plan:
    """Compile any `BrowserRequest` to the single upstream `Plan` that runs it.
    """
    var argv = _session_flags(req)
    var stdin = req.stdin

    if req.mode == "args":
        for i in range(len(req.args)):
            argv.append(req.args[i])
    elif req.mode == "semantic":
        var sa = semantic_argv(req.semantic)
        for i in range(len(sa)):
            argv.append(sa[i])
    elif req.mode == "job":
        argv.append("batch")
        stdin = build_batch_json(req.job)
    elif req.mode == "qa":
        argv.append("batch")
        stdin = build_batch_json(_qa_steps(req.qa))
    elif req.mode == "electron":
        var ea = electron_argv(req.electron)
        for i in range(len(ea)):
            argv.append(ea[i])
    else:
        raise Error("browser_native: unknown request mode '" + req.mode + "'")

    if req.output_path != "":
        argv.append("--output")
        argv.append(req.output_path)

    return Plan(argv^, stdin)


# ── shell rendering (for popen) ───────────────────────────────────────────────


def shell_quote(s: String) -> String:
    """Single-quote `s` for a POSIX shell, escaping embedded single quotes via
    the `'\\''` idiom. Safe for arbitrary content (urls, selectors, json)."""
    var out = String("'")
    for cp in s.codepoint_slices():
        var ch = String(cp)
        if ch == "'":
            out += "'\\''"
        else:
            out += ch
    out += "'"
    return out^


def shell_command(bin: String, plan: Plan) -> String:
    """Render `plan` as one `/bin/sh -c` line: `printf %s '<stdin>' | bin args…`
    when there is stdin, otherwise just `bin args…`. stderr is folded into
    stdout (`2>&1`) so failure diagnostics survive into the captured output."""
    var cmd = shell_quote(bin)
    for i in range(len(plan.argv)):
        cmd += " " + shell_quote(plan.argv[i])
    cmd += " 2>&1"
    if plan.stdin != "":
        return "printf '%s' " + shell_quote(plan.stdin) + " | " + cmd
    return cmd^
