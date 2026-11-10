#!/usr/bin/env python3
"""Compare optimized scanners on static scopes with alternating warm runs."""
import argparse
import json
import re
import statistics
import subprocess
from pathlib import Path


def sample(binary, name, scope):
    args = [binary, scope, "1"] if name == "swift" else [binary, "--bench-scan", scope, "1"]
    output = subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)
    timing = r"seconds=([0-9.]+)" if name == "swift" else r"run 0: ([0-9.]+)s"
    count = r"items=(\d+)" if name == "swift" else r"nodes=(\d+)"
    seconds = float(re.search(timing, output)[1])
    accounting = tuple(int(re.search(pattern, output)[1]) for pattern in (count, r"bytes=(\d+)", r"errors=(\d+)"))
    return seconds, accounting


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", required=True)
    parser.add_argument("--petal", required=True)
    parser.add_argument("--output", default="comparison.json")
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("scopes", nargs="+")
    options = parser.parse_args()
    if options.runs < 2:
        parser.error("--runs must be at least two")
    results = []
    for scope in options.scopes:
        samples = {"swift": [], "petal": []}
        fingerprints = {"swift": set(), "petal": set()}
        for round_number in range(options.runs):
            order = ("swift", "petal") if round_number % 2 == 0 else ("petal", "swift")
            for name in order:
                seconds, accounting = sample(getattr(options, name), name, scope)
                samples[name].append(seconds)
                fingerprints[name].add(accounting)
                print(scope, name, seconds, *accounting, flush=True)
        medians = {name: statistics.median(values) for name, values in samples.items()}
        entry = {
            "scope": scope,
            "samples": samples,
            "medians": medians,
            "ratio": medians["swift"] / medians["petal"],
            "matching": fingerprints["swift"] == fingerprints["petal"] and len(fingerprints["swift"]) == 1,
            "fingerprints": {name: sorted(values) for name, values in fingerprints.items()},
        }
        results.append(entry)
        print(json.dumps(entry), flush=True)
        Path(options.output).write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    if not all(result["matching"] and result["ratio"] <= 1.10 for result in results):
        raise SystemExit("Accounting or 10% timing gate failed")


if __name__ == "__main__":
    main()
