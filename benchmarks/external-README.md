# External audit resource observations (2026-10-30)

Source commit: b6e46b4b303663fee74163e3a3d0b87ecb119440; clean source tree. Same native debug build; immutable executable copies.

| Synthetic calls | Input MiB | In-memory peak RSS MiB | External peak RSS MiB | In-memory seconds | External seconds |
|---|---|---|---|---|---|
| 100,000 | 14.75 | 72.95 | 5.88 | 1.115 | 6.250 |
| 1,000,000 | 149.41 | 631.19 | 5.83 | 5.210 | 85.991 |

One observation per size/mode, not medians. Timing includes startup, reading, sorting, writing, checksums and serialization. System load and cache state were not isolated. Per-child peak RSS is collected with POSIX wait4; macOS bytes and Linux KiB are normalized by the script. Totals, success and usage completeness agree, with independent expected totals.

No manifest was used: this does not measure memory for a million-task manifest. Inputs are synthetic. No model calls, real provider billing, OOM trial or cross-hardware guarantee. Batch bytes is a working-set target, not a hard RSS cap. External audit trades extra time and disk for lower RAM.

Reproduce with the same toolchain and a fresh output directory:

```sh
moon build --target native --deny-warn
python3 scripts/benchmark_external.py --sizes 100000 1000000 --output reports/external-benchmark-new
```

[Raw results](external-2026-10-30.json) include all values, input and executable SHA256, platform, source commit and limits. Later documentation-only commits do not change the measured core.
