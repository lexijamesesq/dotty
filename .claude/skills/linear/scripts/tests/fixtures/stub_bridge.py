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

The payload-file argument (argv[1]) is read but never inspected — these
tests assert on linear_bridge.py's own output, not on what it sent the
bridge; wiring correctness (payload actually contains "query") is covered by
a dedicated argv[1]-content assertion in test_linear_bridge.py's shape test.
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

    resp = responses[min(idx, len(responses) - 1)]
    stdout = resp.get("stdout", "")
    if not isinstance(stdout, str):
        stdout = json.dumps(stdout)
    sys.stdout.write(stdout)
    sys.stderr.write(resp.get("stderr", ""))
    return resp.get("returncode", 0)


if __name__ == "__main__":
    sys.exit(main())
