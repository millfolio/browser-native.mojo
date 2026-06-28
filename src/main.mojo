"""The `browser-native` CLI.

A thin command-line face over the library, mostly for smoke-testing the wrapper
against a real `agent-browser` install. Three shapes:

    browser-native open https://example.com        # args passthrough
    browser-native snapshot -i
    browser-native --semantic click text Learn      # one semantic action
    browser-native --qa https://example.com Welcome # smoke check

Everything after the program name that isn't a recognized leading flag is passed
straight through to `agent-browser` as an `args` request. The result's summary,
category, and (redacted, bounded) details are printed.
"""

from std.sys import argv
from browser_native import (
    BrowserRequest,
    BrowserResult,
    args_request,
    semantic_request,
    qa_request,
    run,
)


def _build_request() raises -> BrowserRequest:
    var a = argv()
    var n = len(a)
    if n <= 1:
        raise Error("usage: browser-native <agent-browser args…>")

    var head = String(a[1])

    if head == "--semantic":
        # --semantic <action> <locator> <value> [input]
        if n < 5:
            raise Error(
                "usage: browser-native --semantic <action> <locator> <value>"
                " [input]"
            )
        var input = String(a[5]) if n > 5 else String("")
        return semantic_request(String(a[2]), String(a[3]), String(a[4]), input)

    if head == "--qa":
        # --qa <url> [expected_text]
        if n < 3:
            raise Error("usage: browser-native --qa <url> [expected_text]")
        var expected = String(a[3]) if n > 3 else String("")
        return qa_request(String(a[2]), expected)

    # Default: pass everything through as a verbatim upstream argv.
    var args = List[String]()
    for i in range(1, n):
        args.append(String(a[i]))
    return args_request(args)


def main() raises:
    var req = _build_request()
    var result = run(req)

    print(result.summary)
    if result.spilled:
        print("(output was trimmed — full result spilled upstream)")
    if result.details != "":
        print("---")
        print(result.details)
