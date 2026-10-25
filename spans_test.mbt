///|
fn sdk_row(extra : String, state : String) -> String {
  "{\"context\":{\"trace_id\":\"0xabcdef1234567890abcdef1234567890\",\"span_id\":\"0x1234567890abcdef\"},\"end_time\":\"2026-10-26T00:00:00Z\",\"status\":{\"status_code\":\"\{state}\"},\"attributes\":{\"gen_ai.operation.name\":\"chat\",\"gen_ai.response.model\":\"m\",\"runledger.run_id\":\"r\",\"runledger.task_id\":\"q\",\"runledger.stage\":\"answer\",\{extra}}}"
}

///|
test "SDK profile keeps inclusive totals without adding cached detail" {
  let parsed = @runledger.import_spans(
    sdk_row(
      "\"gen_ai.usage.input_tokens\":100,\"gen_ai.usage.output_tokens\":20,\"gen_ai.usage.cache_read.input_tokens\":40",
      "OK",
    ),
  )
  assert_eq(parsed.findings.length(), 0)
  assert_eq(parsed.records[0].call.input_tokens, Some(100L))
  assert_eq(
    parsed.records[0].call.call_id,
    "abcdef1234567890abcdef1234567890/1234567890abcdef",
  )
}

///|
test "UNSET status is unknown rather than successful task completion" {
  let parsed = @runledger.import_spans(
    sdk_row("\"gen_ai.usage.input_tokens\":1", "UNSET"),
  )
  assert_eq(parsed.records.length(), 0)
  assert_eq(parsed.findings[0].code, "invalid_span")
}

///|
test "parent spans cannot masquerade as billable model attempts" {
  let parsed = @runledger.import_spans(
    sdk_row("\"openinference.span.kind\":\"AGENT\"", "OK"),
  )
  assert_eq(parsed.records.length(), 0)
  assert_eq(parsed.findings.length(), 1)
}

///|
test "task metadata must be explicit" {
  let text = sdk_row("\"gen_ai.usage.input_tokens\":1", "OK").replace(
    old="\"runledger.task_id\":\"q\",",
    new="",
  )
  assert_eq(@runledger.import_spans(text).findings[0].code, "invalid_span")
}

///|
test "conflicting token conventions fail rather than picking one" {
  let parsed = @runledger.import_spans(
    sdk_row(
      "\"gen_ai.usage.input_tokens\":100,\"llm.token_count.prompt\":60", "OK",
    ),
  )
  assert_eq(parsed.records.length(), 0)
  assert_eq(parsed.findings[0].code, "invalid_span")
}

///|
test "OpenInference LLM attributes have a defined mapping" {
  let text = sdk_row(
      "\"llm.token_count.prompt\":10,\"llm.token_count.completion\":2", "ERROR",
    )
    .replace(
      old="\"gen_ai.operation.name\":\"chat\"",
      new="\"openinference.span.kind\":\"LLM\"",
    )
    .replace(old="gen_ai.response.model", new="llm.model_name")
  let parsed = @runledger.import_spans(text)
  assert_eq(parsed.findings.length(), 0)
  assert_eq(parsed.records[0].call.status, "error")
  assert_eq(parsed.records[0].call.output_tokens, Some(2L))
}

///|
test "trace identity prevents collisions when experiment spans are merged" {
  let first = sdk_row(
    "\"gen_ai.usage.input_tokens\":10,\"gen_ai.usage.output_tokens\":2", "OK",
  )
  let second = first.replace(
    old="abcdef1234567890abcdef1234567890",
    new="bbcdef1234567890abcdef1234567890",
  )
  let report = @runledger.audit_records(
    @runledger.import_spans(first + "\n" + second),
    None,
  )
  assert_true(report.ok)
  assert_eq(report.totals.calls, 2)
}

///|
test "identifier case and prefix normalization detect duplicate exports" {
  let first = sdk_row(
    "\"gen_ai.usage.input_tokens\":10,\"gen_ai.usage.output_tokens\":2", "OK",
  )
  let second = first.replace(
    old="0xabcdef1234567890abcdef1234567890",
    new="ABCDEF1234567890ABCDEF1234567890",
  )
  let report = @runledger.audit_records(
    @runledger.import_spans(first + "\n" + second),
    None,
  )
  assert_eq(report.totals.calls, 1)
  assert_eq(report.findings[0].code, "duplicate_call")
}

///|
test "unknown usage and error status remain observable" {
  let report = @runledger.audit_records(
    @runledger.import_spans(sdk_row("\"gen_ai.usage.input_tokens\":1", "ERROR")),
    None,
  )
  assert_false(report.usage_complete)
  assert_eq(report.totals.failed_calls, 1)
  assert_eq(report.totals.unknown_usage_calls, 1)
}

///|
test "normalization does not retain prompt or output content" {
  let parsed = @runledger.import_spans(
    sdk_row(
      "\"gen_ai.usage.input_tokens\":1,\"gen_ai.usage.output_tokens\":2,\"input.value\":\"private-content\"",
      "OK",
    ),
  )
  let encoded = @runledger.encode_call(parsed.records[0].call).stringify()
  assert_false(encoded.contains("private-content"))
}
