"""Check a published release from an independent consumer, without path dependencies."""
import argparse
import json
import pathlib
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--moon", default="moon")
    parser.add_argument("--version", default="0.1.1")
    args = parser.parse_args()
    module = "nawei123/runledger"
    # Explicit tool paths must survive the change of working directory.
    moon = str(pathlib.Path(args.moon).resolve()) if "/" in args.moon else args.moon
    with tempfile.TemporaryDirectory(prefix="runledger-consumer-") as directory:
        root = pathlib.Path(directory)
        (root / "moon.mod").write_text(
            'name = "runledger-check/consumer"\nversion = "0.0.1"\n'
            'preferred_target = "native"\nimport {\n  '
            + json.dumps(module + "@" + args.version) + ',\n}\n', encoding="utf-8")
        (root / "moon.pkg").write_text('import { "nawei123/runledger" @ledger, } for "test"\n', encoding="utf-8")
        (root / "consumer_test.mbt").write_text('''test "public API detects missing review" {
  let text = "{\\"run_id\\":\\"r\\",\\"task_id\\":\\"q\\",\\"stage\\":\\"answer\\",\\"call_id\\":\\"c\\",\\"model\\":\\"m\\",\\"status\\":\\"ok\\",\\"input_tokens\\":10,\\"output_tokens\\":2}"
  let manifest = "{\\"run_id\\":\\"r\\",\\"model\\":\\"m\\",\\"task_ids\\":[\\"q\\"],\\"required_stages\\":[\\"answer\\",\\"review\\"]}"
  let report = @ledger.audit_with_manifest(text, manifest)
  assert_false(report.ok)
  assert_true(report.usage_complete)
  assert_eq(report.findings.length(), 1)
  assert_eq(report.findings[0].code, "missing_stage")
  assert_eq(report.totals.input_tokens, 10L)
}
''', encoding="utf-8")
        for command in [[moon, "update"], [moon, "test", "--deny-warn"],
                        [moon, "test", "--target", "wasm-gc", "--deny-warn"]]:
            subprocess.run(command, cwd=root, check=True)
        print(f"Published consumer verified: {module}@{args.version} (native and wasm-gc)")


if __name__ == "__main__":
    main()
