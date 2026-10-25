///|
fn detail_row(id : String, stage : String, usage : String) -> String {
  "{\"run_id\":\"r\",\"task_id\":\"q\",\"call_id\":\"\{id}\",\"stage\":\"\{stage}\",\"model\":\"m\",\"status\":\"ok\",\{usage}}"
}

///|
test "detail preserves basic report and attributes stage totals" {
  let text = detail_row(
      "a", "answer", "\"input_tokens\":10,\"output_tokens\":2",
    ) +
    "\n" +
    detail_row("b", "review", "\"input_tokens\":4,\"output_tokens\":1")
  let detail = @runledger.audit_detail(text, None)
  assert_eq(detail.report.to_json(), @runledger.audit(text).to_json())
  assert_eq(detail.groups.length(), 2)
  assert_eq(detail.groups[0].stage, "answer")
  assert_eq(detail.groups[0].totals.input_tokens, 10L)
  assert_eq(detail.groups[1].totals.input_tokens, 4L)
}

///|
test "detail reports directional unknown counts" {
  let text = detail_row(
      "a", "answer", "\"input_tokens\":null,\"output_tokens\":2",
    ) +
    "\n" +
    detail_row("b", "answer", "\"input_tokens\":4,\"output_tokens\":null")
  let detail = @runledger.audit_detail(text, None)
  assert_false(detail.report.ok)
  assert_eq(detail.groups[0].missing_input_calls, 1)
  assert_eq(detail.groups[0].missing_output_calls, 1)
  assert_eq(detail.diagnostic_counts["missing_usage"], 2)
}

///|
test "detail excludes conflicting identities from all groups" {
  let first = detail_row(
    "a", "answer", "\"input_tokens\":10,\"output_tokens\":2",
  )
  let text = first +
    "\n" +
    first +
    "\n" +
    detail_row("a", "answer", "\"input_tokens\":20,\"output_tokens\":2")
  let detail = @runledger.audit_detail(text, None)
  assert_eq(detail.stats.parsed_calls, 3)
  assert_eq(detail.stats.accepted_calls, 0)
  assert_eq(detail.stats.duplicate_rows, 1)
  assert_eq(detail.stats.conflicting_rows, 1)
  assert_eq(detail.groups.length(), 0)
}

///|
test "aggregate overflow withholds misleading group totals" {
  let text = detail_row(
      "a", "answer", "\"input_tokens\":9007199254740991,\"output_tokens\":0",
    ) +
    "\n" +
    detail_row(
      "b", "review", "\"input_tokens\":9007199254740991,\"output_tokens\":0",
    )
  let detail = @runledger.audit_detail(text, None)
  assert_false(detail.group_totals_available)
  assert_eq(detail.groups.length(), 0)
  assert_eq(detail.stats.accepted_calls, 2)
  assert_eq(detail.diagnostic_counts["aggregate_overflow"], 1)
}
