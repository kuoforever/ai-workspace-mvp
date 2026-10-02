# AI Workspace

[![CI](https://github.com/kuoforever/ai-workspace-mvp/actions/workflows/ci.yml/badge.svg)](https://github.com/kuoforever/ai-workspace-mvp/actions/workflows/ci.yml)
[![Android](https://github.com/kuoforever/ai-workspace-mvp/actions/workflows/android.yml/badge.svg)](https://github.com/kuoforever/ai-workspace-mvp/actions/workflows/android.yml)
[![iOS](https://github.com/kuoforever/ai-workspace-mvp/actions/workflows/ios.yml/badge.svg)](https://github.com/kuoforever/ai-workspace-mvp/actions/workflows/ios.yml)

工程设计评审工作台。提交设计、选择检查项，通过连接 MCP 的 AI 助手补充问题并生成带原文引用的报告。Web、Android 和 iOS 客户端共用后端，可在不同设备上继续同一份评审。

![评审报告示例（已保存报告回放）](evidence/demo-replay.png)

## 功能

- 工程知识库：249 项检查、33 类决策和 110 篇文档。
- 设计评审：选择检查范围、补充澄清问题、查看逐项结论与引用来源。
- 状态保存：持久化评审进度，支持幂等提交和版本冲突检测。
- 原生客户端：Android Compose 与 iOS SwiftUI，支持系统文件导入、草稿与回答后台保存、保存状态和失败重试。
- 引用阅读：定位原文行并展示上下文；移动端保留最近 20 份已打开评审，支持离线阅读报告与来源。
- 报告导出：Web 支持 Markdown / JSON；移动端从当前快照生成 Markdown 预览并调用系统分享，离线可用。

## 快速开始

需要 [uv](https://docs.astral.sh/uv/) 和 Python 3.11–3.13。CI 使用 Python 3.12。

```sh
git clone https://github.com/kuoforever/ai-workspace-mvp.git
cd ai-workspace-mvp
uv sync --frozen --python 3.12
uv run --no-sync uvicorn app.api:app --host 127.0.0.1 --port 8765
```

Windows 也可在项目目录运行 `./start.ps1`。

打开 [Web 工作台](http://127.0.0.1:8765/?ai)。选择“离线演示”可先体验完整流程；使用 AI 评审时，按[使用指南](docs/usage.md)连接桌面 MCP 助手。模型推理由助手提供。

## 客户端

| 客户端 | 运行方式 | 文档与下载 |
|---|---|---|
| Web | 浏览器访问本机服务 | [使用指南](docs/usage.md) |
| Android | USB 或模拟器，通过 ADB 转发连接电脑 | [构建与运行](android/README.md) · [Debug APK](https://github.com/kuoforever/ai-workspace-mvp/releases/tag/android-v0.2.0) |
| iOS | Mac 上的 iPhone 模拟器，通过 localhost 连接同机服务 | [构建与运行](ios/README.md) · [模拟器应用](https://github.com/kuoforever/ai-workspace-mvp/releases/tag/ios-v0.3.0) |

当前采用单进程本机部署。远程认证、云端同步和应用商店发布尚未支持。

## 技术栈

FastAPI、LangGraph、SQLite、MCP Python SDK；Web 使用 HTML / JavaScript，Android 使用 Kotlin / Jetpack Compose，iOS 使用 SwiftUI / URLSession。

## 文档

- [使用指南](docs/usage.md)：MCP 配置、评审流程、跨端接续与报告回放。
- [架构设计](docs/architecture.md)：模块、状态机、数据一致性与客户端恢复。
- [开发指南](docs/development.md)：目录、配置、测试与构建。
- [评测](evals/README.md)：数据集、实验方法与结果。
- [测试报告](evidence/README.md)：与源码提交绑定的检查结果、截图与录屏。
- [来源与依赖](ATTRIBUTION.md)：知识内容、设计参考和第三方依赖。
