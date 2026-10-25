"""Exercise the compiled CLI. All fixtures are synthetic; no API is contacted."""
import json
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cmd/runledger/runledger.exe"


class CliTest(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([str(EXE), *map(str, args)], cwd=ROOT,
                              text=True, capture_output=True, check=False)

    def test_clean_manifest(self):
        result = self.run_cli("audit", "examples/clean.jsonl", "examples/manifest.json")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertTrue(report["ok"])
        self.assertEqual(int(report["totals"]["input_tokens"]), 406)
        self.assertEqual(int(report["totals"]["output_tokens"]), 86)

    def test_broken_log_is_not_a_success(self):
        result = self.run_cli("audit", "examples/broken.jsonl", "examples/manifest.json")
        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertFalse(report["ok"])
        codes = {f["code"] for f in report["findings"]}
        self.assertTrue({"duplicate_call", "missing_usage", "unexpected_model", "missing_stage"} <= codes)

    def test_provider_round_trip(self):
        normalized = self.run_cli("normalize-ollama", "examples/ollama.jsonl")
        self.assertEqual(normalized.returncode, 0)
        self.assertEqual(len(normalized.stdout.splitlines()), 4)
        self.assertNotIn("Synthetic example", normalized.stdout)
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "calls with spaces.jsonl"
            path.write_text(normalized.stdout)
            result = self.run_cli("audit", path, "examples/manifest.json")
        direct = self.run_cli("audit-ollama", "examples/ollama.jsonl", "examples/manifest.json")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout), json.loads(direct.stdout))

    def test_io_and_argument_errors(self):
        result = self.run_cli("audit", "not-present.jsonl")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["error"], "cannot_read_input")
        self.assertEqual(self.run_cli("unknown", "examples/clean.jsonl").returncode, 2)

    def test_malformed_rows_preserve_original_lines(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "bad.jsonl"
            path.write_text("\nnot json\n" + (ROOT / "examples/clean.jsonl").read_text())
            result = self.run_cli("audit", path)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)["findings"][0]["line"], 2)

    def test_help(self):
        result = self.run_cli("--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn("normalize-ollama", result.stdout)


if __name__ == "__main__":
    unittest.main()
