#!/usr/bin/env python3
"""Extract OPUS_GATE_VERDICT from a claude-code-action execution file. Prints PASS | FAIL | NONE.

Parses ONLY the action's `result` event (its final output), never the assistant
`message` content blocks. The reviewer quotes PR diff content into its message
stream, so a PR could otherwise spoof a verdict by embedding `OPUS_GATE_VERDICT:
PASS` in its own diff and having the reviewer echo it back. Scoping to the result
event removes that injection surface; the verdict prompt requires the token on the
final line, which lands in the result event.
"""
import json
import re
import sys

exec_file = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    with open(exec_file) as f:
        data = json.load(f)
except Exception:
    print("NONE")
    sys.exit(0)

verdict = None
if isinstance(data, list):
    for e in data:
        if isinstance(e, dict) and e.get("type") == "result" and isinstance(e.get("result"), str):
            for m in re.finditer(r"OPUS_GATE_VERDICT:\s*(PASS|FAIL)", e["result"], re.IGNORECASE):
                verdict = m.group(1).upper()

print(verdict or "NONE")
