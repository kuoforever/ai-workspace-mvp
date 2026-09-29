# Web 集成测试记录

日期：2026-09-29。此记录对应初始 Web 版本；后续自动化报告见[测试索引](README.md)。

| 检查 | 结果 |
|---|---|
| 后端与 stdio MCP 协议测试 | 15 项通过，7.55 秒 |
| Python Lint | 通过 |
| JavaScript 语法 | 通过 |
| Web 流程 | 创建、模拟评审、MCP 结果显示、刷新恢复、来源跳转和导出通过 |
| 人工记录隔离 | AI 报告完成后，人工检查状态保持原值 |

集成样本包含 2 项检查和 6 条字面引用。结果、协议回执和截图分别保存在 [mcp-review.json](mcp-review.json)、[mcp-submission.json](mcp-submission.json) 和 [mcp-review.png](mcp-review.png)。

该单例用于集成检查；未测量模型泛化质量、人工语义支持率或推理性能。
