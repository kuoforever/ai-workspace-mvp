# 复用与新增实现

这个仓库是个人本机工程设计评审应用。既有知识、界面与框架依赖保留来源，新增逻辑按下面的范围描述。

| 来源 | 实际复用 | 本项目新增 |
|---|---|---|
| 个人 SWE 工作台，版本 `2026.09.27-2` | `static/index.html` 的原 UI、工程手册、249 项检查、33 类决策、110 篇文档及原实验材料；`knowledge/catalog.json` 是对应文本索引 | AI 面板、只读手册导航接口、AI 报告与原人工记录分开保存 |
| [agent-crash-recovery-bench](https://github.com/kuoforever/agent-crash-recovery-bench)，参考版本 `e518896d943d7ca31c5b12f1afa0b4d434ab24b6` | StateGraph、SqliteSaver、interrupt 的使用方式；没有搬入桌面执行器 | 等待宿主、等待用户和最终报告的固定评审流程 |
| 个人 PolicyFlow | 输入契约、请求键去重和证据校验的设计思路 | 面向 Web/MCP 评审的独立实现；没有复制其运行时、SDK 或测试数据 |
| [FastAPI](https://github.com/fastapi/fastapi)、[LangGraph](https://github.com/langchain-ai/langgraph)、[MCP Python SDK](https://github.com/modelcontextprotocol/python-sdk) 及锁定依赖 | 框架与协议库，通过包管理器安装 | API、MCP 工具、引用验证、应用快照、协议测试及可复现评测 |

原 SWE HTML 摘要见 `knowledge/provenance.json`。其中的本机来源路径是导入追踪信息，不是运行依赖。手册中已有外部资料链接和引用保持原样；上游依赖仍遵循各自许可。本仓库暂未另行授予覆盖全部内容的开源许可。

历史项目的测试数量不计入本项目。`evidence/` 和 `evals/runs/pilot-mcp/` 仅包含演示设计、报告与验证记录；用户运行时数据库、`.env` 和虚拟环境不入库。固定样本的标签、同会话试跑与独立评测在文档中分别说明。
