# iOS

SwiftUI / URLSession 客户端，最低支持 iOS 17。通过共享 API 提供评审列表、创建、澄清回答、引用查看和报告分享。

## 环境

需要 Mac、Xcode、iOS 模拟器、XcodeGen 和 uv。CI 使用 Xcode 16.4、XcodeGen 2.46.0 和 iOS 18.5。

## 运行

在仓库根目录启动后端：

```sh
uv sync --frozen --python 3.12
uv run --no-sync uvicorn app.api:app --host 127.0.0.1 --port 8765
```

在另一个终端生成并打开 Xcode 项目：

```sh
brew install xcodegen
bash ios/generate.sh
open ios/AIWorkspace.xcodeproj
```

选择 `AIWorkspace` scheme 和 iPhone 模拟器运行。客户端连接 `http://localhost:8765/api`，后端需运行在同一台 Mac。

也可下载[预编译模拟器应用](https://github.com/kuoforever/ai-workspace-mvp/releases/tag/ios-v0.3.0)，解压并启动模拟器后安装：

```sh
xcrun simctl install booted AIWorkspace.app
xcrun simctl launch booted io.github.kuoforever.aiworkspace.ios
```

应用包包含 arm64 / x86_64。它是模拟器应用，不是可安装到 iPhone 的 IPA。真机连接和签名尚未支持；真机上的 localhost 指向手机自身。

## 状态管理

MainActor 状态对象管理交互；Codable 文件的读取与原子替换在同一串行后台队列执行。输入立即保留在界面，显示“正在保存输入”“输入已保存”或失败提示；失败时可“重试保存”，提交前等待最新输入落盘。网络结果未知或本机结果保存失败时保留原请求，由用户重试。前台、联网查看等待助手的记录时轮询结果。

## 文件与离线阅读

- 创建页通过系统文件选择器导入 UTF-8 的 .md、.markdown 或 .txt，保留换行和 Markdown。材料限 10–8,000 个 Unicode 字符、文件读取限 32 KiB；取消、编码错误或文件过大时保留原草稿。
- 已有设计时先确认替换。导入立即复制文本到设备草稿，读取期间使用 security-scoped URL，完成后释放访问，不保留外部文件权限。
- 已打开的最近 20 份评审保存报告与来源快照。“已保存”入口支持离线打开多份记录；原有单报告缓存自动兼容。
- 引用页显示对应原文行及上下文，突出引用片段，完整来源可展开。Markdown 导出与系统分享使用当前快照，离线可用。
- 保存失败时输入仍在界面，不能提交新的评审或回答。意外退出前仍处于“正在保存输入”的更改可能未落盘；原请求日志继续遵循先保存、再发送的规则。

顶部提供连接检查与连接帮助，等待助手时可复制当前评审的处理指令。后端连通和助手处理状态分别展示。

评审方式见[使用指南](../docs/usage.md)，数据与恢复规则见[架构设计](../docs/architecture.md#移动端恢复)。

## 界面适配

支持 iPhone 与 iPad 模拟器、横竖屏、系统深色模式和 Dynamic Type。正文最大宽度为 840 pt；连接与恢复提示随页面滚动。在辅助功能大字体下，连接操作自动换行，评审方式采用可换行的独立选项。

创建页提交入口固定在导航栏右上角，键盘显示、横屏和大字体下仍可使用。切换评审方式或打开检查项时会结束当前输入。

## 测试

在仓库根目录执行，后端须已启动，且 Xcode 中已安装 iOS 18.5 的 iPhone 16 模拟器：

```sh
bash scripts/ios-simulator-check.sh
```

脚本执行 XCTest 和 XCUITest，输出模拟器应用、`.xcresult`、截图和录屏到 `ios-evidence/`。测试覆盖提交恢复、原生评审流程、草稿与回答重启恢复，以及跨端接续。

两端使用同一份[已保存模型报告](../fixtures/mobile-review.json)验证澄清回答与报告接续。样本的真实 MCP 生成记录见[移动端验证](../evidence/mobile/README.md)，模拟器中执行的是回放。

脚本另在 iPhone SE（第三代）和 iPad 模拟器上启用深色模式与最大辅助功能字体，检查键盘输入、旋转后的草稿、可操作的提交按钮与平板报告宽度。每个设备单独保存测试结果和截图。真机和不同系统版本的兼容性仍需设备验证。

[界面适配结果与截图](../evidence/mobile/adaptation/README.md)

[测试结果与截图](../evidence/ios/README.md) · [来源与依赖](../ATTRIBUTION.md)
