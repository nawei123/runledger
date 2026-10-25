///|
test "parse a valid record and preserve physical line number" {
  let parsed = parse_jsonl(
    "\n{\"run_id\":\"r\",\"task_id\":\"1\",\"stage\":\"answer\",\"call_id\":\"c\",\"model\":\"m\",\"status\":\"ok\",\"input_tokens\":10,\"output_tokens\":0}\r\n",
  )
  assert_eq(parsed.findings.length(), 0)
  assert_eq(parsed.records.length(), 1)
  assert_eq(parsed.records[0].line, 2)
  assert_eq(parsed.records[0].call.input_tokens, Some(10L))
}

///|
test "bad syntax and schema are reported rather than silently skipped" {
  let parsed = parse_jsonl("{\n{}\n{\"run_id\":\"r\",\"run_id\":\"x\"}\n")
  assert_eq(parsed.findings.length(), 3)
  assert_eq(parsed.findings[0].code, "invalid_json")
  assert_eq(parsed.findings[1].code, "invalid_record")
  assert_eq(parsed.findings[2].code, "invalid_json")
}

///|
test "reject negative fractional string and oversized counters" {
  for value in ["-1", "1.25", "\"3\"", "9007199254740992", "true"] {
    let text = "{\"run_id\":\"r\",\"task_id\":\"1\",\"stage\":\"a\",\"call_id\":\"c\",\"model\":\"m\",\"status\":\"ok\",\"input_tokens\":" +
      value +
      "}"
    assert_eq(parse_jsonl(text).findings.length(), 1)
  }
}
