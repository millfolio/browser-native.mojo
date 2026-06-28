"""run — the whole pipeline end to end: request → result.

`run` is the one call most consumers make. It threads a `BrowserRequest` through
the three stages — compile to an upstream `Plan`, execute it under the shell,
fold the captured output into a bounded `BrowserResult` — and hands back the
verdict. The intermediate `compile_plan` / `run_shell` / `categorize` stay public
for callers (and tests) that want to drive the stages individually.
"""

from browser_native.request import BrowserRequest
from browser_native.compile import Plan, compile_plan, shell_command
from browser_native.proc import run_shell
from browser_native.result import BrowserResult, categorize

comptime DEFAULT_BIN: String = "agent-browser"


def run(req: BrowserRequest, bin: String = DEFAULT_BIN) raises -> BrowserResult:
    """Compile, execute, and categorize `req` against the `agent-browser` binary
    named `bin` (looked up on PATH)."""
    var plan = compile_plan(req)
    var cmd = shell_command(bin, plan)
    var proc = run_shell(cmd)
    return categorize(plan.argv, proc)
