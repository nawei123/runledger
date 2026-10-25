///|
/// Envelope fields supply the run/task identity missing from provider responses.
/// Each line must contain one final response or one error, never a stream chunk.
pub fn decode_ollama(value : Json) -> Call raise DecodeError {
  guard value is Object(obj) else {
    raise DecodeError("expected provider envelope")
  }
  guard obj.get("response") is Some(Object(response)) else {
    raise DecodeError("expected response object")
  }
  let model = required_string(obj, "model")
  let status = match response.get("error") {
    Some(String(_)) => "error"
    None => {
      if !(response.get("done") is Some(True)) {
        raise DecodeError("expected final done=true response")
      }
      if required_string(response, "model") != model {
        raise DecodeError("response model differs from envelope")
      }
      "ok"
    }
    _ => raise DecodeError("invalid provider error value")
  }
  {
    run_id: required_string(obj, "run_id"),
    task_id: required_string(obj, "task_id"),
    stage: required_string(obj, "stage"),
    call_id: required_string(obj, "call_id"),
    model,
    status,
    input_tokens: optional_tokens(response, "prompt_eval_count"),
    output_tokens: optional_tokens(response, "eval_count"),
  }
}

///|
/// Never includes response text in normalized records or diagnostic messages.
pub fn import_ollama(text : String) -> Parsed {
  let records : Array[Record] = []
  let findings : Array[Finding] = []
  for index, line in text.split("\n").to_array() {
    if line.trim().is_empty() {
      continue
    }
    let value = @json.parse(
      line,
      reject_duplicate_keys=true,
      preserve_number_repr=true,
    ) catch {
      _ => {
        findings.push({
          line: index + 1,
          code: "invalid_json",
          message: "malformed provider JSON or duplicate keys",
        })
        continue
      }
    }
    let call = decode_ollama(value) catch {
      DecodeError(message) => {
        findings.push({
          line: index + 1,
          code: "invalid_provider_record",
          message,
        })
        continue
      }
    }
    records.push({ line: index + 1, call, })
  }
  { records, findings, }
}

///|
/// Encode interoperable integer counters as JSON numbers, not Int64 strings.
/// Use this encoder for normalized interchange, rather than derived ToJson.
pub fn encode_call(call : Call) -> Json {
  let obj : Map[String, Json] = Map([
    ("run_id", Json::string(call.run_id)),
    ("task_id", Json::string(call.task_id)),
    ("stage", Json::string(call.stage)),
    ("call_id", Json::string(call.call_id)),
    ("model", Json::string(call.model)),
    ("status", Json::string(call.status)),
  ])
  match call.input_tokens {
    Some(n) => obj.set("input_tokens", Json::number(n.to_double()))
    None => obj.set("input_tokens", Json::null())
  }
  match call.output_tokens {
    Some(n) => obj.set("output_tokens", Json::number(n.to_double()))
    None => obj.set("output_tokens", Json::null())
  }
  Json::object(obj)
}
