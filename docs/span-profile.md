# SDK span JSONL 导入配置 v1

这是有明确边界的平面SDK导出配置，不是通用OTLP、protobuf、Phoenix API、Langfuse API或所有OTel后端的兼容层。

## 接受的数据

每行一个已结束的模型调用span，形状对应OpenTelemetry Python SDK `ReadableSpan.to_json(indent=None)`。`ConsoleSpanExporter`需要配置单行formatter；默认美化输出不是JSONL。

```json
{"context":{"trace_id":"0xabcdef1234567890abcdef1234567890","span_id":"0x1234567890abcdef"},"end_time":"2026-10-26T00:00:00Z","status":{"status_code":"OK"},"attributes":{"gen_ai.operation.name":"chat","gen_ai.response.model":"demo-model","runledger.run_id":"demo-001","runledger.task_id":"q1","runledger.stage":"answer","gen_ai.usage.input_tokens":100,"gen_ai.usage.output_tokens":20}}
```

| 来源 | 映射与约束 |
|---|---|
| context.trace_id、context.span_id | 非零32/16位十六进制，可有0x前缀；统一小写、去前缀后组合为call_id，防止合并多个trace时发生span ID碰撞 |
| attributes.runledger.run_id | 实验/批次标识，必须由采集端显式提供 |
| attributes.runledger.task_id、runledger.stage | 必须显式提供；不从span名称猜测 |
| end_time | 必须为非空字符串；本配置不验证时间戳语法、时间先后或时长 |
| status.status_code | 仅接受OK或ERROR。UNSET是未知，不能据此满足成功阶段覆盖 |
| gen_ai.operation.name | 仅chat、text_completion、generate_content；或使用openinference.span.kind=LLM |
| gen_ai.response.model | 优先采用；缺省则gen_ai.request.model，再缺省则llm.model_name |
| gen_ai.usage.input_tokens/output_tokens | 或OpenInference的llm.token_count.prompt/completion |

如果两套模型属性同时提供且互相矛盾，或两套Token总量同时提供且不同，会报告invalid_span。缺失用量保留未知。每个数值仍遵循规范化协议的整数和范围约束。

父级Agent/Chain、工具、未标明模型调用类型的span不被默认为LLM调用；混入此配置会明确报错，不会静默忽略以制造干净报告。应在采集端为需要审计的模型调用提供相应导出流。

GenAI总输入计数应包含缓存输入，推理输出明细属于总输出的一部分。导入器只取总量，不把cache/reasoning明细再次相加。不能把Langfuse的互斥usage bucket未经转换就当成这个配置的inclusive总量。

## 使用

```sh
moon run cmd/runledger -- audit-spans examples/sdk-spans.jsonl examples/manifest.json
moon run cmd/runledger -- normalize-spans examples/sdk-spans.jsonl
moon run cmd/runledger -- audit-detail examples/clean.jsonl examples/manifest.json
```

规范化不会保留原span的input/output正文；原始输入文件本身不会被修改，标识和元数据仍需在分享前核对是否包含个人信息。

## 独立SDK验证

```sh
python3 -m venv /tmp/runledger-otel
/tmp/runledger-otel/bin/python -m pip install -r requirements-interop.txt
/tmp/runledger-otel/bin/python scripts/interop_otel.py
```

该脚本实际执行OpenTelemetry SDK导出、MoonBit导入、归一化和详细账目检查。测试SDK固定为1.41.1，选择该版本以支持本地Python3.9环境；不声称它是最新SDK。SDK导出span真实存在，模型用量是脚本设置的合成值，没有模型调用、供应商API验证或费用。

参考：[SDK导出API](https://opentelemetry-python.readthedocs.io/en/latest/sdk/trace.export.html)、[GenAI属性](https://opentelemetry.io/docs/specs/semconv/registry/attributes/gen-ai/)、[OpenInference/Phoenix span形状](https://arize.com/docs/phoenix/learn/tracing)。语义约定持续演进；本配置只覆盖上表，不声明全版本兼容。
