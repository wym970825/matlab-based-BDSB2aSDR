# v0.2.0 小型验收证据

这里保存 2026-10-01 实际运行输出的原样副本，便于随源码版本审阅。完整 IF、MAT、日志和基线快照保留在项目忽略目录，未加入 Git。

| 本目录文件 | 原始位置（相对 results/upgrade_v020） |
|---|---|
| regression.json | regression.json，48 项自动测试 |
| frontend_release_tests.json | 同名文件，最终 10 项前端复验 |
| batch_release.json | 同名文件，批处理入口干运行 |
| validation_manifest.json | full_01/validation_manifest.json，三模式 715 秒运行 |
| comparison.json / comparison.png | full_01/comparison/ |
| reacq_audit.json / reacq_event.png | full_01/reacq_audit_release/ |
| correlation_summary.json / correlation_fidelity.png | correlation_release/ |
| forced_reacq_summary.json | forced_reacq_final/reacq_summary.json，明确标记故障注入 |
| filter_response.json | 同名文件，生产系数的频响网格检查 |
| release_checks.json | 同名文件，源码及配置一致性、探针断言 |

JSON 中的绝对路径为运行时原样记录。三种完整运行使用 `ef246c9`；之后的运行时源码变化仅为 `core/runProbeIf.m` 的显示修复，已独立验证。分析脚本哈希在对应 JSON 中，版本化脚本位于 `tests/`。图像已逐一查看。

完整性通过不等于每种方法都优于 PB。TF400 的真实重捕获、缺少后段 S4，以及仅一个数据集/单星/无 S4 真值的限制见 [验收报告](../VALIDATION.md)。
