"""Generate reproducible synthetic acceptance reports from the compiled CLI."""
import hashlib
import json
import pathlib
import platform
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "reports/acceptance"
EXE = ROOT / "_build/native/debug/build/cmd/runledger/runledger.exe"


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    if not EXE.exists():
        raise SystemExit("Build first: moon build --target native")
    results = []

    def case(name, command, source, expected_exit, expected_codes=()):
        result = subprocess.run([str(EXE), command, str(source), "examples/manifest.json"],
                                cwd=ROOT, text=True, capture_output=True, check=False)
        report = json.loads(result.stdout)
        codes = {finding["code"] for finding in report["findings"]}
        if result.returncode != expected_exit or not set(expected_codes) <= codes:
            raise RuntimeError(f"Unexpected result: {name}, exit={result.returncode}, codes={codes}")
        if report["ok"] != (expected_exit == 0):
            raise RuntimeError(f"Inconsistent report: {name}")
        if expected_exit == 0 and (int(report["totals"]["input_tokens"]),
                                   int(report["totals"]["output_tokens"])) != (406, 86):
            raise RuntimeError(f"Unexpected usage totals: {name}")
        filename = name + ".json"
        write_json(OUTPUT / filename, report)
        results.append({"case": name, "exit_code": result.returncode,
                        "expected_exit_code": expected_exit, "report": filename,
                        "diagnostic_codes": sorted(codes)})

    case("clean", "audit", "examples/clean.jsonl", 0)
    case("broken", "audit", "examples/broken.jsonl", 1,
         ["duplicate_call", "missing_usage", "unexpected_model", "missing_stage"])
    case("ollama", "audit-ollama", "examples/ollama.jsonl", 0)
    normalized = subprocess.run([str(EXE), "normalize-ollama", "examples/ollama.jsonl"],
                                cwd=ROOT, text=True, capture_output=True, check=True)
    normalized_path = OUTPUT / "normalized.jsonl"
    normalized_path.write_text(normalized.stdout, encoding="utf-8")
    case("roundtrip", "audit", normalized_path, 0)
    inputs = {}
    for name in ["clean.jsonl", "broken.jsonl", "ollama.jsonl", "manifest.json"]:
        inputs[name] = hashlib.sha256((ROOT / "examples" / name).read_bytes()).hexdigest()
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True,
                          capture_output=True, check=True).stdout.strip()
    dirty = bool(subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, text=True,
                                capture_output=True, check=True).stdout.strip())
    write_json(OUTPUT / "summary.json", {
        "schema_version": 1, "source_commit": head, "working_tree_dirty": dirty,
        "system": platform.system(), "machine": platform.machine(),
        "synthetic_data": True, "real_provider_integration": False,
        "competition_acceptance": False, "input_sha256": inputs, "cases": results,
    })
    print(f"{len(results)} acceptance demonstrations passed; reports: {OUTPUT}")


if __name__ == "__main__":
    main()
