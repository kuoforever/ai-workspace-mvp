# 测试报告

这里保存发布版本的测试摘要、接口快照和截图。运行环境、源码提交及产物摘要记录在各报告中。

## 自动化检查

| 范围 | 已记录结果 | 环境 | 报告 |
|---|---|---|---|
| 后端与协议 | 24 项测试通过 | Windows / Ubuntu，Python 3.12 | [CI](https://github.com/kuoforever/ai-workspace-mvp/actions/runs/36583017834) |
| Android | 9 项单元测试、2 条界面流程、6 项进程外检查通过 | Android 15 / API 35 模拟器 | [移动端验证](mobile/README.md) |
| iOS | 10 项单元测试、2 条界面流程通过 | iPhone 16 / iOS 18.5，arm64 模拟器 | [移动端验证](mobile/README.md) |

客户端流程使用模拟数据和已保存的模型输出回放；真实 MCP 生成记录与模拟器回放分别保存。模型输出质量另见[评测文档](../evals/README.md)。本地复现命令见[开发指南](../docs/development.md)。早期发布记录见 [Android v0.2.0](android/README.md) 和 [iOS v0.3.0](ios/README.md)。

## 集成记录

- [release-check.json](release-check.json)：指定提交在新目录、新虚拟环境中的安装与回归检查。
- [mcp-registration.json](mcp-registration.json)：MCP 启动、工具发现与知识读取检查。
- [verification.md](verification.md)：初始 Web 集成测试记录。
- [openapi.json](openapi.json)：HTTP 接口快照；运行中的 `/openapi.json` 为当前合约。
- [示例报告](mcp-review.md)及 [JSON](mcp-review.json)：一份已保存的 MCP 评审。
- [回放截图](demo-replay.png)：示例报告通过 MCP 回放后的界面。

记录与其源码版本绑定；历史结果不自动代表后续版本。当前构建状态可从项目首页的 CI 链接查看。
