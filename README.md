# browser-native.mojo

> 💬 **Community:** questions, ideas, and show-and-tell live in [GitHub Discussions](https://github.com/millfolio/millfolio/discussions).

A native, agent-friendly **Mojo** wrapper around the upstream
[`agent-browser`](https://agent-browser.dev/) CLI. It gives that stringly-typed
engine a *typed* face: a caller builds one of five structured requests, and the
pipeline compiles it to a single upstream invocation, runs it, **redacts secrets
out of the output**, and folds the result into a small, **bounded** set of
categories an agent can branch on reliably.

```mojo
from browser_native import args_request, semantic_request, qa_request, run

# Direct passthrough — run `agent-browser open https://example.com`.
var nav = run(args_request(["open", "https://example.com"]))
print(nav.summary)          # agent_browser open ok (navigation)
print(nav.result_category)  # navigation

# One stable-locator action — click the element whose visible text is "Learn".
var click = run(semantic_request("click", "text", "Learn"))
if not click.ok:
    print(click.failure_category, click.summary)   # e.g. stale_ref … take a fresh snapshot

# A URL smoke check — open, assert text, screenshot, all in one batch.
var qa = run(qa_request("https://example.com", "Example Domain", "shot.png"))
```

## Credit

This is a **Mojo port of
[`fitchmultz/pi-agent-browser-native`](https://github.com/fitchmultz/pi-agent-browser-native)**
by [@fitchmultz](https://github.com/fitchmultz) — a Pi extension that wraps the
upstream `agent-browser` engine as a native tool for coding agents. The original
is TypeScript; this repo re-implements its **design** (the five input modes,
argv compilation, secret redaction, and bounded result/failure categories) in
pure Mojo. All credit for the original concept and tool contract goes to that
project and to upstream [`agent-browser`](https://agent-browser.dev/). Neither is
bundled here — `agent-browser` must be installed separately and on `PATH`.

## Why

The upstream CLI is flexible but every call is a bare argv that an agent has to
assemble — and mis-assemble — by hand, and whose free-form text output it then
has to parse and branch on. That is brittle in both directions. `browser_native`
fixes both ends:

- **Typed in.** Pick exactly one input mode; the wrapper builds the argv.
- **Bounded out.** Every run collapses to a closed set of categories plus a
  one-line, model-facing summary with recovery guidance — never a string the
  agent has to guess at.
- **Safe.** Cookies, `Authorization: Bearer …` headers, `password=…` fields, and
  API keys are masked before the output ever reaches the model's context.

## Input modes

Pick exactly one per call (factories in `browser_native.request`):

| Mode | Factory | What it is |
|------|---------|------------|
| `args` | `args_request(argv, stdin?, session_mode?)` | Direct upstream CLI passthrough — the flexible escape hatch. |
| `semantic` | `semantic_request(action, locator, value, input?)` | One role/text/label/selector/ref-targeted action. |
| `job` | `job_request(steps)` | A constrained multi-step workflow compiled to one upstream `batch`. |
| `qa` | `qa_request(url, expected_text?, screenshot_path?)` | A URL smoke check (open → wait → assert → screenshot). |
| `electron` | `electron_request(action, app_name?)` | Desktop-app lifecycle (discover/launch/attach/cleanup). |

`semantic` locators map to upstream flags: `text → --text`, `role → --role`,
`label → --label`, `placeholder → --placeholder`, `ref → --ref`, and anything
else falls back to `--selector` (the css escape hatch).

## Output: the bounded verdict

`run` returns a `BrowserResult`:

| field | meaning |
|-------|---------|
| `ok` | did the run succeed |
| `result_category` | on success — one of `snapshot`, `navigation`, `action`, `artifact`, `info`, `empty` |
| `failure_category` | on failure — one of `not_installed`, `timeout`, `stale_ref`, `navigation_error`, `usage_error`, `exec_error` |
| `summary` | one-line, model-facing prose, with a recovery hint on failure |
| `details` | the **redacted**, size-bounded output body |
| `spilled` | true when an oversized body was head+tail trimmed |
| `exit_code` | the upstream exit status |

## Architecture

A three-stage pipeline, two-thirds of it pure (and so testable with no
`agent-browser` installed):

```
BrowserRequest ──compile_plan──▶ Plan(argv, stdin) ──run_shell──▶ ProcOutput ──categorize──▶ BrowserResult
   (typed input)     (pure)        (one invocation)    (popen)      (captured)     (pure)        (bounded)
```

| file | role |
|------|------|
| `src/browser_native/request.mojo` | the five input-mode structs + `*_request` factories |
| `src/browser_native/compile.mojo` | `compile_plan` (request → argv + stdin), batch-JSON + shell rendering |
| `src/browser_native/redact.mojo` | secret redaction (`key: value`, `key=value`, `Bearer …`) |
| `src/browser_native/result.mojo` | the bounded category vocabulary + `categorize` |
| `src/browser_native/proc.mojo` | the one impure layer — `popen(3)`/`pclose(3)` over libc |
| `src/browser_native/run.mojo` | the end-to-end `run` |
| `src/main.mojo` | a thin `browser-native` CLI |

`compile_plan` and `categorize` are pure functions of strings; the only OS
contact is `proc.run_shell`, which runs a fully single-quoted shell line and
folds stderr into the captured stdout.

## Use it

Pure Mojo + libc (`popen`), no extra dependencies. Consumers add the include
path and import the package:

```
mojo build your.mojo -I ../browser-native.mojo/src
```

```mojo
from browser_native import args_request, run
```

The runtime dependency is the upstream `agent-browser` binary on `PATH` (install
from <https://agent-browser.dev/>). When it's missing, a call returns cleanly
with `failure_category == "not_installed"` rather than crashing.

## CLI

```
mojo build src/main.mojo -I src -o build/browser-native    # or: pixi run build-cli

build/browser-native open https://example.com         # args passthrough
build/browser-native snapshot -i
build/browser-native --semantic click text Learn       # one semantic action
build/browser-native --qa https://example.com Welcome  # smoke check
```

## Test

```
pixi run test
```

The suite drives the pure stages — argv/stdin compilation, redaction, and
categorization — so it runs green without `agent-browser` installed; one case at
the end exercises the `popen` plumbing over a real `printf`.

## License & attribution

Design and tool contract ported, with thanks, from
[`fitchmultz/pi-agent-browser-native`](https://github.com/fitchmultz/pi-agent-browser-native).
Built to drive upstream [`agent-browser`](https://agent-browser.dev/), which is
neither vendored nor modified here.
