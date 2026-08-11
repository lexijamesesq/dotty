#!/usr/bin/env python3
"""
stub_bridge.py — stand-in GraphQL bridge command for linear_bridge.py's unit
tests. Never talks to a network; replays a scripted response sequence so the
transport layer (retry/backoff, error-class detection, exit-code mapping)
gets exercised through a real subprocess invocation, per the spec's testing
requirement ("bridge invocations mocked via a stub bridge script that
replays fixture JSON").

Contract:
    STUB_BRIDGE_RESPONSES   env var, required — a JSON list of
        {"stdout": <str-or-obj>, "stderr": <str>, "returncode": <int>}
        objects, one per successive invocation within a test.
    STUB_BRIDGE_COUNTER_FILE  env var, required — a path this script uses to
        track how many times it's been invoked so far this test (each
        invocation is a fresh process; the counter file is the only shared
        state). Index into STUB_BRIDGE_RESPONSES clamps to the last entry if
        the sequence is exhausted (a bridge failing forever, e.g. the
        never-recovers retry-exhaustion case).
    STUB_BRIDGE_LOG_FILE   env var, optional — when set, each invocation
        appends the payload's `query` string (argv[1], the GraphQL request
        this run actually sent) as one JSON-encoded line, in call order.
        Tests read this back to assert *sequencing* — e.g. --execute-if-
        clean's comment-before-state-change law — not just that the right
        final output came out. Silently skipped when unset; most tests
        don't need call-order assertions and shouldn't pay for the file I/O.

The payload-file argument (argv[1]) is otherwise not inspected by default —
most tests assert on linear_bridge.py's own output, not on what it sent the
bridge.
"""
import json
import os
import sys


def main():
    responses = json.loads(os.environ["STUB_BRIDGE_RESPONSES"])
    counter_file = os.environ["STUB_BRIDGE_COUNTER_FILE"]

    idx = 0
    if os.path.exists(counter_file):
        with open(counter_file, "r", encoding="utf-8") as f:
            content = f.read().strip()
            idx = int(content) if content else 0
    with open(counter_file, "w", encoding="utf-8") as f:
        f.write(str(idx + 1))

    log_file = os.environ.get("STUB_BRIDGE_LOG_FILE")
    if log_file and len(sys.argv) > 1:
        try:
            with open(sys.argv[1], "r", encoding="utf-8") as pf:
                payload = json.load(pf)
            with open(log_file, "a", encoding="utf-8") as lf:
                lf.write(json.dumps(payload.get("query", "")) + "\n")
        except (OSError, ValueError):
            pass  # logging is best-effort; never let it break the stub's own response

    resp = responses[min(idx, len(responses) - 1)]
    stdout = resp.get("stdout", "")
    if not isinstance(stdout, str):
        stdout = json.dumps(stdout)
    sys.stdout.write(stdout)
    sys.stderr.write(resp.get("stderr", ""))
    return resp.get("returncode", 0)


if __name__ == "__main__":
    sys.exit(main())
