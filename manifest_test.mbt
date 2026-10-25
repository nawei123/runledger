///|
let expectation : String = "{\"run_id\":\"r\",\"model\":\"m\",\"task_ids\":[\"1\",\"2\"],\"required_stages\":[\"answer\",\"review\"]}"

///|
fn coverage_row(
  run : String,
  model : String,
  task : String,
  stage : String,
  status : String,
) -> String {
  "{\"run_id\":\"\{run}\",\"model\":\"\{model}\",\"task_id\":\"\{task}\",\"stage\":\"\{stage}\",\"status\":\"\{status}\",\"call_id\":\"\{task}-\{stage}\",\"input_tokens\":2,\"output_tokens\":1}"
}

///|
test "manifest detects wholly missing tasks" {
  let text = coverage_row("r", "m", "1", "answer", "ok") +
    "\n" +
    coverage_row("r", "m", "1", "review", "ok")
  let report = @runledger.audit_with_manifest(text, expectation)
  assert_false(report.ok)
  assert_true(report.usage_complete)
  assert_eq(report.findings.length(), 2)
  assert_eq(report.findings[0].code, "missing_stage")
}

///|
test "wrong run model and failed attempts cannot satisfy coverage" {
  for
    text in [
      coverage_row("wrong", "m", "1", "answer", "ok"),
      coverage_row("r", "wrong", "1", "answer", "ok"),
      coverage_row("r", "m", "1", "answer", "error"),
    ] {
    let report = @runledger.audit_with_manifest(text, expectation)
    assert_false(report.ok)
    assert_true(report.findings.length() >= 4)
  }
}

///|
test "complete two-task workflow passes" {
  let rows : Array[String] = []
  for task in ["1", "2"] {
    for stage in ["answer", "review"] {
      rows.push(coverage_row("r", "m", task, stage, "ok"))
    }
  }
  let report = @runledger.audit_with_manifest(rows.join("\n"), expectation)
  assert_true(report.ok)
  assert_eq(report.totals.calls, 4)
}

///|
test "duplicate task definitions are rejected" {
  let report = @runledger.audit_with_manifest(
    "", "{\"run_id\":\"r\",\"model\":\"m\",\"task_ids\":[\"1\",\"1\"],\"required_stages\":[\"answer\"]}",
  )
  assert_eq(
    report.findings[report.findings.length() - 1].code,
    "invalid_manifest",
  )
}
