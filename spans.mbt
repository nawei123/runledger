///|
/// Canonical SDK identifiers preserve trace identity across merged exports.
fn span_identifier(
  context : Map[String, Json],
  key : String,
  width : Int32,
) -> String raise DecodeError {
  let raw = required_string(context, key).to_lower()
  let value = raw.strip_prefix("0x").unwrap_or(raw.view())
  if value.length() != width {
    raise DecodeError("invalid span identifier: " + key)
  }
  let mut nonzero = false
  for c in value {
    if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
      raise DecodeError("invalid span identifier: " + key)
    }
    if c != '0' {
      nonzero = true
    }
  }
  if !nonzero {
    raise DecodeError("zero span identifier: " + key)
  }
  value.to_owned()
}

///|
/// Both semantic families may coexist, but disagreement is not silently resolved.
fn span_tokens(
  attrs : Map[String, Json],
  genai : String,
  inference : String,
) -> Int64? raise DecodeError {
  let a = optional_tokens(attrs, genai)
  let b = optional_tokens(attrs, inference)
  match (a, b) {
    (Some(x), Some(y)) if x != y =>
      raise DecodeError("conflicting semantic token attributes")
    (Some(x), _) => Some(x)
    (_, value) => value
  }
}

///|
/// Bounded flat SDK-span profile, not raw OTLP/protobuf or a backend API export.
/// Require explicit model-call kind, terminal status and caller-supplied task metadata.
pub fn decode_span(value : Json) -> Call raise DecodeError {
  guard value is Object(obj) else {
    raise DecodeError("expected flat SDK span object")
  }
  guard obj.get("attributes") is Some(Object(attrs)) else {
    raise DecodeError("expected span attributes object")
  }
  guard obj.get("context") is Some(Object(context)) else {
    raise DecodeError("expected span context object")
  }
  let _ = required_string(obj, "end_time")
  let mut model_kind = false
  match attrs.get("openinference.span.kind") {
    Some(String("LLM")) => model_kind = true
    None => ()
    _ => raise DecodeError("only explicit LLM spans are accepted")
  }
  match attrs.get("gen_ai.operation.name") {
    Some(String("chat" | "text_completion" | "generate_content")) =>
      model_kind = true
    None => ()
    _ =>
      raise DecodeError(
        "unsupported GenAI operation; exclude parent and tool spans",
      )
  }
  if !model_kind {
    raise DecodeError("missing explicit model-call span kind")
  }
  guard obj.get("status") is Some(Object(status)) else {
    raise DecodeError("missing explicit span status")
  }
  let state = match status.get("status_code") {
    Some(String("OK")) => "ok"
    Some(String("ERROR")) => "error"
    _ =>
      raise DecodeError(
        "span status must explicitly be OK or ERROR; UNSET is unknown",
      )
  }
  let model = match attrs.get("gen_ai.response.model") {
    Some(String(model)) if !model.trim().is_empty() => model
    None =>
      match attrs.get("gen_ai.request.model") {
        Some(String(model)) if !model.trim().is_empty() => model
        None => required_string(attrs, "llm.model_name")
        _ => raise DecodeError("invalid requested model")
      }
    _ => raise DecodeError("invalid response model")
  }
  match attrs.get("llm.model_name") {
    Some(String(other)) if other != model =>
      raise DecodeError("conflicting semantic model attributes")
    Some(String(_)) | None => ()
    _ => raise DecodeError("invalid OpenInference model")
  }
  {
    run_id: required_string(attrs, "runledger.run_id"),
    task_id: required_string(attrs, "runledger.task_id"),
    stage: required_string(attrs, "runledger.stage"),
    call_id: span_identifier(context, "trace_id", 32) +
    "/" +
    span_identifier(context, "span_id", 16),
    model,
    status: state,
    input_tokens: span_tokens(
      attrs, "gen_ai.usage.input_tokens", "llm.token_count.prompt",
    ),
    output_tokens: span_tokens(
      attrs, "gen_ai.usage.output_tokens", "llm.token_count.completion",
    ),
  }
}

///|
/// Every nonblank input line must be one selected model-call span; no silent filtering.
pub fn import_spans(text : String) -> Parsed {
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
          message: "malformed span JSON or duplicate keys",
        })
        continue
      }
    }
    let call = decode_span(value) catch {
      DecodeError(message) => {
        findings.push({ line: index + 1, code: "invalid_span", message, })
        continue
      }
    }
    records.push({ line: index + 1, call, })
  }
  { records, findings, }
}
