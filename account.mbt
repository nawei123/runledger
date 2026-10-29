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
  let fold = UsageFold::new()
  if parsed.records.is_empty() {
    findings.push({
      line: 0,
      code: "empty_log",
      message: "no reconciled calls available",
    })
  }
  for record in parsed.records {
    for finding in fold.observe(record) {
      findings.push(finding)
    }
  }
  {
    ok: findings.is_empty(),
    usage_complete: findings.is_empty(),
    totals: fold.totals(),
    findings,
  }
}

///|
/// Basic audit without an expected task manifest.
pub fn audit(text : String) -> Report {
  account(reconcile(parse_jsonl(text)))
}
