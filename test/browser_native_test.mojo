"""Unit tests for browser_native.

Everything here exercises the *pure* stages — request → argv/stdin compilation,
secret redaction, and output categorization — so the suite runs green with no
`agent-browser` binary installed. The one impure call (`run_shell` over a real
`echo`) lives at the end and only checks the popen plumbing, not the engine.
"""

from browser_native import (
    args_request,
    semantic_request,
    job_request,
    qa_request,
    electron_request,
    JobStep,
    compile_plan,
    semantic_argv,
    build_batch_json,
    json_escape,
    shell_quote,
    shell_command,
    redact,
    is_sensitive_key,
    categorize,
    success_category,
    failure_category,
    trim_body,
    ProcOutput,
    BrowserResult,
    CAT_NAVIGATION,
    CAT_ACTION,
    CAT_SNAPSHOT,
    CAT_ARTIFACT,
    CAT_EMPTY,
    FAIL_TIMEOUT,
    FAIL_STALE_REF,
    FAIL_USAGE,
    FAIL_NOT_INSTALLED,
)
from browser_native.proc import run_shell


def _expect(cond: Bool, msg: String) raises:
    if not cond:
        raise Error("FAIL: " + msg)
    print("ok:", msg)


def _join(items: List[String]) -> String:
    var s = String("")
    for i in range(len(items)):
        if i > 0:
            s += " "
        s += items[i]
    return s^


# ── compile: args / semantic / job / qa / electron ────────────────────────────


def test_compile_args() raises:
    var argv = List[String]()
    argv.append("open")
    argv.append("https://example.com")
    var plan = compile_plan(args_request(argv))
    _expect(_join(plan.argv) == "open https://example.com", "args passthrough")
    _expect(plan.stdin == "", "args has no stdin")


def test_compile_session_flags() raises:
    var argv = List[String]()
    argv.append("open")
    argv.append("https://example.com")
    var r = args_request(argv, "", "fresh")
    r.profile = "Profile 1"
    var plan = compile_plan(r)
    _expect(
        _join(plan.argv)
        == "--profile Profile 1 --fresh open https://example.com",
        "profile + fresh flags prefix the argv",
    )


def test_compile_semantic_click() raises:
    var plan = compile_plan(semantic_request("click", "text", "Learn"))
    _expect(_join(plan.argv) == "click --text Learn", "semantic click by text")


def test_compile_semantic_fill() raises:
    var plan = compile_plan(
        semantic_request("fill", "selector", "#email", "a@b.com")
    )
    _expect(
        _join(plan.argv) == "fill --selector #email a@b.com",
        "semantic fill by selector with input",
    )


def test_compile_semantic_ref_fallback() raises:
    # Unknown locator falls back to --selector.
    var av = semantic_argv(semantic_request("click", "weird", "x").semantic)
    _expect(_join(av) == "click --selector x", "unknown locator → --selector")
    # ref locator is explicit.
    var av2 = semantic_argv(semantic_request("click", "ref", "@e7").semantic)
    _expect(_join(av2) == "click --ref @e7", "ref locator → --ref")


def test_compile_job_batch() raises:
    var steps = List[JobStep]()
    steps.append(JobStep("open", "https://example.com", ""))
    steps.append(JobStep("fill", "#email", "a@b.com"))
    steps.append(JobStep("click", "Submit", ""))
    var plan = compile_plan(job_request(steps))
    _expect(_join(plan.argv) == "batch", "job runs via batch")
    _expect(
        plan.stdin
        == '[["open","https://example.com"],["fill","#email","a@b.com"],["click","Submit"]]',
        "job batch json shape",
    )


def test_compile_qa_batch() raises:
    var plan = compile_plan(
        qa_request("https://example.com", "Welcome", "s.png")
    )
    _expect(_join(plan.argv) == "batch", "qa runs via batch")
    _expect(
        plan.stdin
        == '[["open","https://example.com"],["wait","load"],["assert","Welcome"],["screenshot","s.png"]]',
        "qa lowers to open/wait/assert/screenshot",
    )


def test_compile_qa_minimal() raises:
    var plan = compile_plan(qa_request("https://example.com"))
    _expect(
        plan.stdin == '[["open","https://example.com"],["wait","load"]]',
        "qa without expected/screenshot omits those steps",
    )


