///|
test "incremental accounting matches batch including unknown, retry and overflow" {
  let text = "{\"run_id\":\"r\",\"task_id\":\"q\",\"stage\":\"answer\",\"call_id\":\"a\",\"model\":\"m\",\"status\":\"error\",\"input_tokens\":9007199254740991,\"output_tokens\":null}\n{\"run_id\":\"r\",\"task_id\":\"q\",\"stage\":\"review\",\"call_id\":\"b\",\"model\":\"m\",\"status\":\"ok\",\"input_tokens\":1,\"output_tokens\":2}"
  let parsed = @runledger.parse_jsonl(text)
  let fold = @runledger.UsageFold::new()
  let findings = []
  for record in parsed.records {
    for finding in fold.observe(record) {
      findings.push(finding)
    }
  }
  let report = @runledger.account(parsed)
  assert_eq(fold.totals().to_json(), report.totals.to_json())
  assert_eq(Json(findings), Json(report.findings))
}

///|
test "coverage index owns its expectation arrays and enumerates missing cells lazily" {
  let tasks = ["q1", "q2"]
  let stages = ["answer", "review"]
  let manifest : @runledger.Manifest = {
    run_id: "r",
    model: "m",
    task_ids: tasks,
    required_stages: stages,
  }
  let index = @runledger.CoverageIndex::new(manifest)
  tasks.clear()
  stages.clear()
  assert_eq(index.missing().count(), 4)
  assert_eq(
    index.missing().take(1).to_array()[0].message,
    "no successful attempt for task=q1, stage=answer",
  )
}
