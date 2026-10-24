#!/usr/bin/env python3
"""Local bridge-v1 client: creates fresh envelopes, never executes actions itself."""
import argparse
import datetime as dt
import json
from pathlib import Path
import secrets
import subprocess
import sys
import time
import uuid


def uuid7():
    value = (int(time.time() * 1000) << 80) | (7 << 76)
    value |= secrets.randbits(12) << 64
    value |= (2 << 62) | secrets.randbits(62)
    return str(uuid.UUID(int=value))


def main():
    project = Path(__file__).resolve().parents[1]
    schema = json.loads((project / "Sources/BridgeCore/Resources/bridge-v1.schema.json").read_text())
    actions = {
        variant["properties"]["action"]["const"]: variant["properties"]["risk_level"]["const"]
        for variant in schema["$defs"]["commandRequest"]["oneOf"]
    }
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--simulate", action="store_true", help="Debug-only in-memory volume, no system writes")
    mode.add_argument("--allow-volume-control", action="store_true", help="Enable real volume set/adjust")
    parser.add_argument("--paused", action="store_true", help="Reject commands at the router")
    parser.add_argument("action", choices=sorted(actions))
    parser.add_argument("parameters", nargs="?", default="{}", help="JSON object; default {}")
    args = parser.parse_args()
    try:
        parameters = json.loads(args.parameters)
        if not isinstance(parameters, dict):
            raise ValueError()
    except (ValueError, TypeError):
        parser.error("parameters must be a valid JSON object")
    now = dt.datetime.now(dt.timezone.utc)

    def timestamp(offset):
        return (now + dt.timedelta(seconds=offset)).isoformat(timespec="seconds").replace("+00:00", "Z")

    envelope = {
        "protocol_version": "1.0", "message_type": "command.request",
        "message_id": uuid7(), "request_id": uuid7(),
        "source": {"kind": "debug_console", "id": "local-command-client"},
        "issued_at": timestamp(-1), "expires_at": timestamp(60),
        "nonce": secrets.token_urlsafe(24),
        "payload": {"action": args.action, "risk_level": actions[args.action], "parameters": parameters},
    }
    data = json.dumps(envelope, separators=(",", ":"), allow_nan=False).encode()
    if len(data) > 65536:
        parser.error("command exceeds 65536-byte limit")
    command = ["swift", "run", "--package-path", str(project), "hushlight-bridge"]
    if args.simulate:
        command.append("--simulate")
    if args.allow_volume_control:
        command.append("--allow-volume-control")
    if args.paused:
        command.append("--paused")
    # One invocation is one process. Use the persistent NDJSON runner for retry/idempotency tests.
    result = subprocess.run(command, input=data + b"\n", check=False)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
