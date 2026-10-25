///|
/// Invalid schema values are separate from malformed JSON syntax.
pub(all) suberror DecodeError {
  DecodeError(String)
}

///|
fn required_string(
  obj : Map[String, Json],
  key : String,
) -> String raise DecodeError {
  match obj.get(key) {
    Some(String(value)) if value.trim().length() > 0 => value
    _ => raise DecodeError("expected nonempty string: " + key)
  }
}

///|
/// Restrict counters to JSON's interoperable exact integer range.
fn optional_tokens(
  obj : Map[String, Json],
  key : String,
) -> Int64? raise DecodeError {
  match obj.get(key) {
    None | Some(Null) => None
    Some(Number(_, repr=Some(raw))) => {
      for char in raw {
        if char < '0' || char > '9' {
          raise DecodeError("expected unsigned decimal integer: " + key)
        }
      }
      let integer = @string.parse_int64(raw) catch {
        _ => raise DecodeError("token count out of range: " + key)
      }
      if integer > 9007199254740991L {
        raise DecodeError("token count out of range: " + key)
      }
      Some(integer)
    }
    Some(Number(value, repr=None)) if value >= 0.0 &&
      value <= 9007199254740991.0 => {
      let integer = value.to_int64()
      if integer.to_double() != value {
        raise DecodeError("expected integer token count: " + key)
      }
      Some(integer)
    }
    _ => raise DecodeError("token count out of range or wrong type: " + key)
  }
}

///|
/// Decode one normalized request attempt; unknown extra fields are ignored.
pub fn decode_call(value : Json) -> Call raise DecodeError {
  guard value is Object(obj) else { raise DecodeError("expected object") }
  let status = required_string(obj, "status")
  if status != "ok" && status != "error" {
    raise DecodeError("status must be ok or error")
  }
  {
    run_id: required_string(obj, "run_id"),
    task_id: required_string(obj, "task_id"),
    stage: required_string(obj, "stage"),
    call_id: required_string(obj, "call_id"),
    model: required_string(obj, "model"),
    status,
    input_tokens: optional_tokens(obj, "input_tokens"),
    output_tokens: optional_tokens(obj, "output_tokens"),
  }
}

///|
/// Inspect all nonblank lines, retaining physical line numbers for diagnostics.
pub fn parse_jsonl(text : String) -> Parsed {
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
          message: "malformed JSON or duplicate object keys",
        })
        continue
      }
    }
    let call = decode_call(value) catch {
      DecodeError(message) => {
        findings.push({ line: index + 1, code: "invalid_record", message, })
        continue
      }
    }
    records.push({ line: index + 1, call, })
  }
  { records, findings, }
}
