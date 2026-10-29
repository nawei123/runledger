///|
/// Bounded accounting state for already-validated, already-reconciled records.
/// The caller owns diagnostic storage and must not feed duplicate/conflicting IDs.
pub struct UsageFold {
  mut calls : Int32
  mut input : Int64
  mut output : Int64
  mut unknown : Int32
  mut failed : Int32
}

///|
pub fn UsageFold::new() -> UsageFold {
  { calls: 0, input: 0L, output: 0L, unknown: 0, failed: 0, }
}

///|
/// Returns only the diagnostics for this record (at most two); stores no records.
pub fn UsageFold::observe(self : UsageFold, record : Record) -> Array[Finding] {
  let findings : Array[Finding] = []
  let call = record.call
  self.calls += 1
  if call.status == "error" {
    self.failed += 1
  }
  if call.input_tokens is None || call.output_tokens is None {
    self.unknown += 1
    findings.push({
      line: record.line,
      code: "missing_usage",
      message: "input or output usage is unknown",
    })
  }
  let incoming = call.input_tokens.unwrap_or(0L)
  let outgoing = call.output_tokens.unwrap_or(0L)
  if self.input > 9007199254740991L - incoming ||
    self.output > 9007199254740991L - outgoing {
    findings.push({
      line: record.line,
      code: "aggregate_overflow",
      message: "aggregate exceeds interoperable JSON integer range; row usage excluded",
    })
  } else {
    self.input += incoming
    self.output += outgoing
  }
  findings
}

///|
pub fn UsageFold::totals(self : UsageFold) -> Totals {
  {
    calls: self.calls,
    input_tokens: self.input,
    output_tokens: self.output,
    unknown_usage_calls: self.unknown,
    failed_calls: self.failed,
  }
}

///|
/// Indexed, incremental coverage checks; storage is bounded by the manifest cells.
pub struct CoverageIndex {
  manifest : Manifest
  tasks : Map[String, Bool]
  stages : Map[String, Bool]
  covered : Map[(String, String), Bool]
}

///|
pub fn CoverageIndex::new(manifest : Manifest) -> CoverageIndex {
  let tasks : Map[String, Bool] = Map([])
  let stages : Map[String, Bool] = Map([])
  for task in manifest.task_ids {
    tasks.set(task, true)
  }
  for stage in manifest.required_stages {
    stages.set(stage, true)
  }
  {
    manifest: {
      run_id: manifest.run_id,
      model: manifest.model,
      task_ids: manifest.task_ids.copy(),
      required_stages: manifest.required_stages.copy(),
    },
    tasks,
    stages,
    covered: Map([]),
  }
}

///|
pub fn CoverageIndex::observe(
  self : CoverageIndex,
  record : Record,
) -> Array[Finding] {
  let findings : Array[Finding] = []
  let call = record.call
  let mut valid = true
  for
    (matches, code) in [
      (call.run_id == self.manifest.run_id, "unexpected_run"),
      (call.model == self.manifest.model, "unexpected_model"),
      (self.tasks.contains(call.task_id), "unexpected_task"),
      (self.stages.contains(call.stage), "unexpected_stage"),
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
    self.covered.set((call.task_id, call.stage), true)
  }
  findings
}

///|
/// Lazy missing-cell enumeration; does not allocate the task-by-stage product.
pub fn CoverageIndex::missing(self : CoverageIndex) -> Iter[Finding] {
  self.manifest.task_ids
  .iter()
  .flat_map(fn(task) {
    self.manifest.required_stages
    .iter()
    .filter_map(fn(stage) {
      if self.covered.contains((task, stage)) {
        None
      } else {
        Some({
          line: 0,
          code: "missing_stage",
          message: "no successful attempt for task=" + task + ", stage=" + stage,
        })
      }
    })
  })
}
