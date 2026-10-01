#!/usr/bin/env python3
"""Export or check compiled ABIs using only the Python standard library."""

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAMES = (
    "LaunchToken", "PvPadToken", "BondingCurve", "PvPadFactory",
    "PvPadHook", "KingOfThePad", "WorkerSubsidy", "FeeEscrow",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail on missing or stale ABI exports")
    args = parser.parse_args()
    mismatches = []
    for name in NAMES:
        artifact = ROOT / "out" / (name + ".sol") / (name + ".json")
        if not artifact.is_file():
            parser.error(f"Missing {artifact.relative_to(ROOT)}; run forge build first")
        abi = json.loads(artifact.read_text())["abi"]
        target = ROOT / "docs" / "abi" / (name + ".json")
        expected = json.dumps(abi, indent=2) + "\n"
        if args.check:
            if not target.is_file() or target.read_text() != expected:
                mismatches.append(str(target.relative_to(ROOT)))
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(expected)
            print(target.relative_to(ROOT))
    if mismatches:
        parser.exit(1, "Missing or stale ABI exports: " + ", ".join(mismatches) + "\n")
    if args.check:
        print(f"All {len(NAMES)} ABI exports match the build artifacts.")


if __name__ == "__main__":
    main()
