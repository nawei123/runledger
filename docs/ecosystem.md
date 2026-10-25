# 查重与项目边界

核查日期：2026-10-25。通过 mooncakes.io 包文档、项目 README 和 `moon search --json` 检索 audit、token、moontrace、runledger。搜索不能证明所有已有项目都已覆盖，申报仍需由赛事组审核。

| 相关项目 | 已有能力 | 本项目具体边界 |
|---|---|---|
| [moonbitstack/moonjson](https://mooncakes.io/docs/moonbitstack/moonjson) | JSON、JSONL、JSON Pointer 等解析 | 直接使用 MoonBit 标准 JSON 解析，不重新实现解析器 |
| [brickfrog/moontrace](https://mooncakes.io/docs/brickfrog/moontrace) | 结构化 tracing、span、订阅器与导出 | 本项目不记录或导出 span；初始名 MoonTrace 因重名改为 RunLedger |
| [cybershang/agent-telemetry](https://mooncakes.io/docs/cybershang/agent-telemetry) | Agent/LLM/工具的 OpenTelemetry 埋点与 usage 记录 | 对已收集的请求记录离线去重、排除冲突并对照任务清单 |
| [weopqrst/agent](https://mooncakes.io/docs/weopqrst/agent) | Agent 编排、UsageTracker、调用跟踪 | 不实现 Agent、在线调用或新的计费监控平台 |
| [lllg123/mooncontext](https://mooncakes.io/docs/lllg123/mooncontext) | 已装配上下文的字符预算、标记、占位符检查 | 输入是执行请求日志，检查实际报告用量与任务覆盖，不检查上下文内容 |
| [weopqrst/tally](https://mooncakes.io/docs/weopqrst/tally) | Token 预算、上下文装配、可验证计划 | 不做 BPE 或装配；缺失 provider usage 时明确未知 |
| [weopqrst/mooncassette-llm](https://mooncakes.io/docs/weopqrst/mooncassette-llm) | 离线回放模型记录、provider usage 与估算差异 | 不回放模型；检查整批日志的身份冲突、失败重试与预期任务阶段 |

定位是一个独立的离线检查库，可能与上游采集或回放工具互补。通用 JSONL 检查、计数统计本身并不构成足够的差异；价值需要通过真实日志中可复现的重复计费和覆盖遗漏问题证明。目前样例与回归测试均为合成数据，这项真实集成验证尚未完成。

实现为本期新建，未复制上述项目代码。标准库与 x 库按其 Apache-2.0 许可使用。AI 参与了选型、代码、测试和文档草拟，参赛者需要复核并理解实现。
