#!/usr/bin/env python3
"""Exercise the local NDJSON bridge with simulated volume; no system write occurs."""
import datetime
import json
import pathlib
import subprocess
import sys

project = pathlib.Path(__file__).resolve().parents[1]
now = datetime.datetime.now(datetime.timezone.utc)
def stamp(offset):
    return (now + datetime.timedelta(seconds=offset)).isoformat(timespec="seconds").replace("+00:00", "Z")

def command(number, action, risk, parameters, request=1, source="debug_console"):
    return {
        "protocol_version": "1.0", "message_type": "command.request",
        "message_id": f"018f0f4e-2f55-7f5c-8ca2-{number:012d}",
        "request_id": f"018f0f4e-2f55-7f5c-8ca2-{request:012d}",
        "source": {"kind": source, "id": "local-smoke"},
        "issued_at": stamp(-1), "expires_at": stamp(60),
        "nonce": f"local-smoke-nonce-{number:012d}",
        "payload": {"action": action, "risk_level": risk, "parameters": parameters},
    }

lines = [
    command(1, "system.volume.set", "L1", {"value": 73}),
    command(2, "system.volume.get", "L0", {}, request=2),
    command(2, "system.volume.get", "L0", {}, request=2),
    command(3, "timer.cancel", "L2", {"timer_id": "timer-1"}, request=3),
    command(4, "system.volume.get", "L0", {}, request=4, source="cloud"),
]
process = subprocess.run(
    ["swift", "run", "hushlight-bridge", "--simulate"], cwd=project,
    input="".join(json.dumps(item, separators=(",", ":")) + "\n" for item in lines),
    text=True, capture_output=True, check=True,
)
responses = [json.loads(line) for line in process.stdout.splitlines()]
assert len(responses) == len(lines), responses
assert all(item["mode"] == "simulation" for item in responses)
assert responses[0]["result"]["summary"]["value"] == 73
assert responses[1]["result"]["summary"]["value"] == 73
assert responses[2]["stable_error"] == "replay_detected"
assert responses[3]["result"]["stable_error"] == "capability_disabled"
assert responses[4]["stable_error"] == "unauthenticated"
print("pass: simulated volume, replay, disabled action, source rejection")
