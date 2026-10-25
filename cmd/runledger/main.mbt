///|
fn usage() -> Unit {
  println("RunLedger: offline agent log integrity and token accounting")
  println("Usage: runledger audit FILE.jsonl [MANIFEST.json]")
  println("       runledger audit-ollama ENVELOPES.jsonl [MANIFEST.json]")
  println("       runledger normalize-ollama ENVELOPES.jsonl")
  println("Exit: 0 clean, 1 findings, 2 invalid command or I/O failure")
}

///|
fn execute(args : Array[String]) -> Int32 raise {
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    usage()
    return 0
  }
  if args.length() < 3 || args.length() > 4 {
    usage()
    return 2
  }
  let command = args[1]
  if command != "audit" &&
    command != "audit-ollama" &&
    command != "normalize-ollama" {
    usage()
    return 2
  }
  if command == "normalize-ollama" && args.length() != 3 {
    usage()
    return 2
  }
  let text = @fs.read_file_to_string(args[2])
  if command == "normalize-ollama" {
    let parsed = @audit.import_ollama(text)
    if !parsed.findings.is_empty() || parsed.records.is_empty() {
      println(@json.to_json(@audit.account(parsed)).stringify())
      return 1
    }
    for record in parsed.records {
      println(@audit.encode_call(record.call).stringify())
    }
    return 0
  }
  let manifest = if args.length() == 4 {
    Some(@fs.read_file_to_string(args[3]))
  } else {
    None
  }
  let parsed = if command == "audit" {
    @audit.parse_jsonl(text)
  } else {
    @audit.import_ollama(text)
  }
  let report = @audit.audit_records(parsed, manifest)
  println(@json.to_json(report).stringify())
  if report.ok {
    0
  } else {
    1
  }
}

///|
fn main {
  let code = execute(@env.args()) catch {
    _ => {
      println(
        "{\"error\":\"cannot_read_input\",\"message\":\"check input and manifest file paths and UTF-8 encoding\"}",
      )
      2
    }
  }
  @sys.exit(code)
}
