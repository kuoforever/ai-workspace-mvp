# 当前切片验证 · 2026-09-29

这是初次交付时的历史快照。后续新增了评测和跨平台测试、MCP 注册及 GitHub 交付；当前新环境验证以 [release-check.json](release-check.json) 为准。

- `uv run pytest -q`：15 passed，7.55 秒。包括隔离 Web 子进程与真实 stdio MCP 客户端的协议测试。测试输出不作为模型质量评测。
- `uv run ruff check app tests scripts`：通过。
- `node --check static/ai-review-ui.js`：通过。
- 本机浏览器：通过键盘操作完成填入示例、模拟评审、MCP 队列创建；MCP 提交后页面自动显示完成报告；刷新恢复报告；展开来源并跳转到原手册正文。
- 原工作台主页仍显示人工结果 `0 / 12`、已通过 `0`；AI 完成报告没有把人工检查自动设为通过。
- 导出 API：保存 `mcp-review.md`、`mcp-review.json`；动态 API 合约保存为 `openapi.json`。
- 真实示例：本轮 Codex 读取 MCP 返回的设计和知识，形成两项风险结论，再通过 `submit_review_output` 协议调用保存。回执见 `mcp-submission.json`，截图见 `mcp-review.png`。
- 模型示例只有 1 份，包含 2 项检查和 6 条字面引用。没有测量泛化成功率、人工语义支持率、P50/P95 或宿主 token 用量。单例不代表固定样本评测完成。
- 未执行全局 MCP 注册脚本；未修改原 SWE 或其他项目，未向 GitHub 发布，未实现原生客户端。

界面自动化遇到内嵌浏览器的鼠标点击无效、截图短暂滞后；使用页面支持的键盘操作完成验证，并待页面实际渲染后保存截图。未把自动化工具问题直接归因为应用代码缺陷。