def test_compile_electron() raises:
    var plan = compile_plan(electron_request("launch", "Visual Studio Code"))
    _expect(
        _join(plan.argv) == "electron launch Visual Studio Code",
        "electron launch argv",
    )


def test_compile_output_path() raises:
    var r = args_request(List[String]())
    r.args.append("snapshot")
    r.output_path = "/tmp/out.txt"
    var plan = compile_plan(r)
    _expect(
        _join(plan.argv) == "snapshot --output /tmp/out.txt",
        "output_path appends --output",
    )


# ── json escaping ─────────────────────────────────────────────────────────────


def test_json_escape() raises:
    _expect(json_escape('he said "hi"') == 'he said \\"hi\\"', "escape quotes")
    _expect(json_escape("a\\b") == "a\\\\b", "escape backslash")
    _expect(json_escape("line1\nline2") == "line1\\nline2", "escape newline")


# ── shell quoting ─────────────────────────────────────────────────────────────


def test_shell_quote() raises:
    _expect(shell_quote("simple") == "'simple'", "plain single-quoted")
    _expect(shell_quote("a b") == "'a b'", "spaces preserved inside quotes")
    _expect(
        shell_quote("it's") == "'it'\\''s'", "embedded single quote escaped"
    )


def test_shell_command_with_stdin() raises:
    var steps = List[JobStep]()
    steps.append(JobStep("open", "https://x.com", ""))
    var plan = compile_plan(job_request(steps))
    var cmd = shell_command("agent-browser", plan)
    _expect(cmd.startswith("printf '%s' "), "stdin piped via printf")
    _expect(cmd.find("| 'agent-browser' 'batch' 2>&1") != -1, "pipes into bin")


def test_shell_command_no_stdin() raises:
    var argv = List[String]()
    argv.append("open")
    argv.append("https://x.com")
    var cmd = shell_command("agent-browser", compile_plan(args_request(argv)))
    _expect(
        cmd == "'agent-browser' 'open' 'https://x.com' 2>&1",
        "no stdin → bare command with 2>&1",
    )


# ── redaction ─────────────────────────────────────────────────────────────────


def test_is_sensitive_key() raises:
    _expect(is_sensitive_key("password"), "password is sensitive")
    _expect(is_sensitive_key("  API_KEY "), "api_key (case/space) is sensitive")
    _expect(is_sensitive_key("Set-Cookie"), "set-cookie is sensitive")
    _expect(not is_sensitive_key("title"), "title is not sensitive")
    _expect(not is_sensitive_key("url"), "url is not sensitive")


def test_redact_key_value() raises:
    var got = redact("password: hunter2")
    _expect(got == "password: «redacted»", "colon value masked")
    var got2 = redact("api_key=sk-abcdef123456")
    _expect(got2 == "api_key= «redacted»", "equals value masked")


def test_redact_preserves_benign() raises:
    var got = redact("title: Example Domain")
    _expect(got == "title: Example Domain", "benign line untouched")


def test_redact_bearer() raises:
    var got = redact("Authorization: Bearer abc.def.ghi")
    # 'authorization' is itself a sensitive key, so the whole value is masked.
    _expect(got == "Authorization: «redacted»", "authorization line masked")
    var got2 = redact("X-Trace: Bearer tok_live_secret")
    _expect(got2 == "X-Trace: Bearer «redacted»", "bearer token masked inline")


def test_redact_multiline() raises:
    var got = redact("title: Home\npassword: s3cr3t\nfooter: bye")
    _expect(
        got == "title: Home\npassword: «redacted»\nfooter: bye",
        "only the sensitive line is masked across lines",
    )


# ── categorization ────────────────────────────────────────────────────────────


def test_success_category() raises:
    var open_argv = List[String]()
    open_argv.append("open")
    _expect(
        success_category(open_argv, 42) == CAT_NAVIGATION, "open → navigation"
    )

    var click_argv = List[String]()
    click_argv.append("click")
    click_argv.append("--text")
    click_argv.append("Go")
    _expect(success_category(click_argv, 10) == CAT_ACTION, "click → action")

    var snap_argv = List[String]()
    snap_argv.append("snapshot")
    _expect(success_category(snap_argv, 99) == CAT_SNAPSHOT, "snapshot → snap")

    var shot_argv = List[String]()
    shot_argv.append("screenshot")
    _expect(success_category(shot_argv, 5) == CAT_ARTIFACT, "screenshot → art")

    _expect(success_category(open_argv, 0) == CAT_EMPTY, "empty body → empty")


