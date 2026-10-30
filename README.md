# RunLedger

MoonBit 编写的 Agent 日志离线对账库与 CLI。把一次实验中的请求记录、Token 用量和预期任务清单放在一起检查，避免重复日志被重复统计、漏掉整道任务或把缺失用量算成零。

项目源码公开于 [nawei123/runledger](https://github.com/nawei123/runledger)，包已发布到 [mooncakes.io](https://mooncakes.io/docs/nawei123/runledger)。以下命令在源码目录运行，不要求 GPU、模型服务或 API Key。

在其他 MoonBit 项目中安装库：

```sh
moon add nawei123/runledger
```

在使用该库的包的 `moon.pkg` 中添加 `"nawei123/runledger" @ledger` 导入。仅测试使用的依赖应放入 `import { ... } for "test"`，避免开启 `--deny-warn` 时出现未使用导入警告。

## 大规模日志与中断恢复（0.3.0）

新增原生Linux/macOS外部审计：按受限批次读入和排序，通过磁盘多路归并完成跨分片对账，再按原始行号归并。完整诊断逐条落盘，支持内容绑定的检查点、独占锁和中断后恢复。它用磁盘与额外处理时间换取较低常驻内存，batch_bytes不是硬RSS限制。

```sh
job_root=$(mktemp -d)
moon run cmd/runledger-large -- examples/clean.jsonl "$job_root/job" --manifest examples/manifest.json
moon run cmd/runledger-large -- examples/clean.jsonl "$job_root/job" --manifest examples/manifest.json --resume
```

[完整架构、恢复协议与边界](docs/external-audit.md)说明为什么仅按行读取不够、如何撤销跨分片冲突以及为何需要恢复原始顺序。旧audit接口与输出结构保留；新模式的完整诊断在工作目录findings.jsonl，摘要输出使用独立schema。

## 快速运行

安装 [MoonBit CLI](https://www.moonbitlang.com/download)，获取源码并进入项目目录：

```sh
git clone https://github.com/nawei123/runledger.git
cd runledger
moon run cmd/runledger -- audit examples/clean.jsonl examples/manifest.json
moon run cmd/runledger -- audit examples/broken.jsonl examples/manifest.json
moon run cmd/runledger -- audit-ollama examples/ollama.jsonl examples/manifest.json
moon run cmd/runledger -- audit-spans examples/sdk-spans.jsonl examples/manifest.json
moon run cmd/runledger -- audit-detail examples/clean.jsonl examples/manifest.json
```

第一个命令返回 `ok: true`，共 4 次调用，输入 406 Token、输出 86 Token。第二个命令返回非零退出码，并报告重复调用、缺失用量、错误模型和缺失阶段。所有示例均为合成数据，不代表真实模型输出或比赛成绩。

也可以先转换封装的 Ollama 最终响应，再检查：

```sh
moon run cmd/runledger -- normalize-ollama examples/ollama.jsonl > /tmp/runledger-calls.jsonl
moon run cmd/runledger -- audit /tmp/runledger-calls.jsonl examples/manifest.json
```

原始 Ollama 响应缺少任务与运行标识，需要调用方添加封装字段，格式见 [协议说明](docs/protocol.md)。仅支持最终 `done=true` 响应或明确错误对象；逐块流式响应必须先由调用方收集到最终结果。

## 三个使用场景

1. 比较本地 LLM 优化前后的实验用量：保留每次失败尝试和重试，通过运行与调用 ID 去重，检查是否漏记 provider 用量。项目本身不比较答案准确率。
2. 检查多阶段批量评测是否完整：从独立任务清单要求每道题同时具有成功的 `answer` 和 `review`；日志里完全没有出现的题目也会被报告。
3. 在 CI 中阻止带有不一致日志的结果入库：使用 JSON 报告和退出码作为门禁；保留原始行号定位问题，无需启动模型。

## 数据规则

- 重试使用独立 `call_id`；同一调用键是 `(run_id, call_id)`。完全相同的重复记录只算一次并报错；相互冲突的副本全部排除。
- 成功和失败请求中已记录的用量都参与统计；缺少输入或输出用量时保留未知状态，不当成零用量的完整调用。
- `ok` 表示本次选定检查均通过；`usage_complete` 只表示日志中用量账目完整，不表示覆盖了全部预期任务。完整工作流判断应提供 manifest。
- 输出总量字段使用十进制字符串表示 Int64；规范化调用记录中的计数仍是 JSON 数字。各计数和累计量限制为 `0..9007199254740991`。
- 用量表示 provider 已报告的观察值，不估算价格，不自行分词，不把缓存或推理 Token 明细再次加到总量上。

## 库接口

核心接口为 `audit(text)`、`audit_with_manifest(text, manifest_text)`、`import_ollama(text)` 和 `audit_records(parsed, manifest_text?)`。新增 `import_spans(text)`、`audit_detail(text, manifest_text?)`、`detail_records(parsed, manifest_text?)` 提供SDK导入和分组报告。调用方可接入自有日志收集器；底层结构与完整接口见 `pkg.generated.mbti`。

[验收演示与发布检查](docs/acceptance.md) 提供可复现报告生成命令及独立注册表消费者验证。

运行全部本地检查：

```sh
bash scripts/verify.sh
moon test --target wasm-gc --deny-warn
python3 scripts/check_invariants.py
```

CLI 退出码：`0` 检查通过；`1` 有诊断；`2` 参数错误或输入文件无法读取。归一化命令如有格式错误，不输出部分 JSONL，而输出错误报告并退出 `1`。所有命令只读取输入文件、将结果写入 stdout，文件保存由调用方重定向。

## 兼容性与边界

本地已验证 macOS arm64、moonc `v0.10.17+d971670cd` 的原生构建、39 项单元测试（37项可移植核心、2项原生摘要向量）、9 项原CLI集成测试及16项外部引擎黑盒测试；37项可移植核心测试在wasm-gc通过。GitHub Actions 配置覆盖 Linux 和 macOS，实际运行结果见 [CI 工作流](https://github.com/nawei123/runledger/actions/workflows/ci.yml)。

旧audit模式逐文件读入内存，新external模式按受限批次处理。已对10万条合成调用进行本机端到端基准，结果及局限见[研究与改进说明](docs/market-research.md)，未验证持续生产吞吐或内存峰值。支持规范化JSONL、指定Ollama封装及[有明确边界的SDK span配置](docs/span-profile.md)，不支持任意OTLP或所有Agent框架。实际SDK导出互操作已验证，模型用量仍为合成；真实脱敏提供者日志验证尚未完成。

离线日志可被修改，检查结果不能证明调用确实发生、原始账单真实、答案正确或符合某项比赛要求。报告不会复制 prompt 或回答正文；标识字段和 manifest 缺失项仍会出现在报告里，分享前应自行脱敏。

## 生态定位与许可证

[查重与差异说明](docs/ecosystem.md) 列出了现有 JSON、tracing、Agent 监控和回放项目。RunLedger 聚焦已有调用记录的离线一致性与任务覆盖检查，不提供新的 JSON 解析器或 Agent 运行框架。

Apache-2.0。依赖 `moonbitlang/core` 和 `moonbitlang/x@0.5.6`，未复制其他 Agent 项目实现。开发使用了 AI 辅助，设计、实现与测试需要由维护者复核并能够解释。

## 详细报告与外部数据

`audit-detail`在原有报告外增加schema_version、行/身份统计、诊断计数和按运行/阶段/模型的分组。各组显示缺少输入及输出计数的调用数。若全局累计量溢出安全范围，group_totals_available为false并清空groups，避免分组和受限总量形成误导性对照。旧audit输出结构保持不变。

manifest是检查合同，不是过滤器：混入的外部运行/模型记录会使检查失败，其已知用量仍属于输入日志观察值。分组内用量完整不表示任务覆盖完整；使用总量作实验结论前应检查全局report.ok与合同是否适用。

SDK配置要求显式模型调用类型、任务标识和OK/ERROR状态；UNSET不会被当作成功，父级Agent汇总span不能混作模型调用，语义属性冲突会被报告。见[配置说明](docs/span-profile.md)。

同类方案、借鉴关系、改进内容及基准方法见[市场研究](docs/market-research.md)。本项目主张MoonBit生态内的工程集成与性能改进，不主张首创Token统计或trace合同。

[技术补充与九个可重放实例](docs/review-supplement.md)提供具体输入、诊断、实现位置和证据边界。新增实例用于解释已有0.2.0行为，不代表新增核心能力或赛事认可。

0.3.0同构建百万条合成调用观测：内存模式峰值约631 MiB，外部模式约5.8 MiB；耗时约5.2秒与86秒，账目一致。[原始结果、复现和限制](benchmarks/external-README.md)。增量库接口UsageFold、CoverageIndex供已验证且完成身份对账的记录使用；外部引擎入口位于nawei123/runledger/external，原生I/O适配不进入可移植核心。
