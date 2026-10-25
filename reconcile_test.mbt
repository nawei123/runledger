///|
fn row(run : String, call : String, tokens : Int32) -> String {
  "{\"run_id\":\"\{run}\",\"task_id\":\"1\",\"stage\":\"answer\",\"call_id\":\"\{call}\",\"model\":\"m\",\"status\":\"ok\",\"input_tokens\":\{tokens},\"output_tokens\":2}"
}

///|
test "identical duplicates cannot double count usage" {
  let result = @moontrace.reconcile(
    @moontrace.parse_jsonl(row("r", "c", 10) + "\n" + row("r", "c", 10)),
  )
  assert_eq(result.records.length(), 1)
  assert_eq(result.findings[0].code, "duplicate_call")
  assert_eq(result.findings[0].line, 2)
}

///|
test "conflicting counters exclude all copies" {
  let result = @moontrace.reconcile(
    @moontrace.parse_jsonl(
      row("r", "c", 10) + "\n" + row("r", "c", 20) + "\n" + row("r", "c", 10),
    ),
  )
  assert_eq(result.records.length(), 0)
  assert_eq(result.findings[0].code, "conflicting_call")
}

///|
test "call IDs can be reused across separate runs" {
  let result = @moontrace.reconcile(
    @moontrace.parse_jsonl(row("r", "c", 10) + "\n" + row("s", "c", 20)),
  )
  assert_eq(result.records.length(), 2)
  assert_eq(result.findings.length(), 0)
}