def test_failure_category() raises:
    _expect(
        failure_category("Error: navigation timeout of 30000ms exceeded")
        == FAIL_TIMEOUT,
        "timeout detected",
    )
    _expect(
        failure_category("stale element reference: @e3 not found")
        == FAIL_STALE_REF,
        "stale ref detected",
    )
    _expect(
        failure_category("usage: agent-browser <command>") == FAIL_USAGE,
        "usage error detected",
    )
    _expect(
        failure_category("sh: agent-browser: command not found")
        == FAIL_NOT_INSTALLED,
        "missing binary (exit 127) → not_installed",
    )


def test_categorize_success() raises:
    var argv = List[String]()
    argv.append("open")
    argv.append("https://example.com")
    var proc = ProcOutput("Navigated to https://example.com", 0, True)
    var res = categorize(argv, proc)
    _expect(res.ok, "success is ok")
    _expect(res.result_category == CAT_NAVIGATION, "categorized as navigation")
    _expect(res.failure_category == "", "no failure category on success")
    _expect(res.exit_code == 0, "exit 0")


def test_categorize_redacts_details() raises:
    var argv = List[String]()
    argv.append("snapshot")
    var proc = ProcOutput("token: sk-LIVE-SECRET\nheading: Welcome", 0, True)
    var res = categorize(argv, proc)
    _expect(res.details.find("sk-LIVE-SECRET") == -1, "secret stripped")
    _expect(res.details.find("Welcome") != -1, "benign content kept")


def test_categorize_failure() raises:
    var argv = List[String]()
    argv.append("click")
    argv.append("--text")
    argv.append("Nope")
    var proc = ProcOutput("Error: element not found", 1, True)
    var res = categorize(argv, proc)
    _expect(not res.ok, "failure not ok")
    _expect(res.failure_category == FAIL_STALE_REF, "click miss → stale_ref")
    _expect(res.summary.find("snapshot") != -1, "summary has recovery hint")


def test_categorize_not_installed() raises:
    var argv = List[String]()
    argv.append("open")
    var proc = ProcOutput("", -1, False)
    var res = categorize(argv, proc)
    _expect(not res.ok, "not-ran is failure")
    _expect(
        res.failure_category == FAIL_NOT_INSTALLED, "popen-null → not_installed"
    )


def test_trim_body() raises:
    # Build a body well past BODY_LIMIT (8000).
    var big = String("")
    for _ in range(2000):
        big += "ABCDE"  # 10000 bytes
    var trimmed = trim_body(big)
    _expect(
        trimmed.byte_length() < big.byte_length(), "oversized body is trimmed"
    )
    _expect(trimmed.find("elided") != -1, "trim leaves an elision marker")
    var small = String("short body")
    _expect(trim_body(small) == small, "small body untouched")


# ── proc plumbing (the one impure check) ──────────────────────────────────────


def test_run_shell_echo() raises:
    var out = run_shell("printf 'hello world'")
    _expect(out.ran, "popen ran")
    _expect(out.exit_code == 0, "echo exits 0")
    _expect(out.stdout == "hello world", "captured stdout")


def test_run_shell_exit_code() raises:
    var out = run_shell("exit 3")
    _expect(out.ran, "popen ran for exit 3")
    _expect(out.exit_code == 3, "non-zero exit code recovered")


def main() raises:
    test_compile_args()
    test_compile_session_flags()
    test_compile_semantic_click()
    test_compile_semantic_fill()
    test_compile_semantic_ref_fallback()
    test_compile_job_batch()
    test_compile_qa_batch()
    test_compile_qa_minimal()
    test_compile_electron()
    test_compile_output_path()
    test_json_escape()
    test_shell_quote()
    test_shell_command_with_stdin()
    test_shell_command_no_stdin()
    test_is_sensitive_key()
    test_redact_key_value()
    test_redact_preserves_benign()
    test_redact_bearer()
    test_redact_multiline()
    test_success_category()
    test_failure_category()
    test_categorize_success()
    test_categorize_redacts_details()
    test_categorize_failure()
    test_categorize_not_installed()
    test_trim_body()
    test_run_shell_echo()
    test_run_shell_exit_code()
    print("all browser_native tests passed")
