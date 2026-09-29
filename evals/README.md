# 小型评测与证据

固定样本见 `cases.json`，冻结摘要见 `manifest.json`，判据与限制见 `protocol.md`。4 个开发样本、8 个验收样本覆盖完整材料、信息不足、并发、结果未知、对象授权、不适用与资料内伪指令。

本轮完成的是 **MCP 同会话试跑**：8 份报告经真实 stdio MCP 提交后保存，17 条引用通过逐字校验。来源、输出、工具回执与保存后的报告均在 `runs/pilot-mcp/`。当前会话已见参考标签，所以不能把 8/8 标签匹配或 17/17 引用匹配写成独立模型质量结果。

`direct` 对照输入已经生成，尚未运行独立模型。`comparison.json` 明确保留 `not_run` 和 null，不虚构相对提升。当前宿主模型版本、调用数量、token、费用和模型延迟不可可靠归属，均不填估算数字。

## 重现离线核对

从项目根目录执行：

```powershell
uv run python -m evals.benchmark freeze
uv run python -m evals.benchmark score evals/runs/pilot-mcp/responses.json --out evals/runs/pilot-mcp/score.json
uv run pytest -q
```

freeze 对已存在版本只验证，不覆盖变化。score 核对已保存的模型输出，不会调用模型，也不会将历史工具回执重新执行。

## 运行新的一轮

1. 用单独端口和空数据目录启动 Web 服务，避免评测混入日常记录。例如设置 `AI_WORKSPACE_DATA` 为独立目录，端口使用 8766。
2. 执行 `uv run python -m evals.mcp_run queue --url http://127.0.0.1:8766 --run-id <唯一运行名> --out <新目录>/queue.json`，创建验收集 MCP 记录并保存上下文。
3. 让获授权的宿主在独立上下文生成结果。使用 `inputs/direct-acceptance.json` 或 `inputs/mcp-acceptance.json`；两者都不包含 reference/rubric。结果信封格式参考 `runs/pilot-mcp/responses.json`，独立运行须另记模型版本、推理设置及运行环境。
4. MCP 组执行 `uv run python -m evals.mcp_run submit --url http://127.0.0.1:8766 --queue <新目录>/queue.json --responses <新目录>/responses.json --out <新目录>/receipts.json`。direct 组只离线评分，不伪称经过 MCP。
5. 两组均用 score 核对结构和来源，再由独立评审者判断引用是否支持结论、风险遗漏和建议质量。此前保持人工质量指标为 null。

队列中的 live MCP 上下文允许澄清，而本次固定比较要求最终报告。运行者应遵循 `protocol.md` 的单次最终报告约束；一轮问答的恢复能力已在应用回归中独立验证。

本轮评测没有启动额外模型子代理或独立 API 调用。新增的工具只负责固定输入、协议提交、保存和核对，不会自动生成答案。代码检索目前按检查主题取固定有界片段，可能包含与具体问题关系较弱的候选；后续优化需用开发样本，不能在验收集上反复调参。
