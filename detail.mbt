///|
/// Usage attributed to one run, stage and model after reconciliation.
pub(all) struct UsageGroup {
  run_id : String
  stage : String
  model : String
  totals : Totals
  usage_complete : Bool
  missing_input_calls : Int32
  missing_output_calls : Int32
} derive(ToJson)

///|
pub extend UsageGroup with ToJson::{to_json}

///|
/// Row counts distinguish decoding, duplicate copies and accepted identities.
pub(all) struct AuditStats {
  parsed_calls : Int32
  accepted_calls : Int32
  duplicate_rows : Int32
  conflicting_rows : Int32
} derive(ToJson)

///|
pub extend AuditStats with ToJson::{to_json}

///|
/// Additive envelope; the existing Report and audit commands remain unchanged.
pub(all) struct DetailedReport {
  schema_version : Int32
  report : Report
  stats : AuditStats
  groups : Array[UsageGroup]
  diagnostic_counts : Map[String, Int32]
} derive(ToJson)

///|
pub extend DetailedReport with ToJson::{to_json}

///|
/// Group order follows first accepted occurrence; no prompt or output is retained.
pub fn detail_records(raw : Parsed, manifest_text : String?) -> DetailedReport {
  let parsed = reconcile(raw)
  let report = audit_reconciled(parsed, manifest_text)
  let counts : Map[String, Int32] = Map([])
  for finding in report.findings {
    counts.set(finding.code, counts.get(finding.code).unwrap_or(0) + 1)
  }
  let members : Map[(String, String, String), Array[Record]] = Map([])
  let order : Array[(String, String, String)] = []
  for record in parsed.records {
    let call = record.call
    let key = (call.run_id, call.stage, call.model)
    match members.get(key) {
      Some(rows) => rows.push(record)
      None => {
        members.set(key, [record])
        order.push(key)
      }
    }
  }
  let groups : Array[UsageGroup] = []
  for key in order {
    let rows = members[key]
    let group = account({ records: rows, findings: [], })
    let mut missing_input = 0
    let mut missing_output = 0
    for row in rows {
      if row.call.input_tokens is None {
        missing_input += 1
      }
      if row.call.output_tokens is None {
        missing_output += 1
      }
    }
    groups.push({
      run_id: key.0,
      stage: key.1,
      model: key.2,
      totals: group.totals,
      usage_complete: group.usage_complete,
      missing_input_calls: missing_input,
      missing_output_calls: missing_output,
    })
  }
  {
    schema_version: 1,
    report,
    stats: {
      parsed_calls: raw.records.length(),
      accepted_calls: parsed.records.length(),
      duplicate_rows: counts.get("duplicate_call").unwrap_or(0),
      conflicting_rows: counts.get("conflicting_call").unwrap_or(0),
    },
    groups,
    diagnostic_counts: counts,
  }
}

///|
/// Detailed normalized-JSONL audit with optional expected task manifest.
pub fn audit_detail(text : String, manifest_text : String?) -> DetailedReport {
  detail_records(parse_jsonl(text), manifest_text)
}
