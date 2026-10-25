"""Seeded fault combinations checked against an independent Python reference."""
import argparse
import collections
import copy
import json
import pathlib
import random
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cmd/runledger/runledger.exe"


def reference(rows, manifest):
    buckets = collections.defaultdict(list)
    for row in rows:
        buckets[row["run_id"], row["call_id"]].append(row)
    accepted = []
    findings = collections.Counter()
    for copies in buckets.values():
        findings["duplicate_call"] += sum(row == copies[0] for row in copies[1:])
        findings["conflicting_call"] += sum(row != copies[0] for row in copies[1:])
        if all(row == copies[0] for row in copies):
            accepted.append(copies[0])
    if not accepted:
        findings["empty_log"] += 1
    unknown = sum(row["input_tokens"] is None or row["output_tokens"] is None for row in accepted)
    findings["missing_usage"] += unknown
    complete = not any(findings.values())
    covered = set()
    for row in accepted:
        checks = {
            "unexpected_run": row["run_id"] == manifest["run_id"],
            "unexpected_model": row["model"] == manifest["model"],
            "unexpected_task": row["task_id"] in manifest["task_ids"],
            "unexpected_stage": row["stage"] in manifest["required_stages"],
        }
        for code, matches in checks.items():
            findings[code] += not matches
        if all(checks.values()) and row["status"] == "ok":
            covered.add((row["task_id"], row["stage"]))
    findings["missing_stage"] += sum((task, stage) not in covered
                                     for task in manifest["task_ids"] for stage in manifest["required_stages"])
    totals = {"calls": len(accepted), "input_tokens": sum(row["input_tokens"] or 0 for row in accepted),
              "output_tokens": sum(row["output_tokens"] or 0 for row in accepted),
              "unknown_usage_calls": unknown, "failed_calls": sum(row["status"] == "error" for row in accepted)}
    return totals, {code: count for code, count in findings.items() if count}, complete


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cases", type=int, default=100)
    parser.add_argument("--seed", type=int, default=20261026)
    args = parser.parse_args()
    if args.cases < 1:
        parser.error("cases must be positive")
    rng = random.Random(args.seed)
    with tempfile.TemporaryDirectory(prefix="runledger-invariants-") as directory:
        path = pathlib.Path(directory)
        for index in range(args.cases):
            manifest = {"run_id": "r", "model": "m", "task_ids": [str(i) for i in range(rng.randint(1, 12))],
                        "required_stages": ["answer", "review"]}
            rows = [{"run_id": "r", "model": "m", "task_id": task, "stage": stage,
                     "call_id": task + stage, "status": rng.choice(["ok", "ok", "error"]),
                     "input_tokens": rng.choice([None, 0, 10, 100]),
                     "output_tokens": rng.choice([None, 0, 2, 20])}
                    for task in manifest["task_ids"] for stage in manifest["required_stages"]]
            if rng.random() < 0.7:
                rows.append(copy.deepcopy(rng.choice(rows)))
            if rng.random() < 0.6:
                conflict = copy.deepcopy(rng.choice(rows))
                conflict["input_tokens"] = (conflict["input_tokens"] or 0) + 1
                rows.append(conflict)
            if rng.random() < 0.4:
                foreign = copy.deepcopy(rows[0])
                foreign.update(call_id="foreign", run_id="other", model="other", task_id="unknown", stage="unknown")
                rows.append(foreign)
            if rng.random() < 0.3:
                rows.pop(rng.randrange(len(rows)))
            if rng.random() < 0.05:
                rows = []
            (path / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            original_totals = None
            for permutation in range(2):
                if permutation:
                    rng.shuffle(rows)
                expected_totals, expected_codes, expected_complete = reference(rows, manifest)
                (path / "calls.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
                proc = subprocess.run([str(EXE), "audit-detail", str(path / "calls.jsonl"), str(path / "manifest.json")],
                                      cwd=ROOT, text=True, capture_output=True, check=False)
                detail = json.loads(proc.stdout)
                report = detail["report"]
                actual_totals = {key: int(value) for key, value in report["totals"].items()}
                actual_codes = dict(collections.Counter(f["code"] for f in report["findings"]))
                assert actual_totals == expected_totals, (index, permutation, actual_totals, expected_totals)
                assert actual_codes == expected_codes, (index, permutation, actual_codes, expected_codes)
                assert report["usage_complete"] == expected_complete
                assert report["ok"] == (not expected_codes)
                assert proc.returncode == (0 if report["ok"] else 1)
                for field in ["input_tokens", "output_tokens", "calls"]:
                    assert sum(int(group["totals"][field]) for group in detail["groups"]) == actual_totals[field]
                if original_totals is not None:
                    assert actual_totals == original_totals, (index, "permutation changed accounting")
                original_totals = actual_totals
    out = ROOT / "reports/invariants"
    out.mkdir(parents=True, exist_ok=True)
    (out / "summary.json").write_text(json.dumps({"seed": args.seed, "cases": args.cases,
        "permutations_per_case": 2, "reference": "independent Python grouping and coverage reference",
        "scope": "small valid-schema synthetic records; not exhaustive or a proof", "passed": True}, indent=2) + "\n")
    print(f"Independent reference and permutation checks passed: {args.cases} cases, 2 orders each, seed={args.seed}")


if __name__ == "__main__":
    main()
