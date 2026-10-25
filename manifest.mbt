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
  let covered : Map[(String, String), Bool] = Map([])
  for record in parsed.records {
    let call = record.call
    let mut valid = true
    for
      (matches, code) in [
        (call.run_id == manifest.run_id, "unexpected_run"),
        (call.model == manifest.model, "unexpected_model"),
        (manifest.task_ids.contains(call.task_id), "unexpected_task"),
        (manifest.required_stages.contains(call.stage), "unexpected_stage"),
      ] {
      if !matches {
        findings.push({
          line: record.line,
          code,
          message: "record falls outside the expected manifest",
        })
        valid = false
      }
    }
    if valid && call.status == "ok" {
      covered.set((call.task_id, call.stage), true)
    }
  }
  for task in manifest.task_ids {
    for stage in manifest.required_stages {
      if !covered.contains((task, stage)) {
        findings.push({
          line: 0,
          code: "missing_stage",
          message: "no successful attempt for task=" + task + ", stage=" + stage,
        })
      }
    }
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
  let parsed = reconcile(raw)
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
