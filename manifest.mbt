///|
/// An external expectation catches tasks that are wholly absent from the log.
pub(all) struct Manifest {
  run_id : String
  model : String
  task_ids : Array[String]
  required_stages : Array[String]
} derive(ToJson)

///|
pub extend Manifest with ToJson::{to_json}

///|
fn string_list(
  obj : Map[String, Json],
  key : String,
) -> Array[String] raise DecodeError {
  guard obj.get(key) is Some(Array(items)) && !items.is_empty() else {
    raise DecodeError("expected nonempty string list: " + key)
  }
  let result : Array[String] = []
  let seen : Map[String, Bool] = Map([])
  for item in items {
    guard item is String(text) && !text.trim().is_empty() else {
      raise DecodeError("invalid list element: " + key)
    }
    if seen.contains(text) {
      raise DecodeError("duplicate list element: " + key)
    }
    seen.set(text, true)
    result.push(text)
  }
  result
}

///|
pub fn decode_manifest(value : Json) -> Manifest raise DecodeError {
  guard value is Object(obj) else {
    raise DecodeError("expected manifest object")
  }
  {
    run_id: required_string(obj, "run_id"),
    model: required_string(obj, "model"),
    task_ids: string_list(obj, "task_ids"),
    required_stages: string_list(obj, "required_stages"),
  }
}

///|
/// Only successful attempts in the declared run/model may satisfy coverage.
pub fn check_coverage(parsed : Parsed, manifest : Manifest) -> Array[Finding] {
  let findings : Array[Finding] = []
  let index = CoverageIndex::new(manifest)
  for record in parsed.records {
    for finding in index.observe(record) {
      findings.push(finding)
    }
  }
  for finding in index.missing() {
    findings.push(finding)
  }
  findings
}

///|
/// Audit using an explicit run, model and task-stage coverage contract.
pub fn audit_with_manifest(text : String, manifest_text : String) -> Report {
  audit_records(parse_jsonl(text), Some(manifest_text))
}

///|
/// Preserve adapter diagnostics and original line numbers through reconciliation.
pub fn audit_records(raw : Parsed, manifest_text : String?) -> Report {
  audit_reconciled(reconcile(raw), manifest_text)
}

///|
/// Shared path for callers that already reconciled identities.
fn audit_reconciled(parsed : Parsed, manifest_text : String?) -> Report {
  let report = account(parsed)
  guard manifest_text is Some(manifest_text) else { return report }
  let findings = report.findings.copy()
  let manifest = decode_manifest(
    @json.parse(manifest_text, reject_duplicate_keys=true),
  ) catch {
    _ => {
      findings.push({
        line: 0,
        code: "invalid_manifest",
        message: "invalid manifest: require run_id, model, unique nonempty task_ids and required_stages",
      })
      return {
        ok: false,
        usage_complete: report.usage_complete,
        totals: report.totals,
        findings,
      }
    }
  }
  for finding in check_coverage(parsed, manifest) {
    findings.push(finding)
  }
  {
    ok: findings.is_empty(),
    usage_complete: report.usage_complete,
    totals: report.totals,
    findings,
  }
}
