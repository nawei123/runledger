# 同类方案研究与改进依据

核查日期：2026-10-26。范围为官方文档、官方仓库README、相关标准及Mooncakes包说明；是文档级比较，不是对所有产品完整功能、最新版本或性能的全面测试。未在其他商业平台建立账户或导入用户数据。

## 已有能力：不作为本项目首创

| 方案与官方来源 | 文档明确展示的能力 | 对本项目的启示 |
|---|---|---|
| [Langfuse](https://langfuse.com/docs/observability/features/token-and-cost-tracking) | 用量/成本跟踪、提供者用量优先、模型价格及细分usage bucket | 不能以“能统计Token”作为创新；其互斥bucket与OTel总量的口径不同，转换不能随意相加 |
| [LangSmith](https://docs.langchain.com/langsmith/log-llm-trace) | LLM trace、usage_metadata与成本信息 | 调用级元数据已经成熟；本项目需明确自身是可离线复现的检查器 |
| [LiteLLM](https://docs.litellm.ai/docs/proxy/cost_tracking) | 请求级支出日志、request_id查询和成本跟踪 | 网关式采集与成本管理已有成熟实现；本项目不另做网关、价格表或账单系统 |
| [Phoenix](https://arize.com/docs/phoenix/tracing/how-to-tracing/save-and-load-traces) | 导入、导出和查询trace，OpenInference span表示 | 应接入有明确定义的导出形状，不声称另创通用追踪格式 |
| [MLflow](https://mlflow.org/docs/latest/genai/tracing/token-usage-cost/) | 调用/trace级Token及成本聚合，未报告用量可为空 | 未知值不应成为“0消耗”的确定证据；未知处理本身也不是独有思想 |
| [Helicone](https://github.com/Helicone/helicone) | 可观测、Agent tracing、成本/延迟、路由与fallback | 无需复制在线监控控制台；关注已导出批次的账目检查 |
| [Weights & Biases Weave](https://github.com/wandb/weave) | Agent/函数追踪与评估 | tracing和evaluations已经普及，不能仅凭CLI或统计页面主张新颖性 |
| [Pydantic AI/Evals](https://github.com/pydantic/pydantic-ai) | Agent开发、输出及工具轨迹评估、Logfire生态 | 执行过程评估并非空白；应限定到批次对账与覆盖合同 |
| [Promptfoo](https://github.com/promptfoo/promptfoo) | CLI化自动评测与红队测试 | “可在CI运行”是工程要求，不是独有创新 |
| [OpenLLMetry](https://github.com/traceloop/openllmetry) | 基于OpenTelemetry的LLM可观测与自动埋点 | 避免自建无必要的在线采集SDK；本项目只接受明确配置的导出数据 |
| [OpenLIT](https://github.com/openlit/openlit) | OTel原生追踪、评估、成本和Agent相关监控 | 不能宣称现有平台不支持Agent或只看最终回答 |
| [agent-eval trace contracts](https://github.com/tangle-network/agent-eval/blob/main/docs/trace-contracts.md) | 无模型的确定性trace合同：工具、顺序、模型、用量预算、未知状态失败等 | 这是最接近的既有思路之一；“合同式检查执行路径”不能称全球首创。其范围比本项目更广 |

没有在产品介绍中看到某项规则，不等于该产品不支持；本表不提供未经验证的“竞品不支持”结论。

## MoonBit生态定位

已核对的相关包包括moonjson、moontrace、agent-telemetry、weopqrst/agent、mooncontext、tally和mooncassette-llm，具体链接及边界见[生态查重](ecosystem.md)。新增核对AgentCanary、LedgerWeave、MoonFlowGraph和MoonEvidence的官方README，分别覆盖工具策略回放、业务流水对账、工作流生命周期审计和文件证据完整性。AgentCanary及MoonFlowGraph在离线规则/执行完整性方向有明显交集，因此不能主张MoonBit生态此前没有相关检查器。另对ledger、token usage和trace audit进行Mooncakes检索；关键词排名及摘要不能证明穷尽整个注册表。

本项目的合理定位是：MoonBit生态内可嵌入的离线批次调用账目与任务阶段覆盖检查库，与采集器和回放工具互补。它不是更完整的Langfuse、Phoenix或agent-eval替代品。该生态价值仍需真实用户和维护反馈证明。

## 本轮已实现的改进

### 1. 有边界的标准数据接入与语义冲突检查

新增SDK span JSONL配置，支持所列GenAI和OpenInference属性。显式要求模型调用类型、结束记录、OK/ERROR状态和任务元数据；UNSET、父级Agent span、互相矛盾的计数或模型属性都会失败。将trace/span组合成调用身份，统一十六进制表示，防止合并trace时错误去重。

这是接入和正确性改进，不是发明新标准；不支持原始OTLP容器或任意后端导出。真实SDK互操作已经测试，提供者用量仍为合成。见[配置与边界](span-profile.md)。

### 2. 可解释的账目拆分和未知量归因

新增版本化详细报告，区分解码成功行、去重后接受调用、重复行和冲突行；按运行/阶段/模型拆分账目，并分别报告缺少输入、缺少输出用量的调用数。排除冲突身份后再统计，避免不同报表各自计数导致账目不一致。

全局安全整数累计溢出时，详细报告显式将group_totals_available设为false并清空分组，避免分组结果与被排除溢出行的总量形成误导性对照。

原有audit JSON保持不变，详细报告通过新接口和命令提供。这是兼容性与可解释性设计，不把同类平台已有的聚合统计作为原创。

### 3. 批次覆盖检查的复杂度优化

旧版对每次调用线性搜索任务与阶段数组，成员检查成本随任务数增长。本轮预先建立哈希索引，使成员检查平均成本降为常数；完整流程仍需读取调用及枚举预期任务×阶段，内存仍为整文件级别。

同一编译器、macOS arm64原生debug配置下，对比已保留的0.1.1二进制：预热后各5次、交替运行顺序、比较端到端CLI中位时间，并逐次核对完整基础报告相同。

| 合成任务数 | 调用数 | 0.1.1中位时间 | 本轮中位时间 | 比率 |
|---|---|---|---|---|
| 1,000 | 2,000 | 0.01284s | 0.01062s | 约1.21倍 |
| 10,000 | 20,000 | 0.27378s | 0.09047s | 约3.03倍 |
| 50,000 | 100,000 | 4.66468s | 0.45346s | 约10.29倍 |

这是本机合成批次的观察值，不是跨硬件保证，也不代表模型推理速度或准确率提高。微小样本易受启动噪声影响；没有测内存峰值、持续吞吐、流式处理或竞品性能。基线提交765dd81、被测候选提交5378ae2，报告保存二进制SHA256、全部样本和工作区状态。基准脚本为scripts/benchmark_compare.py。

## 验证方法

- 35项MoonBit单元测试，原生和wasm-gc执行同一套用例。
- 9项CLI集成测试，包括详细报告一致性、SDK导出样本及UNSET状态拒绝。
- 独立Python参考实现对100个固定种子的故障组合进行对账，每个组合再打乱输入顺序，检查基础账目、诊断计数及分组和总量一致性。覆盖有限合成域，不是形式化证明。
- 实际执行OpenTelemetry SDK导出4个span，经过MoonBit导入、规范化、详细报告再核对用量。模型计数由测试设置，没有实际模型请求。

## 还需要做什么

真实脱敏提供者日志、真实使用者反馈、流式大文件处理、更多格式和精细费用策略仍未完成。应先证实现有闭环有实际用户，再决定是否扩展，不能把这些规划写成现成功能。赛事的立项与最终验收仍由主办方判断。
