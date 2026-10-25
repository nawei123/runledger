"""Real SDK export -> MoonBit audit. Model usage is intentionally synthetic."""
import importlib.metadata
import io
import json
import pathlib
import subprocess

from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import ConsoleSpanExporter, SimpleSpanProcessor
from opentelemetry.trace import SpanKind, Status, StatusCode

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "reports/otel-interop"
EXE = ROOT / "_build/native/debug/build/cmd/runledger/runledger.exe"


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    stream = io.StringIO()
    provider = TracerProvider()
    exporter = ConsoleSpanExporter(out=stream, formatter=lambda span: span.to_json(indent=None) + "\n")
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    tracer = provider.get_tracer("runledger.interop")
    for index, (task, stage) in enumerate((t, s) for t in ["q1", "q2"] for s in ["answer", "review"]):
        with tracer.start_as_current_span("model." + stage, kind=SpanKind.CLIENT) as span:
            span.set_attributes({
                "gen_ai.operation.name": "chat", "gen_ai.response.model": "demo-model",
                "runledger.run_id": "demo-001", "runledger.task_id": task, "runledger.stage": stage,
                "gen_ai.usage.input_tokens": 100 + index, "gen_ai.usage.output_tokens": 20 + index,
                "gen_ai.usage.cache_read.input_tokens": 40,
                "input.value": "Synthetic prompt; normalization must drop this content.",
            })
            span.set_status(Status(StatusCode.OK))
    provider.force_flush()
    source = OUTPUT / "sdk-spans.jsonl"
    source.write_text(stream.getvalue(), encoding="utf-8")
    parsed_spans = [json.loads(line) for line in stream.getvalue().splitlines()]
    assert len(parsed_spans) == 4 and all(x["status"]["status_code"] == "OK" for x in parsed_spans)
    audit = subprocess.run([str(EXE), "audit-spans", str(source), "examples/manifest.json"],
                           cwd=ROOT, text=True, capture_output=True, check=True)
    report = json.loads(audit.stdout)
    assert report["ok"] and report["totals"]["calls"] == 4
    assert int(report["totals"]["input_tokens"]) == 406
    assert int(report["totals"]["output_tokens"]) == 86
    normalized = subprocess.run([str(EXE), "normalize-spans", str(source)], cwd=ROOT,
                                text=True, capture_output=True, check=True)
    assert "Synthetic prompt" not in normalized.stdout
    normalized_path = OUTPUT / "normalized.jsonl"
    normalized_path.write_text(normalized.stdout, encoding="utf-8")
    detail = subprocess.run([str(EXE), "audit-detail", str(normalized_path), "examples/manifest.json"],
                            cwd=ROOT, text=True, capture_output=True, check=True)
    detailed = json.loads(detail.stdout)
    assert len(detailed["groups"]) == 2
    assert sum(int(group["totals"]["input_tokens"]) for group in detailed["groups"]) == 406
    (OUTPUT / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (OUTPUT / "detail.json").write_text(json.dumps(detailed, indent=2) + "\n", encoding="utf-8")
    metadata = {"sdk": "opentelemetry-sdk", "sdk_version": importlib.metadata.version("opentelemetry-sdk"),
                "real_sdk_execution": True, "real_model_execution": False,
                "synthetic_model_usage": True, "captured_spans": 4,
                "input_tokens": 406, "output_tokens": 86, "passed": True}
    (OUTPUT / "provenance.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    print("SDK interoperability passed: 4 real SDK spans, synthetic model usage, no provider/API call")


if __name__ == "__main__":
    main()
