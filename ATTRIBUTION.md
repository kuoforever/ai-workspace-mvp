# 来源与依赖

## 知识与界面

工程手册、249 项检查、33 类决策、110 篇文档和基础 Web 界面来自个人 SWE 工作台 `2026.09.27-2`。`knowledge/catalog.json` 为对应内容索引，[provenance.json](knowledge/provenance.json) 记录导入版本及来源摘要。材料中的外部引用保持原样。

## 实现参考

| 项目 | 使用方式 |
|---|---|
| [agent-crash-recovery-bench](https://github.com/kuoforever/agent-crash-recovery-bench)，`e518896d943d7ca31c5b12f1afa0b4d434ab24b6` | 参考 StateGraph、SqliteSaver 和 interrupt 的使用方式，实现评审等待与恢复 |
| 个人 PolicyFlow | 输入契约、幂等控制与证据校验的设计参考 |
| 个人 SWE `android-work` 实验 | 复用 Gradle Wrapper 和 Android 构建配置起点 |
| 个人 SWE `ios-recording` 实验 | 应用状态管理、显式恢复与原生分享的组织方式参考 |

## 第三方依赖

- [FastAPI](https://github.com/fastapi/fastapi)：HTTP 服务。
- [LangGraph](https://github.com/langchain-ai/langgraph)：工作流和持久检查点。
- [MCP Python SDK](https://github.com/modelcontextprotocol/python-sdk)：stdio MCP 适配。
- [Gradle](https://github.com/gradle/gradle)：Android 构建与 Wrapper，保留上游 Apache-2.0 许可。
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：生成 Xcode 工程。
- [OkHttp](https://square.github.io/okhttp/)：Android 异步 HTTP 与请求取消；MockWebServer 用于网络边界测试。
- [AndroidX Benchmark](https://developer.android.com/jetpack/androidx/releases/benchmark)：Android 优化构建的启动与帧时长测量。

Python 依赖版本见 [uv.lock](uv.lock)，移动端依赖见各端构建配置。第三方依赖和导入材料保留各自的许可与引用信息；本仓库尚未设置统一的开源许可。
