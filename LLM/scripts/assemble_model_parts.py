#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
from pathlib import Path


LLM_ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    config = json.loads((LLM_ROOT / "config" / "model.json").read_text(encoding="utf-8"))
    model_dir = LLM_ROOT / config["local_path"]
    target = model_dir / config["weight_file"]
    parts = [model_dir / f"{config['weight_file']}.part{index}" for index in range(5)]
    missing = [str(path) for path in parts if not path.is_file()]
    if missing:
        raise FileNotFoundError(f"Missing model parts: {missing}")

    assembled = target.with_suffix(target.suffix + ".assembled")
    digest = hashlib.sha256()
    total_bytes = 0
    with assembled.open("wb") as output:
        for part in parts:
            with part.open("rb") as source:
                for chunk in iter(lambda: source.read(16 * 1024 * 1024), b""):
                    output.write(chunk)
                    digest.update(chunk)
                    total_bytes += len(chunk)

    actual_sha256 = digest.hexdigest()
    if total_bytes != config["expected_weight_bytes"]:
        assembled.unlink(missing_ok=True)
        raise ValueError(
            f"Assembled size mismatch: {total_bytes} != {config['expected_weight_bytes']}"
        )
    if actual_sha256 != config["expected_weight_sha256"]:
        assembled.unlink(missing_ok=True)
        raise ValueError(
            f"Assembled SHA-256 mismatch: {actual_sha256} != {config['expected_weight_sha256']}"
        )

    assembled.replace(target)
    print(
        json.dumps(
            {
                "passed": True,
                "weight_path": str(target),
                "bytes": total_bytes,
                "sha256": actual_sha256,
                "parts_retained": [str(path) for path in parts],
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

