# RunLedger 0.2.0 技术补充与可核验证据

历史范围说明：本文保留0.2.0实例；0.3.0的实质新增外部引擎、资源控制及恢复能力见[新架构文档](external-audit.md)。

日期：2026-10-30。本文是AI辅助整理的公开技术文档，不是要求本人手写的参赛申报书。用于说明已实现行为及验证范围，不代表赛事已认可独立项目价值或工程深度。

本轮新增的是可复现实例及证据索引。下述核心功能已存在于0.2.0，不能写成收到审核意见后新增的能力。实现基准提交：[2da6e64](https://github.com/nawei123/runledger/tree/2da6e6404ad835f518412dc4676ed0d9ec28e9eb)。

## 问题边界与预期用途

输入是已经收集的调用记录和独立任务清单，输出是观察账目、诊断和退出码。场景为批次实验用量核对、多阶段评测完整性检查、CI结果入库门禁。三者是预期用途；目前没有真实使用者采纳或真实模型提供者日志证据。

去重、求和、集合差集是基础机制。项目的具体工程选择是如何处理相互冲突的调用身份、失败重试、未知计数、整数边界、外部SDK语义及账目与覆盖之间的不同结论。下面用实际输入输出说明这些选择，不主张基础算法或trace合同首创。

```mermaid
flowchart LR
  A[规范化日志或指定导出配置] --> B[解析与字段校验]
  B --> C[调用身份对账]
  C --> D[已知用量与未知量统计]
  C --> E[独立任务阶段覆盖]
  D --> F[JSON诊断及退出码]
  E --> F
```

## 关键设计与实现位置

| 设计 | 实际行为 | 实现 |
|---|---|---|
| 冲突身份隔离 | 键为运行ID与调用ID。完全重复仅计一次并诊断；同键不同内容的所有副本均排除，不能拿第一条满足覆盖 | [reconcile.mbt](../reconcile.mbt) |
| 失败与未知分离 | 失败尝试已报告的用量仍计入；缺失一侧只累计已知一侧，并标记未知，不能形成完整消耗结论 | [account.mbt](../account.mbt) |
| 独立任务清单 | 只有清单指定的运行、模型、任务、阶段的成功调用可满足覆盖；整题没有出现也能检查。清单不是日志过滤器 | [manifest.mbt](../manifest.mbt) |
| 严格数值边界 | 输入拒绝负数、指数、小数、数字字符串及重复JSON键；计数和累计量限制在安全JSON整数范围 | [parse.mbt](../parse.mbt)、[account.mbt](../account.mbt) |
| 外部语义冲突拒绝 | 所列SDK平面形状要求明确任务标识、模型调用类型及OK/ERROR；UNSET不算成功；两套usage不一致则拒绝 | [spans.mbt](../spans.mbt)、[SDK配置](span-profile.md) |
| 详细账目可用性 | 按运行/阶段/模型归因，报告方向性未知；全局累计溢出时groups清空、group_totals_available=false | [detail.mbt](../detail.mbt) |

identity对账先于总量和覆盖检查，使冲突副本同时失去两种用途。已知失败重试仍参与消耗，但失败本身不满足阶段成功。不存在用一张“成功行表”同时计算两者的捷径。

`report.ok`表示所选检查通过，`usage_complete`描述解析与对账后的观察账目完整性，二者不同。例如整题缺失可使ok=false而usage_complete=true；分组的usage_complete也不等于全局覆盖通过。含溢出的总量只保留被接受的部分观察值，不能当作完整账单或比较节约比例。

AuditStats不是行数互斥分区：parsed_calls是解码成功行数，accepted_calls是排除冲突后唯一身份数，duplicate_rows及conflicting_rows统计新增副本相对首次记录的诊断次数；后两者不等于所有被排除身份的总行数。

## 九个可重放实例

所有数据均为合成。每个目录包含input.jsonl、manifest.json及CLI实际report.json；描述与精确期望由[scripts/review_evidence.py](../scripts/review_evidence.py)核对。

| 实例 | 精确观察结果 | 输入与报告 |
|---|---|---|
| 干净对照 | 2次调用，输入14、输出3，exit 0 | [01](review-evidence/01-clean-control/report.json) |
| 同键不同用量 | 两个answer副本均排除，只剩review输入4、输出1，缺少answer；倒序执行观察总量和诊断码一致 | [02](review-evidence/02-conflicting-identity/report.json) |
| 失败后重试 | 失败尝试100/20，加成功answer 10/2、review 4/1，共输入114、输出23；覆盖通过 | [03](review-evidence/03-failed-attempt-and-retry/report.json) |
| 已覆盖但用量未知 | 输入一侧缺失，保留已知输入4、输出3；unknown_usage_calls=1，exit 1 | [04](review-evidence/04-directional-unknown-usage/report.json) |
| 整题没有日志 | q1完整，但独立清单还有q2，报告q2两个阶段缺失；账目完整不表示覆盖完整 | [05](review-evidence/05-wholly-missing-task/report.json) |
| SDK UNSET | answer不接受为成功证据，诊断invalid_span及missing_stage | [06](review-evidence/06-sdk-unset-status/report.json) |
| 两套usage冲突 | 同条span中GenAI输入100、OpenInference输入60，不选择其一凑数 | [07](review-evidence/07-conflicting-semantic-usage/report.json) |
| inclusive缓存口径 | 总输入100已含缓存40，加review输入4后总量104，不把缓存再加一次 | [08](review-evidence/08-inclusive-cache-usage/report.json) |
| 安全整数累计越界 | 9007199254740991再加1触发aggregate_overflow；详细分组显式不可用 | [09](review-evidence/09-unsafe-aggregate/report.json) |

复现：先构建原生CLI，再运行以下命令。输出默认写入被Git忽略的reports/review-evidence，公开目录是2026-10-30的固定副本。

```sh
moon build --target native --deny-warn
python3 scripts/review_evidence.py --date 2026-10-30
```

[结果汇总](review-evidence/summary.json)保存实现参考提交、可执行文件SHA256、输入SHA256、期望核对结果。反序一致性的展示仅限所列安全计数冲突例，不声称所有溢出输入均有顺序不变的部分总量。

## 验证及性能证据

- 本地原生35项、wasm-gc35项单元测试，CLI 9项集成测试；另有上述9个技术演示，数量分别计算。
- 独立Python参考实现对100组小规模合成故障记录执行原顺序及乱序核对，范围不是完整输入空间。
- 实际OpenTelemetry SDK导出4个span后由MoonBit导入、规范化和核对；SDK执行真实，模型用量由测试设置，没有真实LLM调用。
- 0.2.0源码的[Linux/macOS CI](https://github.com/nawei123/runledger/actions/runs/40216615978)通过；独立注册表消费者从mooncakes安装0.2.0后native和wasm-gc公共接口验证通过。

任务/阶段预建哈希成员索引，平均避免逐调用线性扫描任务清单。仍需处理输入字节、记录和预期任务×阶段，内存仍是整文件级别；新增索引没有把整个检查变成常数空间或流式处理。

本机macOS arm64、同工具链原生debug、预热后各5次交替运行的端到端CLI比较：10万条合成调用从4.66468秒降到0.45346秒，基础报告逐次相同。基线765dd81、候选5378ae2；最后核心提交2da6e64没有改变被测覆盖索引。见[全部原始样本及复现方法](../benchmarks/README.md)。这不证明模型推理加速、内存降低或竞品性能优势。

## 相关方案与尚缺证据

[市场研究](market-research.md)和[MoonBit生态核查](ecosystem.md)覆盖12类外部方案与11个相关MoonBit项目。Langfuse/LangSmith等已具备用量追踪；AgentCanary、MoonFlowGraph及agent-eval已有离线执行规则或完整性检查。RunLedger不声称这些方向空白，也尚未取得上游集成或用户采纳。

当前仍缺真实脱敏提供者日志、真实使用者反馈及独立项目必要性的外部证明。它不验证时间先后、DAG依赖、防篡改、提供者真实账单或答案正确性，不支持任意OTLP，不能将计划写成已实现功能。

这些材料能证明实现行为和验证过程，不能单独证明已经满足赛事对实际价值和工程深度的要求。是否允许重报及如何评估，由赛事组决定。
