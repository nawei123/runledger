///| One provider request attempt. Retries must use distinct call IDs.
pub(all) struct Call {
  run_id : String
  task_id : String
  stage : String
  call_id : String
  model : String
  status : String
  input_tokens : Int64?
  output_tokens : Int64?
} derive(ToJson)

///| Diagnostics never copy prompts or response text into the report.
pub(all) struct Finding {
  line : Int
  code : String
  message : String
} derive(ToJson)

///| An accepted record and its physical, one-based source line.
pub(all) struct Record {
  line : Int
  call : Call
} derive(ToJson)

///| All malformed lines are retained as diagnostics instead of being skipped.
pub(all) struct Parsed {
  records : Array[Record]
  findings : Array[Finding]
} derive(ToJson)

pub extend Call with ToJson::{to_json}
pub extend Finding with ToJson::{to_json}
pub extend Record with ToJson::{to_json}
pub extend Parsed with ToJson::{to_json}
