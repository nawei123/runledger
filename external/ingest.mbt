///|
fn parse_line(text : String, format : String) -> @ledger.Parsed {
  match format {
    "ollama" => @ledger.import_ollama(text)
    "sdk" => @ledger.import_spans(text)
    _ => @ledger.parse_jsonl(text)
  }
}

///|
fn ingest(
  source : String,
  expected_sha : String,
  state : State,
  control : Control,
  options : Options,
) -> Unit raise {
  let reader = @disk.open(source)
  defer reader.close()
  reader.seek(state.input_offset)
  let mut ended = false
  while !ended {
    let rows : Array[@ledger.Record] = []
    let path = run_path(control.directory, "identity", 0, state.ingest_runs)
    let diag = control.directory +
      "/parse-" +
      state.ingest_runs.to_string() +
      ".jsonl"
    let writer = @disk.open(diag + ".tmp", write=true)
    defer writer.close()
    let start = reader.position()
    let mut batch_lines = 0
    while batch_lines < options.batch_rows &&
          reader.position() - start < options.batch_bytes.to_int64() {
      let line = reader.read_line(options.max_line_bytes)
      if line is End {
        ended = true
        break
      }
      if state.input_line == 2147483646 {
        raise EngineError("physical line limit exceeded")
      }
      state.input_line += 1
      batch_lines += 1
      match line {
        Text(text) => {
          let parsed = parse_line(text, options.format)
          for record in parsed.records {
            rows.push({ line: state.input_line, call: record.call, })
            state.parsed_calls += 1
          }
          for finding in parsed.findings {
            emit(writer, {
              line: state.input_line,
              code: finding.code,
              message: finding.message,
            })
          }
        }
        TooLong =>
          emit(writer, {
            line: state.input_line,
            code: "line_too_long",
            message: "physical line exceeds configured byte limit; record rejected",
          })
        InvalidUtf8 =>
          emit(writer, {
            line: state.input_line,
            code: "invalid_utf8",
            message: "physical line is not valid UTF-8; record rejected",
          })
        End => ()
      }
    }
    if batch_lines == 0 && state.ingest_runs > 0 {
      writer.close()
      @fs.remove_file(diag + ".tmp")
      break
    }
    write_run(rows, path, control.directory, false)
    writer.sync()
    writer.close()
    seal(diag, control.directory)
    state.input_offset = reader.position()
    state.ingest_runs += 1
    control.save(state)
  }
  // Binding is checked again after ingestion so mid-read source changes cannot complete silently.
  if @disk.file_sha256(source) != expected_sha {
    raise EngineError("source changed during ingestion; use a new workspace")
  }
  state.phase = 1
  state.generation = 0
  state.runs = state.ingest_runs
  state.next_group = 0
  control.save(state)
}

///|
fn reconcile_sorted(
  state : State,
  control : Control,
  options : Options,
) -> Unit raise {
  let path = run_path(
    control.directory,
    "identity",
    state.identity_generation,
    0,
  )
  verify(path)
  let reader = @disk.open(path)
  defer reader.close()
  let diag = control.directory + "/identity-findings.jsonl"
  let writer = @disk.open(diag + ".tmp", write=true)
  defer writer.close()
  let chunks : OrderChunks = {
    directory: control.directory,
    options,
    rows: [],
    bytes: 0,
    runs: 0,
  }
  let mut first : @ledger.Record? = None
  let mut canonical = ""
  let mut conflicted = false
  while next_record(reader, options.max_line_bytes + 1024) is Some(record) {
    match first {
      Some(previous) if previous.call.run_id == record.call.run_id &&
        previous.call.call_id == record.call.call_id =>
        if @json.to_json(record.call).stringify() == canonical {
          emit(writer, {
            line: record.line,
            code: "duplicate_call",
            message: "duplicate of line " + previous.line.to_string(),
          })
        } else {
          conflicted = true
          emit(writer, {
            line: record.line,
            code: "conflicting_call",
            message: "conflicts with line " +
            previous.line.to_string() +
            "; all copies excluded",
          })
        }
      _ => {
        if first is Some(previous) && !conflicted {
          chunks.push(previous)
        }
        first = Some(record)
        canonical = @json.to_json(record.call).stringify()
        conflicted = false
      }
    }
  }
  if first is Some(previous) && !conflicted {
    chunks.push(previous)
  }
  if !chunks.rows.is_empty() || chunks.runs == 0 {
    chunks.flush()
  }
  writer.sync()
  writer.close()
  seal(diag, control.directory)
  state.runs = chunks.runs
  state.generation = 0
  state.next_group = 0
  state.phase = 3
  control.save(state)
}
