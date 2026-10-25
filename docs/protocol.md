# 输入输出协议 v0.1

## 规范化调用 JSONL

每个非空物理行是一条请求尝试。字段：

| 字段 | 类型 | 约束 |
|---|---|---|
| run_id | string | 非空；一次完整运行的标识 |
| task_id | string | 非空；任务 ID，不要求为数字 |
| stage | string | 非空；例如 answer/review |
| call_id | string | 非空；每次请求尝试唯一，重试必须换 ID |
| model | string | 非空；模型名称，应由收集器如实记录 |
| status | string | 仅 ok/error；表示请求结果 |
| input_tokens / output_tokens | number/null/缺省 | 缺省或 null 表示未知；已知值必须是非负十进制整数字面量，最大 9007199254740991 |

不接受数字字符串、小数或指数计数，防止浮点转换掩盖误差。重复 JSON 对象键报错；空白行忽略，CRLF 可用。未知附加字段被忽略；JSON 嵌套深度采用标准库默认限制。

```json
{"run_id":"r1","task_id":"q1","stage":"answer","call_id":"req1","model":"m","status":"ok","input_tokens":100,"output_tokens":20}
```

## 预期清单

```json
{"run_id":"r1","model":"m","task_ids":["q1"],"required_stages":["answer","review"]}
```

两个数组都必须非空、元素非空且不重复。只有符合该运行、模型、任务与阶段的成功请求才能满足覆盖。失败后重试成功可满足覆盖；失败尝试的已知 Token 仍计入账目。完全重复记录保留第一条并报错，冲突的调用副本全部排除。此清单不会验证阶段的执行时间先后。

## Ollama 封装

```json
{"run_id":"r1","task_id":"q1","stage":"answer","call_id":"req1","model":"m","response":{"model":"m","done":true,"prompt_eval_count":100,"eval_count":20}}
```

`response` 是 `/api/chat` 或 `/api/generate` 的最终响应；归一化映射 `prompt_eval_count→input_tokens`、`eval_count→output_tokens`。成功响应的 model 必须与封装 model 相同。明确错误响应可写为 `"response":{"error":"request failed"}`，未报告的用量保留未知。上游失败且没有响应时，收集器可直接写规范化 error 记录。

参考 [Ollama chat 文档](https://docs.ollama.com/api/chat) 和 [generate 文档](https://docs.ollama.com/api/generate)。样例按这些公开字段构造，未声称已对真实服务完成端到端验证。

## 报告

```json
{"ok":true,"usage_complete":true,"totals":{"calls":4,"input_tokens":"406","output_tokens":"86","unknown_usage_calls":0,"failed_calls":0},"findings":[]}
```

`totals` 是规范化且去重后的已知观察值；若报告失败，它不是完整账单。冲突调用和超过累计范围的行不计用量，未知计数仅累计已知一侧。`usage_complete=false` 时不可据总量声明节约百分比。

诊断包含 `line/code/message`。line 是原文件一基物理行号，`0` 表示清单或全局问题。重复调用给出首次出现行号。主要诊断码：invalid_json、invalid_record、invalid_provider_record、duplicate_call、conflicting_call、empty_log、missing_usage、aggregate_overflow、invalid_manifest、unexpected_run/model/task/stage、missing_stage。

低层 API `decode_call`、`decode_manifest` 负责校验；如手工构建公开结构体后调用 `account` 或 `check_coverage`，调用方需保证结构满足上述字段约束。推荐直接使用高层 audit 接口。
