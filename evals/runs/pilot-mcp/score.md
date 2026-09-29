# 固定样本运行结果

配置：mcp · acceptance · same_session_pilot

- 有效最终报告：8 / 8。缺失样本保留在分母。
- 逐字有效引用：17 / 17。
- 合成样本参考标签一致：8 / 8。
- 人工语义支持率、宿主 token、费用和模型延迟：未测量。

同会话试跑不是独立盲测；上述数值不代表开放任务成功率，也不证明相对直接提示的提升。

| 样本 | 类别 | 结构与引用 | 参考标签 |
|---|---|---|---|
| accept-01 | concurrency | 通过 | 一致 |
| accept-02 | parameter_conflict | 通过 | 一致 |
| accept-03 | unknown_effect | 通过 | 一致 |
| accept-04 | not_applicable | 通过 | 一致 |
| accept-05 | missing_contract | 通过 | 一致 |
| accept-06 | tenant_scope | 通过 | 一致 |
| accept-07 | data_path | 通过 | 一致 |
| accept-08 | unrelated_injection | 通过 | 一致 |
