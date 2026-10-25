# 可复现演示与发布检查

项目仓库：https://github.com/nawei123/runledger

## 工程验证

```sh
bash scripts/verify.sh
moon test --target wasm-gc --deny-warn
python3 scripts/acceptance.py
```

`scripts/verify.sh` 包含依赖索引初始化、格式、静态检查、原生单元测试、构建、CLI集成测试及生成接口校验。验收演示脚本会生成 `reports/acceptance/`：

- clean.json：干净日志，exit 0，4次调用，输入406、输出86 Token。
- broken.json：故障日志，预期exit 1，报告重复调用、缺失用量、错误模型和阶段缺失。
- ollama.json：Ollama最终响应封装导入，exit 0。
- normalized.jsonl、roundtrip.json：归一化及再次检查，观察账目保持一致。
- summary.json：源码提交、工作区是否存在修改、运行平台、输入SHA256及各例结果。

所有演示数据都是合成数据。脚本输出不代表真实提供者调用，也不代表赛事审核通过。报告目录被Git忽略，避免把本地运行结果误作固定源码。

## 发布检查

登录账号应与 `nawei123/runledger` 命名空间匹配：

```sh
moon whoami
moon publish --dry-run
```

确认打包内容、许可证、版本和元数据后发布。新版本号必须递增，不能重复发布同一版本。不要将登录凭据放入源码、验收材料或聊天。

发布成功后，使用独立临时工程从注册表安装并验证公共接口：

```sh
python3 scripts/verify_published.py --version 0.1.0
```

该脚本不使用本地路径依赖，在native和wasm-gc分别验证已发布包。若注册表尚未更新或尚未发布，会报错，不应将其计为成功。

mooncakes文档索引、报名审核、真实脱敏日志集成、赛事最终验收是不同事项，应分别确认状态。当前报名状态以参赛者反馈为准，审核结果以官方通知为准。
