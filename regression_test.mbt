///|
fn generated_row(task : String, stage : String, id : String) -> String {
  "{\"run_id\":\"large-run\",\"task_id\":\"\{task}\",\"stage\":\"\{stage}\",\"call_id\":\"\{id}\",\"model\":\"one-model\",\"status\":\"ok\",\"input_tokens\":10,\"output_tokens\":5}"
}

///|
test "100-task manifest requires every answer and review" {
  let rows : Array[String] = []
  let tasks : Array[Json] = []
  for i in 0..<100 {
    let task = i.to_string()
    tasks.push(Json::string(task))
    for stage in ["answer", "review"] {
      // Leave precisely the last review out; all task IDs still appear.
      if i == 99 && stage == "review" {
        continue
      }
      rows.push(generated_row(task, stage, task + stage))
    }
  }
  let manifest : Json = {
    "run_id": "large-run",
    "model": "one-model",
    "task_ids": Json::array(tasks),
    "required_stages": ["answer", "review"],
  }
  let report = @runledger.audit_with_manifest(
    rows.join("\n"),
    manifest.stringify(),
  )
  assert_false(report.ok)
  assert_eq(report.findings.length(), 1)
  assert_eq(report.findings[0].code, "missing_stage")
  rows.push(generated_row("99", "review", "99review"))
  let complete = @runledger.audit_with_manifest(
    rows.join("\n"),
    manifest.stringify(),
  )
  assert_true(complete.ok)
  assert_eq(complete.totals.calls, 200)
  assert_eq(complete.totals.input_tokens, 2000L)
}

///|
test "canonical ToJson round trip preserves max exact counter" {
  let text = "{\"run_id\":\"r\",\"task_id\":\"1\",\"stage\":\"answer\",\"call_id\":\"c\",\"model\":\"m\",\"status\":\"ok\",\"input_tokens\":9007199254740991,\"output_tokens\":0}"
  let call = @runledger.parse_jsonl(text).records[0].call
  let encoded = call.to_json().stringify()
  let result = @runledger.parse_jsonl(encoded)
  assert_eq(result.findings.length(), 0)
  assert_eq(result.records[0].call.input_tokens, Some(9007199254740991L))
}

///|
test "unknown schema status is rejected" {
  let text = generated_row("q", "answer", "c").replace(
    old="\"status\":\"ok\"",
    new="\"status\":\"pending\"",
  )
  assert_eq(@runledger.parse_jsonl(text).findings[0].code, "invalid_record")
}

///|
test "adapter error line remains visible even alongside valid responses" {
  let parsed = @runledger.import_ollama("\n{\"response\":{\"done\":false}}\n")
  let report = @runledger.audit_records(parsed, None)
  assert_false(report.ok)
  assert_eq(report.findings[0].line, 2)
  assert_eq(report.findings[0].code, "invalid_provider_record")
}
