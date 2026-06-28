"""redact — strip secrets out of upstream output before an agent ever sees it.

`agent-browser` faithfully echoes whatever the page (or the command) contained:
cookies, `Authorization: Bearer …` headers, `password=…` form fields, API keys.
None of that should reach the model's context or a transcript. `redact` is a
line-oriented pass that masks the *value* half of any sensitive key while
leaving benign page content intact.

It is deliberately conservative-but-blunt: a `key: value` or `key=value` line
whose key looks sensitive has its value replaced wholesale with the redaction
marker. Better to over-redact a stray field than to leak a live credential.

Ported from the redaction layer of fitchmultz/pi-agent-browser-native.
"""

comptime REDACTED: String = "«redacted»"


def _sensitive_keys() -> List[String]:
    """Substrings that, when present in a key, mark its value as a secret."""
    var keys = List[String]()
    keys.append("password")
    keys.append("passwd")
    keys.append("secret")
    keys.append("token")
    keys.append("api_key")
    keys.append("apikey")
    keys.append("api-key")
    keys.append("authorization")
    keys.append("auth")
    keys.append("cookie")
    keys.append("set-cookie")
    keys.append("session")
    keys.append("credential")
    keys.append("private_key")
    keys.append("access_key")
    keys.append("client_secret")
    return keys^


def is_sensitive_key(key: String) -> Bool:
    """True if `key` (case-insensitively) contains a sensitive substring."""
    var k = key.strip().lower()
    if k == "":
        return False
    var keys = _sensitive_keys()
    for i in range(len(keys)):
        if k.find(keys[i]) != -1:
            return True
    return False


def _redact_bearer(line: String) -> String:
    """Mask a bare `Bearer <token>` anywhere in `line` (the value after the
    scheme word), even when it isn't framed as `key: value`."""
    var lower = line.lower()
    var pos = lower.find("bearer ")
    if pos == -1:
        return line
    # Keep everything up to and including "Bearer " (preserving original case),
    # then redact the token that follows.
    return String(line[byte = : pos + 7]) + REDACTED


def redact(text: String) -> String:
    """Return `text` with the values of sensitive `key: value` / `key=value`
    lines (and any `Bearer` tokens) masked."""
    var out = String("")
    var lines = text.split("\n")
    for i in range(len(lines)):
        if i > 0:
            out += "\n"
        var line = String(lines[i])

        # Find the first key/value separator and test the key half.
        var colon = line.find(":")
        var equals = line.find("=")
        var sep = -1
        if colon != -1 and (equals == -1 or colon < equals):
            sep = colon
        elif equals != -1:
            sep = equals

        if sep > 0 and is_sensitive_key(String(line[byte=:sep])):
            # Preserve the key + separator, mask the value (keep indentation).
            out += String(line[byte = : sep + 1]) + " " + REDACTED
        else:
            out += _redact_bearer(line)
    return out^
