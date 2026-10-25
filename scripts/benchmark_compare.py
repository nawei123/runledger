"""Compare CLI audit throughput and exact reports against a retained baseline binary."""
import argparse
import hashlib
import json
import pathlib
import platform
import statistics
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", type=pathlib.Path, required=True)
    parser.add_argument("--candidate", type=pathlib.Path,
                        default=ROOT / "_build/native/debug/build/cmd/runledger/runledger.exe")
    parser.add_argument("--sizes", type=int, nargs="+", default=[100, 1000, 5000])
    parser.add_argument("--repeats", type=int, default=3)
    args = parser.parse_args()
    if args.repeats < 1 or any(x < 1 for x in args.sizes):
        parser.error("sizes and repeats must be positive")
    binaries = {"baseline": args.baseline.resolve(), "candidate": args.candidate.resolve()}
    out = ROOT / "reports/benchmark"
    out.mkdir(parents=True, exist_ok=True)
    results = []
    for size in args.sizes:
        rows = []
        for index in range(size):
            for stage in ["answer", "review"]:
                rows.append({"run_id": "bench", "task_id": str(index), "stage": stage,
                             "call_id": f"{index}-{stage}", "model": "bench-model", "status": "ok",
                             "input_tokens": 10, "output_tokens": 2})
        source = out / "calls.jsonl"
        source.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
        manifest = out / "manifest.json"
        manifest.write_text(json.dumps({"run_id": "bench", "model": "bench-model",
                                       "task_ids": [str(i) for i in range(size)],
                                       "required_stages": ["answer", "review"]}), encoding="utf-8")
        timings = {name: [] for name in binaries}
        reference = None
        # Warm both binaries, then alternate their order to reduce order bias.
        for iteration in range(args.repeats + 1):
            order = list(binaries) if iteration % 2 == 0 else list(reversed(binaries))
            for name in order:
                start = time.perf_counter()
                proc = subprocess.run([str(binaries[name]), "audit", str(source), str(manifest)],
                                      cwd=ROOT, text=True, capture_output=True, check=True)
                elapsed = time.perf_counter() - start
                report = json.loads(proc.stdout)
                if reference is None:
                    reference = report
                if report != reference:
                    raise RuntimeError(f"Accounting/diagnostic regression: {name}, tasks={size}")
                if iteration:
                    timings[name].append(elapsed)
        medians = {name: statistics.median(samples) for name, samples in timings.items()}
        result = {"tasks": size, "calls": len(rows), "report_equivalence": True,
                  "seconds": timings, "median_seconds": medians,
                  "median_speedup": medians["baseline"] / medians["candidate"]}
        results.append(result)
        print(json.dumps(result), flush=True)
    data = {"scope": "synthetic CLI end-to-end audit, process startup and parsing included",
            "system": platform.system(), "machine": platform.machine(), "repeats": args.repeats,
            "baseline_source_commit": "765dd81e16d87ba7a95d55c3f35ff1c5e312462a",
            "candidate_source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
            "working_tree_dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip()),
            "binary_sha256": {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in binaries.items()},
            "results": results}
    (out / "comparison.json").write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
