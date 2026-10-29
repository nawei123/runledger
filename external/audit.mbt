///|
priv struct Findings {
  writer : @disk.File
  sample_limit : Int32
  sample : Array[@ledger.Finding]
  counts : Map[String, Int64]
  mut sample_bytes : Int32
  mut total : Int64
  mut usage_complete : Bool
}

///|
fn Findings::add(
  self : Findings,
  finding : @ledger.Finding,
  affects_usage : Bool,
) -> Unit raise {
  let text = @json.to_json(finding).stringify()
  self.writer.write_line(text)
  self.counts.set(
    finding.code,
    self.counts.get(finding.code).unwrap_or(0L) + 1L,
  )
  self.total += 1L
  if affects_usage {
    self.usage_complete = false
  }
  let size = @utf8.encode(text).length()
  if self.sample.length() < self.sample_limit &&
    size <= 65536 - self.sample_bytes {
    self.sample.push(finding)
    self.sample_bytes += size
  }
}

///|
fn copy_findings(path : String, sink : Findings) -> Unit raise {
  verify(path)
  let reader = @disk.open(path)
  defer reader.close()
  while true {
    match reader.read_line(16384) {
      End => break
      Text(text) => {
        guard @json.parse(text, reject_duplicate_keys=true) is Object(obj) else {
          raise EngineError("invalid intermediate diagnostic")
        }
        sink.add(
          {
            line: int_field(obj, "line"),
            code: text_field(obj, "code"),
            message: text_field(obj, "message"),
          },
          true,
        )
      }
      _ =>
        raise EngineError("invalid intermediate diagnostic encoding or length")
    }
  }
}

///|
fn audit_sorted(
  state : State,
  control : Control,
  options : Options,
  manifest : @ledger.Manifest?,
  source_sha : String,
  source_size : Int64,
  manifest_sha : String,
) -> Json raise {
  let directory = control.directory
  let diag = directory + "/findings.jsonl"
  let writer = @disk.open(diag + ".tmp", write=true)
  defer writer.close()
  let sink : Findings = {
    writer,
    sample_limit: options.sample_limit,
    sample: [],
    counts: Map([]),
    sample_bytes: 0,
    total: 0L,
    usage_complete: true,
  }
  for i = 0; i < state.ingest_runs; i = i + 1 {
    copy_findings(directory + "/parse-" + i.to_string() + ".jsonl", sink)
  }
  copy_findings(directory + "/identity-findings.jsonl", sink)
  let path = run_path(directory, "order", state.order_generation, 0)
  verify(path)
  let reader = @disk.open(path)
  defer reader.close()
  let fold = @ledger.UsageFold::new()
  let coverage = manifest.map(@ledger.CoverageIndex::new)
  while next_record(reader, options.max_line_bytes + 1024) is Some(record) {
    for finding in fold.observe(record) {
      sink.add(finding, true)
    }
    if coverage is Some(index) {
      for finding in index.observe(record) {
        sink.add(finding, false)
      }
    }
  }
  if fold.totals().calls == 0 {
    sink.add(
      { line: 0, code: "empty_log", message: "no reconciled calls available", },
      true,
    )
  }
  if coverage is Some(index) {
    for finding in index.missing() {
      sink.add(finding, false)
    }
  }
  writer.sync()
  writer.close()
  seal(diag, directory)
  let result = Json::object(
    Map([
      ("schema_version", @json.to_json(1)),
      ("engine", Json::string("external-merge/0.3.0")),
      ("status", Json::string("complete")),
      (
        "report",
        Json::object(
          Map([
            ("ok", @json.to_json(sink.total == 0L)),
            ("usage_complete", @json.to_json(sink.usage_complete)),
            ("totals", @json.to_json(fold.totals())),
            ("diagnostic_count", @json.to_json(sink.total)),
            ("diagnostic_counts", @json.to_json(sink.counts)),
            ("sample_findings", @json.to_json(sink.sample)),
            (
              "sample_truncated",
              @json.to_json(sink.total > sink.sample.length().to_int64()),
            ),
          ]),
        ),
      ),
      ("resources", @json.to_json(options)),
      (
        "input",
        Json::object(
          Map([
            ("sha256", Json::string(source_sha)),
            ("bytes", @json.to_json(source_size)),
            ("physical_lines", @json.to_json(state.input_line)),
            ("parsed_calls", @json.to_json(state.parsed_calls)),
            ("manifest_sha256", Json::string(manifest_sha)),
          ]),
        ),
      ),
      (
        "external_sort",
        Json::object(
          Map([
            ("ingest_runs", @json.to_json(state.ingest_runs)),
            (
              "identity_merge_generations",
              @json.to_json(state.identity_generation),
            ),
            ("order_merge_generations", @json.to_json(state.order_generation)),
          ]),
        ),
      ),
      (
        "artifacts",
        Json::object(
          Map([
            ("findings", Json::string("findings.jsonl")),
            ("findings_sha256", Json::string(@disk.file_sha256(diag))),
            (
              "accepted_records",
              Json::string(
                "order-g" + state.order_generation.to_string() + "-r0.jsonl",
              ),
            ),
            ("accepted_records_sha256", Json::string(@disk.file_sha256(path))),
          ]),
        ),
      ),
    ]),
  )
  result
}
