# AI Workspace

[![CI](https://github.com/kuoforever/ai-workspace-mvp/actions/workflows/ci.yml/badge.svg)](https://github.com/kuoforever/ai-workspace-mvp/actions/workflows/ci.yml)
[![Android](https://github.com/kuoforever/ai-workspace-mvp/actions/workflows/android.yml/badge.svg)](https://github.com/kuoforever/ai-workspace-mvp/actions/workflows/android.yml)
[![iOS](https://github.com/kuoforever/ai-workspace-mvp/actions/workflows/ios.yml/badge.svg)](https://github.com/kuoforever/ai-workspace-mvp/actions/workflows/ios.yml)

以工作台为输入的 AI 任务平台。带入完整的内容、结构、进度和业务要求，说明本次目标与交付要求，让连接 MCP 的助手生成带原文引用的结果。每条要求都保留满足情况、缺失证据或冲突。

通用工作台支持评审、总结、对比、整理、补写和计划。软件工程设计评审是其中一个模板。Android 与 iOS 保留原生工程评审流程，并提供通用工作台的浏览器入口。

![通用工作台示例（离线演示，含业务要求冲突）](evidence/workbench/desktop-report.jpg)

页面与协议验证记录见 [通用工作台验证](evidence/workbench/README.md)。

## 功能

- 工作台输入：导入 `ai-workbench` JSON / 数据 HTML，以及已有工程工作台 HTML / JSON；结构、对象关系、状态、来源与要求经过接入校验。
- 三层要求：平台接入规则、工作台业务要求、用户本次任务要求。每份工作台至少一条要求，每条包含来源、适用对象和验收方式。
- 通用任务：六类任务独立声明目标、范围与产物；每条工作台和任务要求均有结论，字段规则与已识别冲突不能被模型覆盖。
- 修改接续：整理、补写、计划可以生成修改建议；用户选择后生成新版本，保留原快照，检查版本及冲突。
- 恢复与导出：Web 保存输入、原请求和最近打开的任务，支持未知结果重试、离线阅读来源以及 Markdown / JSON 导出。
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

打开 [通用工作台](http://127.0.0.1:8765/workspace)，载入活动筹备示例或导入自己的工作台，选择任务类型并填写目标和交付要求。选择“离线演示”可检查流程、字段规则与冲突；真实语义处理由连接 MCP 的助手提供。原[工程评审模板](http://127.0.0.1:8765/engineering?ai)继续可用。

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
- [工作台输入规范](docs/workbench-contract.md)：接入要求、工作台要求、任务要求、导入格式、结果与版本规则。
- [开发指南](docs/development.md)：目录、配置、测试与构建。
- [移动端质量](docs/mobile-quality.md)：取消与重试、优化构建、模拟器性能复现和[实测基线](evidence/mobile/quality/README.md)。
- [评测](evals/README.md)：数据集、实验方法与结果。
- [测试报告](evidence/README.md)：与源码提交绑定的检查结果、截图与录屏。
- [来源与依赖](ATTRIBUTION.md)：知识内容、设计参考和第三方依赖。
