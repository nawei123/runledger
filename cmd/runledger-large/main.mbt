///|
fn usage() -> Unit {
  println("RunLedger external audit (native POSIX)")
  println(
    "Usage: runledger-large INPUT.jsonl NEW_WORKSPACE [--manifest FILE] [--format normalized|ollama|sdk]",
  )
  println(
    "  --resume                resume a locked, content-bound workspace; repeat original resource flags",
  )
  println(
    "  --batch-bytes N         serialized batch target (default 4194304), not a hard RSS limit",
  )
  println(
    "  --batch-rows N          maximum records/physical lines per input batch (default 10000)",
  )
  println("  --fan-in N              merge file fan-in, 2..32 (default 16)")
  println(
    "  --max-line-bytes N      reject and drain longer physical lines (default 1048576)",
  )
  println(
    "  --sample-limit N        diagnostic sample count, additionally capped at 64 KiB (default 100)",
  )
  println("Exit: 0 clean, 1 findings, 2 invalid job/I/O, 75 checkpointed pause")
}

///|
fn execute(args : Array[String]) -> Int32 raise {
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    usage()
    return 0
  }
  if args.length() < 3 {
    usage()
    return 2
  }
  let defaults = @engine.Options::defaults()
  let mut batch_bytes = defaults.batch_bytes
  let mut batch_rows = defaults.batch_rows
  let mut fan_in = defaults.fan_in
  let mut max_line_bytes = defaults.max_line_bytes
  let mut sample_limit = defaults.sample_limit
  let mut format = defaults.format
  let mut manifest : String? = None
  let mut recover = false
  let mut pause_after = 0
  let mut i = 3
  while i < args.length() {
    if args[i] == "--resume" {
      recover = true
      i += 1
      continue
    }
    if i + 1 >= args.length() {
      usage()
      return 2
    }
    let value = args[i + 1]
    match args[i] {
      "--manifest" => manifest = Some(value)
      "--format" => format = value
      "--batch-bytes" => batch_bytes = @string.parse_int(value)
      "--batch-rows" => batch_rows = @string.parse_int(value)
      "--fan-in" => fan_in = @string.parse_int(value)
      "--max-line-bytes" => max_line_bytes = @string.parse_int(value)
      "--sample-limit" => sample_limit = @string.parse_int(value)
      // Fault-injection / reproducibility control, not part of the job binding.
      "--pause-after-checkpoints" => pause_after = @string.parse_int(value)
      _ => {
        usage()
        return 2
      }
    }
    i += 2
  }
  let result = @engine.run(
    args[1],
    args[2],
    manifest,
    { batch_bytes, batch_rows, fan_in, max_line_bytes, sample_limit, format, },
    recover~,
    pause_after~,
  )
  println(result.stringify())
  guard result is Object(obj) else { return 2 }
  if obj.get("status") == Some(Json::string("paused")) {
    return 75
  }
  if obj.get("report") is Some(Object(report)) &&
    report.get("ok") == Some(Json::boolean(true)) {
    0
  } else {
    1
  }
}

///|
fn fail_job(message : String) -> Int32 {
  println(
    Json::object(
      Map([
        ("error", Json::string("job_failed")),
        ("message", Json::string(message)),
      ]),
    ).stringify(),
  )
  2
}

///|
fn main {
  let result = execute(@env.args()) catch {
    @engine.EngineError(message) => fail_job(message)
    @disk.IOError(message) => fail_job(message)
    error => fail_job(error.to_string())
  }
  @sys.exit(result)
}
