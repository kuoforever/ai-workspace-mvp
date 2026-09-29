# 评测

评测工具用于检查设计评审输出的结构、检查覆盖、引用来源与协议处理。数据集包含 12 个合成工程场景，分为 4 个开发样本和 8 个验收样本。

| 文件 | 内容 |
|---|---|
| [cases.json](cases.json) | 设计材料、检查项与参考判据 |
| [protocol.md](protocol.md) | 已冻结的 v1 实验协议 |
| [manifest.json](manifest.json) | 样本、协议、知识与输出 Schema 的摘要 |
| [runs/pilot-mcp/](runs/pilot-mcp/) | 已保存的预实验输入、输出、协议回执与评分 |

## 输入配置

| 配置 | 模型输入 |
|---|---|
| `direct` | 设计材料与选中检查卡 |
| `mcp` | 相同资料，加上有界检索的手册与决策片段；经 MCP 提交结果 |

两组均要求一次最终报告，不使用澄清。比较同时涉及检索内容和处理流程，不能单独归因于 MCP 协议。独立实验需使用相同模型版本、推理设置及隔离上下文，并记录运行环境。

## 已有结果

`pilot-mcp` 保存了 8 份报告，17 条引用通过逐字校验。该记录标记为 `same_session_pilot`：生成上下文接触过参考判据，因此用于验证协议与可追溯性，不作为盲测结果。

独立 direct/MCP 对照尚未运行。人工语义支持、模型 token、费用和模型端延迟尚无测量值，记录为 `null`。详细结果见 [score.md](runs/pilot-mcp/score.md)。

## 核对已保存结果

在项目根目录执行：

```sh
uv run python -m evals.benchmark freeze
uv run python -m evals.benchmark score evals/runs/pilot-mcp/responses.json --out work/pilot-score.json
```

`freeze` 检查 v1 内容是否与摘要一致；`score` 核对已保存输出，不调用模型或重放历史写操作。冻结版本的协议与数据按原样保留，修改判据需建立新版本。

## 新建实验

1. 使用独立数据目录和本机端口启动后端，例如设置 `AI_WORKSPACE_DATA` 并使用 8766 端口。
2. 为两组准备输入：

   ```sh
   uv run python -m evals.benchmark prepare --profile direct --split acceptance --out work/eval/direct-input.json
   uv run python -m evals.benchmark prepare --profile mcp --split acceptance --out work/eval/mcp-input.json
   ```

3. MCP 组创建评审队列并保存上下文：

   ```sh
   uv run python -m evals.mcp_run queue --url http://127.0.0.1:8766 --run-id my-run --out work/eval/queue.json
   ```

4. 在独立模型上下文生成响应，遵循 v1 的最终报告约束。输出格式参考 [responses.json](runs/pilot-mcp/responses.json)，独立运行使用 `run_type: independent`。工具本身不生成答案。
5. MCP 组提交响应；direct 组直接进行离线评分：

   ```sh
   uv run python -m evals.mcp_run submit --url http://127.0.0.1:8766 --queue work/eval/queue.json --responses work/eval/mcp-responses.json --out work/eval/receipts.json
   uv run python -m evals.benchmark score work/eval/mcp-responses.json --out work/eval/mcp-score.json
   uv run python -m evals.benchmark score work/eval/direct-responses.json --out work/eval/direct-score.json
   ```

6. 由独立评审者检查引用支持、风险遗漏和建议质量。缺失或失败样本保留在统计分母中，未进行的人工评审保持为 `null`。

澄清和恢复能力由应用测试覆盖，运行命令见[开发指南](../docs/development.md)。
