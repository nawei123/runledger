///|
/// Native POSIX external audit. New workspaces are exclusive, resume is content-bound.
/// Intermediate records omit provider prompt/output payloads; identifiers remain sensitive.
pub fn run(
  source : String,
  directory : String,
  manifest_path : String?,
  options : Options,
  recover~ : Bool = false,
  pause_after~ : Int32 = 0,
) -> Json raise {
  options.validate()
  if pause_after < 0 {
    raise EngineError("pause_after must be nonnegative")
  }
  let source_size = @disk.file_size(source)
  if source_size > 9007199254740991L {
    raise EngineError("source exceeds exact checkpoint offset range")
  }
  let source_sha = @disk.file_sha256(source)
  if @disk.file_size(source) != source_size {
    raise EngineError("source changed during fingerprinting")
  }
  let (manifest, manifest_sha) = match manifest_path {
    None => (None, "")
    Some(path) => {
      let digest = @disk.file_sha256(path)
      let text = read_small(path, 4L * 1024L * 1024L)
      if @disk.sha256(text) != digest || @disk.file_sha256(path) != digest {
        raise EngineError("manifest changed while reading")
      }
      let manifest = @ledger.decode_manifest(
        @json.parse(text, reject_duplicate_keys=true),
      )
      if manifest.task_ids.length().to_int64() *
        manifest.required_stages.length().to_int64() >
        1000000L {
        raise EngineError("manifest exceeds one million task-stage cells")
      }
      (Some(manifest), digest)
    }
  }
  let binding_data = Json::object(
    Map([
      ("version", Json::string("external-merge/0.3.0")),
      ("source_sha256", Json::string(source_sha)),
      ("source_size", @json.to_json(source_size)),
      ("manifest_sha256", Json::string(manifest_sha)),
      ("options", @json.to_json(options)),
    ]),
  ).stringify()
  let binding = @disk.sha256(binding_data)
  if !recover {
    @disk.create_workspace(directory)
  }
  let lock = @disk.lock_workspace(directory)
  defer lock.close()
  let state : State = if recover {
    read_state(directory, binding)
  } else {
    @disk.write_atomic(directory + "/job.json", binding_data, directory)
    {
      binding,
      phase: 0,
      ingest_runs: 0,
      input_offset: 0L,
      input_line: 0,
      parsed_calls: 0,
      generation: 0,
      runs: 0,
      next_group: 0,
      identity_generation: 0,
      order_generation: 0,
    }
  }
  if state.input_offset > source_size || state.parsed_calls > state.input_line {
    raise EngineError("invalid source position in checkpoint")
  }
  let control : Control = { directory, remaining: pause_after, }
  // The initial checkpoint is committed before any run file can be created.
  if !recover {
    control.save(state) catch {
      Pause =>
        return Json::object(
          Map([
            ("status", Json::string("paused")),
            ("phase", @json.to_json(state.phase)),
          ]),
        )
      error => raise error
    }
  }
  let result = execute(
    source, source_sha, source_size, manifest_sha, manifest, state, control, options,
  ) catch {
    Pause =>
      return Json::object(
        Map([
          ("status", Json::string("paused")),
          ("phase", @json.to_json(state.phase)),
        ]),
      )
    error => raise error
  }
  result
}

///|
fn execute(
  source : String,
  source_sha : String,
  source_size : Int64,
  manifest_sha : String,
  manifest : @ledger.Manifest?,
  state : State,
  control : Control,
  options : Options,
) -> Json raise {
  if state.phase == 0 {
    ingest(source, source_sha, state, control, options)
  }
  if state.phase == 1 {
    merge_all(state, control, options, "identity", false)
  }
  if state.phase == 2 {
    reconcile_sorted(state, control, options)
  }
  if state.phase == 3 {
    merge_all(state, control, options, "order", true)
  }
  if state.phase == 4 {
    let result = audit_sorted(
      state, control, options, manifest, source_sha, source_size, manifest_sha,
    )
    if @disk.file_sha256(source) != source_sha {
      raise EngineError("source changed before report commit")
    }
    let output = control.directory + "/report.json"
    @disk.write_atomic(output + ".tmp", result.stringify(), control.directory)
    seal(output, control.directory)
    state.phase = 5
    control.save(state)
    return result
  }
  if state.phase != 5 {
    raise EngineError("unsupported checkpoint phase")
  }
  verify(control.directory + "/report.json")
  verify(control.directory + "/findings.jsonl")
  verify(run_path(control.directory, "order", state.order_generation, 0))
  @json.parse(
    read_small(control.directory + "/report.json", 4L * 1024L * 1024L),
    reject_duplicate_keys=true,
  )
}
