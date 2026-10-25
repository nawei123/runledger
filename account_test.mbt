///|
fn usage_row(call : String, status : String, usage : String) -> String {
  "{\"run_id\":\"r\",\"task_id\":\"1\",\"stage\":\"answer\",\"call_id\":\"\{call}\",\"model\":\"m\",\"status\":\"\{status}\",\{usage}}"
}

///|
test "failed attempts are included in observed usage" {
  let text = usage_row("a", "error", "\"input_tokens\":10,\"output_tokens\":0") +
    "\n" +
    usage_row("b", "ok", "\"input_tokens\":20,\"output_tokens\":5")
  let report = @runledger.audit(text)
  assert_true(report.ok)
  assert_eq(report.totals.input_tokens, 30L)
  assert_eq(report.totals.output_tokens, 5L)
  assert_eq(report.totals.failed_calls, 1)
}

///|
test "unknown tokens cannot yield a complete report" {
  let report = @runledger.audit(usage_row("a", "ok", "\"input_tokens\":0"))
  assert_false(report.ok)
  assert_false(report.usage_complete)
  assert_eq(report.totals.unknown_usage_calls, 1)
}

///|
test "empty input does not pass" {
  let report = @runledger.audit(" \n\r\n")
  assert_false(report.ok)
  assert_eq(report.findings[0].code, "empty_log")
}

///|
test "aggregate overflow is reported instead of wrapping" {
  let text = usage_row(
      "a", "ok", "\"input_tokens\":9007199254740991,\"output_tokens\":0",
    ) +
    "\n" +
    usage_row("b", "ok", "\"input_tokens\":1,\"output_tokens\":1")
  let report = @runledger.audit(text)
  assert_false(report.ok)
  assert_eq(report.findings[0].code, "aggregate_overflow")
  assert_eq(report.totals.input_tokens, 9007199254740991L)
}
