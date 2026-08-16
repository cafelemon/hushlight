#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
from pathlib import Path


LLM_ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    config = json.loads((LLM_ROOT / "config" / "model.json").read_text(encoding="utf-8"))
    weight_path = LLM_ROOT / config["local_path"] / config["weight_file"]
    actual_bytes = weight_path.stat().st_size
    digest = hashlib.sha256()
    with weight_path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(16 * 1024 * 1024), b""):
            digest.update(chunk)
    actual_sha256 = digest.hexdigest()
    checks = {
        "size_matches": actual_bytes == config["expected_weight_bytes"],
        "sha256_matches": actual_sha256 == config["expected_weight_sha256"],
    }
    result = {
        "passed": all(checks.values()),
        "model_id": config["model_id"],
        "weight_path": str(weight_path),
        "actual_bytes": actual_bytes,
        "actual_sha256": actual_sha256,
        "checks": checks,
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

