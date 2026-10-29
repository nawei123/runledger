///|
pub(all) suberror EngineError {
  EngineError(String)
}

///|
priv suberror Pause {
  Pause
}

///|
pub(all) struct Options {
  batch_bytes : Int32
  batch_rows : Int32
  fan_in : Int32
  max_line_bytes : Int32
  sample_limit : Int32
  format : String
} derive(ToJson)

///|
pub extend Options with ToJson::{to_json}

///|
pub fn Options::defaults() -> Options {
  {
    batch_bytes: 4 * 1024 * 1024,
    batch_rows: 10000,
    fan_in: 16,
    max_line_bytes: 1024 * 1024,
    sample_limit: 100,
    format: "normalized",
  }
}

///|
fn Options::validate(self : Options) -> Unit raise EngineError {
  if self.batch_bytes < 256 ||
    self.batch_bytes > 64 * 1024 * 1024 ||
    self.batch_rows < 1 ||
    self.batch_rows > 100000 ||
    self.fan_in < 2 ||
    self.fan_in > 32 ||
    self.max_line_bytes < 128 ||
    self.max_line_bytes > 8 * 1024 * 1024 ||
    self.sample_limit < 0 ||
    self.sample_limit > 1000 ||
    !(self.format == "normalized" ||
    self.format == "ollama" ||
    self.format == "sdk") {
    raise EngineError("invalid resource bounds or input format")
  }
}

///|
priv struct State {
  binding : String
  mut phase : Int32
  mut ingest_runs : Int32
  mut input_offset : Int64
  mut input_line : Int32
  mut parsed_calls : Int32
  mut generation : Int32
  mut runs : Int32
  mut next_group : Int32
  mut identity_generation : Int32
  mut order_generation : Int32
} derive(ToJson)

///|
fn field(obj : Map[String, Json], key : String) -> Json raise EngineError {
  obj
  .get(key)
  .unwrap_or_else(() => raise EngineError("checkpoint field missing: " + key))
}

///|
fn text_field(
  obj : Map[String, Json],
  key : String,
) -> String raise EngineError {
  guard field(obj, key) is String(value) else {
    raise EngineError("invalid checkpoint string: " + key)
  }
  value
}

///|
fn int_field(obj : Map[String, Json], key : String) -> Int32 raise EngineError {
  guard field(obj, key) is Number(n, ..) &&
    n >= 0.0 &&
    n <= 2147483647.0 &&
    n.to_int().to_double() == n else {
    raise EngineError("invalid checkpoint integer: " + key)
  }
  n.to_int()
}

///|
fn read_small(path : String, limit : Int64) -> String raise {
  if @disk.file_size(path) > limit {
    raise EngineError("metadata exceeds size limit")
  }
  let reader = @disk.open(path)
  defer reader.close()
  let result = StringBuilder()
  while true {
    let before = reader.position()
    match reader.read_line(limit.to_int()) {
      End => break
      Text(text) => {
        let after = reader.position()
        if after > limit {
          raise EngineError("metadata grew beyond size limit")
        }
        result.write_string(text)
        if after - before > @utf8.encode(text).length().to_int64() {
          result.write_char('\n')
        }
      }
      _ => raise EngineError("invalid or oversized UTF-8 metadata")
    }
  }
  result.to_string()
}

///|
fn read_state(directory : String, binding : String) -> State raise {
  let envelope = @json.parse(
    read_small(directory + "/checkpoint.json", 65536L),
    reject_duplicate_keys=true,
  )
  guard envelope is Object(env) else {
    raise EngineError("invalid checkpoint envelope")
  }
  let payload = text_field(env, "payload")
  if text_field(env, "sha256") != @disk.sha256(payload) {
    raise EngineError("checkpoint checksum mismatch")
  }
  guard @json.parse(payload, reject_duplicate_keys=true) is Object(obj) else {
    raise EngineError("invalid checkpoint payload")
  }
  let actual_binding = text_field(obj, "binding")
  if actual_binding != binding {
    raise EngineError(
      "source, manifest, engine version, or options changed; use a new workspace",
    )
  }
  let offset = @string.parse_int64(text_field(obj, "input_offset"))
  let phase = int_field(obj, "phase")
  let generation = int_field(obj, "generation")
  if phase > 5 || generation > 64 || offset < 0L {
    raise EngineError("checkpoint state out of range")
  }
  {
    binding,
    phase,
    generation,
    ingest_runs: int_field(obj, "ingest_runs"),
    input_offset: offset,
    input_line: int_field(obj, "input_line"),
    parsed_calls: int_field(obj, "parsed_calls"),
    runs: int_field(obj, "runs"),
    next_group: int_field(obj, "next_group"),
    identity_generation: int_field(obj, "identity_generation"),
    order_generation: int_field(obj, "order_generation"),
  }
}

///|
priv struct Control {
  directory : String
  mut remaining : Int32
}

///|
fn Control::save(self : Control, state : State) -> Unit raise {
  let payload = @json.to_json(state).stringify()
  let env = Json::object(
    Map([
      ("payload", Json::string(payload)),
      ("sha256", Json::string(@disk.sha256(payload))),
    ]),
  )
  @disk.write_atomic(
    self.directory + "/checkpoint.json",
    env.stringify(),
    self.directory,
  )
  if self.remaining > 0 {
    self.remaining -= 1
    if self.remaining == 0 {
      raise Pause
    }
  }
}

///|
fn run_path(
  directory : String,
  prefix : String,
  generation : Int32,
  index : Int32,
) -> String {
  directory +
  "/" +
  prefix +
  "-g" +
  generation.to_string() +
  "-r" +
  index.to_string() +
  ".jsonl"
}

///|
fn seal(path : String, directory : String) -> Unit raise {
  @disk.atomic_rename(path + ".tmp", path, directory)
  let digest = @disk.file_sha256(path)
  @disk.write_atomic(path + ".sha256", digest, directory)
}

///|
fn verify(path : String) -> Unit raise {
  if read_small(path + ".sha256", 64L) != @disk.file_sha256(path) {
    raise EngineError("intermediate file checksum mismatch")
  }
}

///|
fn remove_run(path : String) -> Unit raise {
  if @fs.path_exists(path) {
    @fs.remove_file(path)
  }
  if @fs.path_exists(path + ".sha256") {
    @fs.remove_file(path + ".sha256")
  }
}

///|
fn record_text(record : @ledger.Record) -> String {
  @json.to_json(record).stringify()
}

///|
fn decode_record(text : String) -> @ledger.Record raise {
  guard @json.parse(text, reject_duplicate_keys=true, preserve_number_repr=true)
    is Object(obj) else {
    raise EngineError("invalid intermediate record")
  }
  {
    line: int_field(obj, "line"),
    call: @ledger.decode_call(field(obj, "call")),
  }
}

///|
fn next_record(reader : @disk.File, limit : Int32) -> @ledger.Record? raise {
  match reader.read_line(limit) {
    End => None
    Text(text) => Some(decode_record(text))
    _ => raise EngineError("corrupted or oversized intermediate record")
  }
}

///|
fn compare_record(
  a : @ledger.Record,
  b : @ledger.Record,
  by_line : Bool,
) -> Int32 {
  if !by_line {
    let run = a.call.run_id.compare(b.call.run_id)
    if run != 0 {
      return run
    }
    let call = a.call.call_id.compare(b.call.call_id)
    if call != 0 {
      return call
    }
  }
  a.line.compare(b.line)
}

///|
fn emit(writer : @disk.File, finding : @ledger.Finding) -> Unit raise {
  writer.write_line(@json.to_json(finding).stringify())
}
