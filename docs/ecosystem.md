# 查重与项目边界

核查日期：2026-10-26。通过 mooncakes.io 包文档、项目 README 和 `moon search --json` 检索 audit、token、moontrace、runledger。搜索不能证明所有已有项目都已覆盖，申报仍需由赛事组审核。

| 相关项目 | 已有能力 | 本项目具体边界 |
|---|---|---|
| [moonbitstack/moonjson](https://mooncakes.io/docs/moonbitstack/moonjson) | JSON、JSONL、JSON Pointer 等解析 | 直接使用 MoonBit 标准 JSON 解析，不重新实现解析器 |
| [brickfrog/moontrace](https://mooncakes.io/docs/brickfrog/moontrace) | 结构化 tracing、span、订阅器与导出 | 本项目不埋点；只导入所列SDK形状的选定模型span；初始名 MoonTrace 因重名改为 RunLedger |
| [cybershang/agent-telemetry](https://mooncakes.io/docs/cybershang/agent-telemetry) | Agent/LLM/工具的 OpenTelemetry 埋点与 usage 记录 | 对已收集的请求记录离线去重、排除冲突并对照任务清单 |
| [weopqrst/agent](https://mooncakes.io/docs/weopqrst/agent) | Agent 编排、UsageTracker、调用跟踪 | 不实现 Agent、在线调用或新的计费监控平台 |
| [lllg123/mooncontext](https://mooncakes.io/docs/lllg123/mooncontext) | 已装配上下文的字符预算、标记、占位符检查 | 输入是执行请求日志，检查实际报告用量与任务覆盖，不检查上下文内容 |
| [weopqrst/tally](https://mooncakes.io/docs/weopqrst/tally) | Token 预算、上下文装配、可验证计划 | 不做 BPE 或装配；缺失 provider usage 时明确未知 |
| [weopqrst/mooncassette-llm](https://mooncakes.io/docs/weopqrst/mooncassette-llm) | 离线回放模型记录、provider usage 与估算差异 | 不回放模型；检查整批日志的身份冲突、失败重试与预期任务阶段 |


| [AgentCanary](https://github.com/zhangbowen2006/AgentCanary) | 工具轨迹离线策略回放；敏感标签传播、审批、累计预算、前置步骤及策略回归 | 离线检查与预算规则存在交集；本项目限定到请求身份对账、未知用量及独立任务×阶段清单，不扩展权限策略引擎 |
| [LedgerWeave](https://github.com/sujy123456/project_3) | 订单/支付/退款/调整流水对账、异常归因、整数金额及复核工作流 | 对账思想和确定性诊断相近，业务对象不同；不能称“对账”本身原创 |
| [MoonFlowGraph](https://github.com/AlexenderSokolov/moonflowgraph) | DAG规划、provenance、运行快照导入及生命周期/任务状态审计 | 任务完整性检查有交集；本项目不规划DAG或验证生命周期顺序，只核对显式任务阶段成功调用与用量 |
| [MoonEvidence](https://github.com/wenlittle/MoonEvidence) | 文件证据包、摘要、Merkle与版本链验证 | 可对归档字节做完整性保护；本项目不验证文件来源或防篡改，也不能证明日志真实性 |

以上新增四项由官方README核对，非仅按Mooncakes搜索摘要推断。MoonFlowGraph搜索结果匹配到未公开API的命令包，不代表其核心库没有API；已以仓库README补正。没有对这些项目运行功能或性能比较，也没有复制实现。

定位是一个独立的离线检查库，可能与上游采集或回放工具互补。通用 JSONL 检查、计数统计本身并不构成足够的差异；价值需要通过真实日志中可复现的重复计费和覆盖遗漏问题证明。目前模型用量样例与回归测试仍为合成数据；已实际执行OpenTelemetry SDK导出互操作，但没有真实提供者日志或使用者反馈，这项真实业务集成验证尚未完成。

实现为本期新建，未复制上述项目代码。标准库与 x 库按其 Apache-2.0 许可使用。AI 参与了选型、代码、测试和文档草拟，参赛者需要复核并理解实现。
