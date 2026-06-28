"""proc — the one impure layer: run a shell command and capture its output.

Everything else in `browser_native` is a pure function of strings; this module
is where we actually touch the OS. It wraps libc `popen(3)` / `pclose(3)` to run
a `/bin/sh -c` line, drain its stdout (the caller folds stderr in with `2>&1`),
and recover the child's exit code.

`popen` returning NULL — the binary isn't on PATH, or the fork failed — is
reported as `ran == False` rather than an exception, so the result layer can map
it to the `not_installed` failure category and hand the agent an actionable
message instead of a crash.
"""

from std.ffi import external_call, c_int
from std.memory import UnsafePointer

comptime _FilePtr = UnsafePointer[NoneType, MutUntrackedOrigin]
comptime _CHUNK: Int = 8192


@fieldwise_init
struct ProcOutput(Copyable, Movable):
    """The captured result of a `run_shell` call.

    `stdout`    — combined stdout/stderr bytes as text.
    `exit_code` — the child's exit status (`WEXITSTATUS`); -1 if it never ran.
    `ran`       — False when `popen` returned NULL (binary missing / fork fail).
    """

    var stdout: String
    var exit_code: Int
    var ran: Bool


def run_shell(command: String) -> ProcOutput:
    """Run `command` via `popen(command, "r")`, returning its captured output.

    The caller is responsible for the command being shell-safe — `compile`'s
    `shell_command` builds one with every argument single-quoted.
    """
    var cmd_copy = command
    var c_cmd = cmd_copy.as_c_string_slice()
    var mode = String("r")
    var c_mode = mode.as_c_string_slice()

    var fp = external_call["popen", _FilePtr](
        c_cmd.unsafe_ptr(), c_mode.unsafe_ptr()
    )
    if Int(fp) == 0:
        return ProcOutput("", -1, False)

    var buf = List[UInt8]()
    buf.resize(_CHUNK, UInt8(0))
    var acc = List[UInt8]()
    while True:
        var n = Int(
            external_call["fread", Int](buf.unsafe_ptr(), 1, _CHUNK, fp)
        )
        if n <= 0:
            break
        for i in range(n):
            acc.append(buf[i])

    var status = Int(external_call["pclose", c_int](fp))
    # WEXITSTATUS(status): the low 8 bits of the second byte.
    var code = (status >> 8) & 0xFF
    var out = String(unsafe_from_utf8=Span[UInt8, _](acc))
    return ProcOutput(out, code, True)
