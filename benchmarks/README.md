# 覆盖检查优化基准

原始结果：2026-10-26-comparison.json。机器macOS arm64，同一MoonBit工具链、两个原生debug二进制；预热后各5次并交替顺序；时间包含进程启动、文件读取、解析、检查和报告序列化。每次完整基础报告都要求相同。

基线为765dd81（0.1.1），候选为5378ae2；JSON保存各次耗时、源码提交、工作区状态和二进制SHA256。该测量发生于功能实现提交后、后续文档/验证补充之前；核心覆盖索引代码在后续版本未改变。

## 复现方法

使用Git完整历史在独立目录检出基线，安装相同编译器后构建：

```sh
git worktree add --detach /tmp/runledger-baseline 765dd81
cd /tmp/runledger-baseline
moon update
moon build --target native
```

返回当前新版源码目录：

```sh
moon build --target native
python3 scripts/benchmark_compare.py --baseline /tmp/runledger-baseline/_build/native/debug/build/cmd/runledger/runledger.exe --baseline-commit 765dd81 --build-profile native-debug --sizes 1000 10000 50000 --repeats 5
```

结果保存在reports/benchmark/comparison.json。不提交或修改基线工作树。不要将debug结果与release结果混比，也不要将本机合成负载的比率外推为生产保证。没有测量LLM推理、准确率、峰值内存或竞品性能。
