# RunLedger

MoonBit 编写的 Agent 日志离线对账库与 CLI。把一次实验中的请求记录、Token 用量和预期任务清单放在一起检查，避免重复日志被重复统计、漏掉整道任务或把缺失用量算成零。

本项目仍是本地开发版本，尚未发布到 GitHub 或 mooncakes.io。以下命令在源码目录运行，不要求 GPU、模型服务或 API Key。

## 快速运行

安装 [MoonBit CLI](https://www.moonbitlang.com/download)，进入项目目录：

```sh
moon run cmd/runledger -- audit examples/clean.jsonl examples/manifest.json
moon run cmd/runledger -- audit examples/broken.jsonl examples/manifest.json
moon run cmd/runledger -- audit-ollama examples/ollama.jsonl examples/manifest.json
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

核心接口为 `audit(text)`、`audit_with_manifest(text, manifest_text)`、`import_ollama(text)` 和 `audit_records(parsed, manifest_text?)`。调用方可接入自有日志收集器；底层结构与完整接口见 `pkg.generated.mbti`。

运行全部本地检查：

```sh
bash scripts/verify.sh
moon test --target wasm-gc --deny-warn
```

CLI 退出码：`0` 检查通过；`1` 有诊断；`2` 参数错误或输入文件无法读取。归一化命令如有格式错误，不输出部分 JSONL，而输出错误报告并退出 `1`。所有命令只读取输入文件、将结果写入 stdout，文件保存由调用方重定向。

## 兼容性与边界

本地已验证 macOS arm64、moonc `v0.10.17+d971670cd` 的原生构建、21 项单元测试、6 项 CLI 集成测试；相同 21 项单元测试也在 wasm-gc 通过。GitHub Actions 配置覆盖 Linux 和 macOS，尚未在公开仓库运行。

当前逐文件读入内存，适合中小型日志；未验证大规模吞吐。仅支持自定义规范化 JSONL 和指定 Ollama 封装格式，未声称兼容所有 Agent 框架。未接入真实模型运行日志，尚需补充脱敏真实样本的集成验证。

离线日志可被修改，检查结果不能证明调用确实发生、原始账单真实、答案正确或符合某项比赛要求。报告不会复制 prompt 或回答正文；标识字段和 manifest 缺失项仍会出现在报告里，分享前应自行脱敏。

## 生态定位与许可证

[查重与差异说明](docs/ecosystem.md) 列出了现有 JSON、tracing、Agent 监控和回放项目。RunLedger 聚焦已有调用记录的离线一致性与任务覆盖检查，不提供新的 JSON 解析器或 Agent 运行框架。

Apache-2.0。依赖 `moonbitlang/core` 和 `moonbitlang/x@0.5.6`，未复制其他 Agent 项目实现。开发使用了 AI 辅助，设计、实现与测试需要由维护者复核并能够解释。
