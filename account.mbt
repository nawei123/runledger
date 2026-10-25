///|
/// Totals describe recorded observations, never estimated provider billing.
pub(all) struct Totals {
  calls : Int32
  input_tokens : Int64
  output_tokens : Int64
  unknown_usage_calls : Int32
  failed_calls : Int32
} derive(ToJson)

///|
pub extend Totals with ToJson::{to_json}

///|
pub(all) struct Report {
  ok : Bool
  usage_complete : Bool
  totals : Totals
  findings : Array[Finding]
} derive(ToJson)

///|
pub extend Report with ToJson::{to_json}

///|
/// Check all request attempts, including failed attempts that may be billable.
/// Missing usage stays unknown; it must never silently become a zero count.
pub fn account(parsed : Parsed) -> Report {
  let findings = parsed.findings.copy()
  let mut input = 0L
  let mut output = 0L
  let mut unknown = 0
  let mut failed = 0
  if parsed.records.is_empty() {
    findings.push({
      line: 0,
      code: "empty_log",
      message: "no reconciled calls available",
    })
  }
  for record in parsed.records {
    let call = record.call
    if call.status == "error" {
      failed += 1
    }
    if call.input_tokens is None || call.output_tokens is None {
      unknown += 1
      findings.push({
        line: record.line,
        code: "missing_usage",
        message: "input or output usage is unknown",
      })
    }
    // Keep aggregate integers exact in JSON and avoid overflowing Int64.
    let incoming = call.input_tokens.unwrap_or(0L)
    let outgoing = call.output_tokens.unwrap_or(0L)
    if input > 9007199254740991L - incoming ||
      output > 9007199254740991L - outgoing {
      findings.push({
        line: record.line,
        code: "aggregate_overflow",
        message: "aggregate exceeds interoperable JSON integer range; row usage excluded",
      })
    } else {
      input += incoming
      output += outgoing
    }
  }
  {
    ok: findings.is_empty(),
    usage_complete: findings.is_empty(),
    totals: {
      calls: parsed.records.length(),
      input_tokens: input,
      output_tokens: output,
      unknown_usage_calls: unknown,
      failed_calls: failed,
    },
    findings,
  }
}

///|
/// Basic audit without an expected task manifest.
pub fn audit(text : String) -> Report {
  account(reconcile(parse_jsonl(text)))
}
