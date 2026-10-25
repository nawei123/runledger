///|
fn envelope(response : String) -> String {
  "{\"run_id\":\"r\",\"task_id\":\"1\",\"stage\":\"answer\",\"call_id\":\"c\",\"model\":\"m\",\"response\":" +
  response +
  "}"
}

///|
test "normalize final Ollama response and round trip without text" {
  let parsed = @runledger.import_ollama(
    envelope(
      "{\"model\":\"m\",\"done\":true,\"prompt_eval_count\":10,\"eval_count\":3,\"message\":{\"content\":\"secret prompt data\"}}",
    ),
  )
  assert_eq(parsed.findings.length(), 0)
  let encoded = @runledger.encode_call(parsed.records[0].call).stringify()
  assert_false(encoded.contains("secret"))
  let decoded = @runledger.parse_jsonl(encoded)
  assert_eq(decoded.findings.length(), 0)
  assert_eq(decoded.records[0].call.output_tokens, Some(3L))
}

///|
test "partial streams and mismatched models are rejected" {
  for
    response in [
      "{\"model\":\"m\",\"done\":false}", "{\"model\":\"wrong\",\"done\":true}",
    ] {
    let parsed = @runledger.import_ollama(envelope(response))
    assert_eq(parsed.records.length(), 0)
    assert_eq(parsed.findings[0].code, "invalid_provider_record")
  }
}

///|
test "provider errors preserve unknown usage" {
  let parsed = @runledger.import_ollama(envelope("{\"error\":\"unavailable\"}"))
  assert_eq(parsed.findings.length(), 0)
  assert_eq(parsed.records[0].call.status, "error")
  assert_false(@runledger.account(parsed).usage_complete)
}
