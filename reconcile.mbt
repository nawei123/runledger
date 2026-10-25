///|
/// Scope call IDs by run. Exact duplicates are counted once and diagnosed.
/// Conflicting copies are excluded entirely rather than trusting the first row.
pub fn reconcile(parsed : Parsed) -> Parsed {
  let first : Map[(String, String), Record] = Map([])
  let conflicts : Map[(String, String), Bool] = Map([])
  let ordered : Array[Record] = []
  let findings = parsed.findings.copy()
  for record in parsed.records {
    let call = record.call
    let key = (call.run_id, call.call_id)
    match first.get(key) {
      None => {
        first.set(key, record)
        ordered.push(record)
      }
      Some(previous) =>
        if @json.to_json(previous.call) == @json.to_json(call) {
          findings.push({
            line: record.line,
            code: "duplicate_call",
            message: "duplicate of line " + previous.line.to_string(),
          })
        } else {
          conflicts.set(key, true)
          findings.push({
            line: record.line,
            code: "conflicting_call",
            message: "conflicts with line " +
            previous.line.to_string() +
            "; all copies excluded",
          })
        }
    }
  }
  let records = ordered.filter(fn(record) {
    !conflicts.contains((record.call.run_id, record.call.call_id))
  })
  { records, findings, }
}
