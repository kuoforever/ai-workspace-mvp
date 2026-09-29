# iOS 原生客户端

SwiftUI + URLSession + Codable，最低 iOS 17，无第三方运行时依赖。与 Web、Android 共用 FastAPI / SQLite / MCP 工作流，支持评审列表、新建、检查项选择、澄清回答、引用快照和原生分享。

草稿与回答随编辑原子保存；提交前落盘请求键和原始请求体。连接中断、服务端 5xx 或无效响应保留原提交，重启后由用户重试。4xx 明确拒绝后可刷新再提交。文件损坏时停止写入，不静默丢弃请求记录。当前不承诺设备断电后的持久化保证。

## Mac 本机运行

需要 Xcode（CI 固定 16.4）、已安装的 iOS 模拟器、XcodeGen 和 uv。在仓库根目录：

```sh
uv sync --frozen --python 3.12
uv run uvicorn app.api:app --host 127.0.0.1 --port 8765
```

在另一个终端生成项目并打开：

```sh
brew install xcodegen
bash ios/generate.sh
open ios/AIWorkspace.xcodeproj
```

选择 AIWorkspace scheme 和 iPhone 模拟器运行。客户端固定连接 `http://localhost:8765/api`，模拟器使用 Mac 的本机网络；服务继续只监听回环地址。ATS 仅为本机连接放行，HTTP 重定向被拒绝。

选择“离线模拟”可不接模型演示；选择“助手评审”后，在同一台 Mac 上将 `swe-workspace` MCP 接入桌面助手，按根目录 README 操作。iOS 端不托管模型，也不保存模型密钥。

## 自动验证与交付范围

`.github/workflows/ios.yml` 在 macOS 15 / Xcode 16.4 / iPhone 16 / iOS 18.5 上执行。单元测试覆盖请求丢失回复后的恢复、请求替换拒绝、磁盘写入失败、4xx/5xx、损坏响应及损坏日志；两条 UI 流程覆盖草稿/回答重启恢复、报告/来源/分享入口，以及电脑创建到手机继续的 MCP 协议流程。MCP 测试使用显式夹具，不代表真实模型质量。

运行 `bash scripts/ios-simulator-check.sh` 前先启动后端。脚本输出测试结果、截图、录屏和 `AIWorkspace-simulator.app.zip`；实际构建和验证结果以 CI 及仓库证据为准。

交付物是 **iOS Simulator 应用**。不含 iPhone 真机签名、IPA、TestFlight 或 App Store 发布。真机的 localhost 属于手机自身，不能直接访问 Mac；真机连接方式和签名留作后续独立任务。
