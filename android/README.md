# Android

Kotlin / Jetpack Compose 客户端，通过共享 API 提供评审列表、创建、澄清回答、引用查看和报告分享。

## 环境

- JDK 17、Android SDK Platform 36、Build Tools 35.0.0。
- Gradle Wrapper 8.11.1、AGP 8.10.1、Kotlin 2.1.20、Compose BOM 2025.04.01。
- Android 模拟器，或已开启 USB 调试的设备。

用 Android Studio 打开本目录。SDK 路径通过 `local.properties` 或 `ANDROID_HOME` 配置。

## 运行

1. 按[快速开始](../README.md#快速开始)启动电脑上的后端。
2. 连接设备并建立端口转发：

   ```sh
   adb reverse tcp:8765 tcp:8765
   ```

3. 安装[预编译 Debug APK](https://github.com/kuoforever/ai-workspace-mvp/releases/tag/android-v0.2.0)，或从本目录构建：

   ```powershell
   ./gradlew.bat :app:assembleDebug
   adb install -r app/build/outputs/apk/debug/app-debug.apk
   ```

4. 打开 AI Workspace。评审方式与 MCP 连接见[使用指南](../docs/usage.md)。

macOS / Linux 使用 `./gradlew`。存在多个设备时，为 `adb` 添加 `-s <设备序列号>`；设备断开或模拟器重启后需重新建立转发。

客户端固定连接 `127.0.0.1:8765`，ADB 将其转发到电脑后端。当前使用本机开发连接，发布包为调试签名。

## 状态管理

ViewModel 管理页面状态；草稿、回答、缓存和提交日志的磁盘操作通过同一串行后台执行器完成。输入立即保留在界面，显示“正在保存输入”“输入已保存”或失败提示；失败时可“重试保存”，提交前会等待最新输入落盘。SharedPreferences 保存草稿和缓存，AtomicFile 保存待确认请求。连接中断或结果无法写入本机时，可以用原幂等键重试；版本冲突时保留输入并提示刷新。仅在前台、联网查看等待助手的记录时自动刷新。

## 文件与离线阅读

- 创建页通过系统文件选择器导入 UTF-8 的 .md、.markdown 或 .txt。保留换行和 Markdown；材料限 10–8,000 个 Unicode 字符、文件读取限 32 KiB。编码错误、过大文件和取消选择不会替换原草稿。
- 已有设计时先确认替换；导入后可继续编辑，文件不会自动提交，也不保留外部文件的访问权限。
- 已打开的最近 20 份评审（包含报告与来源快照）保存在设备。“已保存”入口可直接打开任一份；已有单报告缓存会自动兼容。
- 引用页定位到对应原文行，突出引用并展示前后文；完整来源可展开。离线也可生成当前快照的 Markdown 并打开系统分享。
- 应用意外退出前尚处于“正在保存输入”的更改可能未落盘；保存状态不会把未完成或失败的写入显示为成功。提交仍要求先持久化原请求再发送。

启动时记录损坏会进入恢复页面，保留文件并暂停写入。顶部提供连接检查和连接帮助；等待助手时可以复制当前评审的处理指令。

详细的数据与重试规则见[架构设计](../docs/architecture.md#移动端恢复)。

## 界面适配

跟随系统深色模式和字体大小，支持横竖屏与可调整窗口。平板或宽窗口中的正文最大宽度为 840 dp。连接、错误与恢复提示随页面滚动；键盘出现时避开输入区域，检查项和连接帮助可滚动查看。

## 测试

在本目录执行：

```powershell
./gradlew.bat :app:testDebugUnitTest :app:lintDebug
adb reverse tcp:8765 tcp:8765
./gradlew.bat :app:connectedDebugAndroidTest
```

设备测试需要后端服务和已连接的模拟器。CI 使用隔离数据库，在 Android 15 / API 35 模拟器测试创建、澄清、Activity 重建、报告、引用与跨端接续，并保存截图和录屏。

CI 还从应用进程外执行 `scripts/android-process-check.py`，验证强制结束进程后的草稿、回答和原请求恢复，以及断网重试、只读连接检查和损坏日志的恢复页面。该脚本只接受隔离模拟器。模型报告样本见[移动端验证](../evidence/mobile/README.md)；CI 使用已保存输出，不调用模型。

界面适配测试在隔离模拟器中切换到 360 dp 宽度、两倍系统字体和深色模式，检查输入、横屏草稿保留、提交与宽窗口阅读宽度。测试结束后恢复系统设置；不会在真机执行窗口覆盖操作。

[界面适配结果与截图](../evidence/mobile/adaptation/README.md)

[测试结果与截图](../evidence/android/README.md) · [来源与依赖](../ATTRIBUTION.md)

## 优化构建与性能基线

Release 启用 R8 与资源缩减；benchmark 从 Release 继承优化设置，仅增加 profileable 和本机调试签名，保持 non-debuggable。CI 同时构建 Debug、Release 与 benchmark，保存混淆映射；Release APK 没有生产签名，benchmark APK 用于模拟器验证。

独立 benchmark 模块使用 Macrobenchmark 1.3.4，固定 Full 编译模式：冷启动 10 次、8000 字文本批量替换及保存 5 次、20 条评审列表滚动 5 次。CI 启动独立后端、写入固定模拟资料，并仅在隔离模拟器清除该应用的数据；不会调用模型。原始 JSON 与 Perfetto 分析文件随 CI 产物保存。

手动测量时准备隔离的服务与模拟器，在本目录执行：

```powershell
./gradlew.bat :benchmark:connectedBenchmarkAndroidTest "-Pandroid.testInstrumentationRunnerArguments.androidx.benchmark.suppressErrors=EMULATOR"
```

EMULATOR 是模拟器运行时唯一显式放宽的设备限制；没有放宽 debuggable 或 profileable 检查。计时结果用于同一环境的后续比较，不代表真机速度，也不据此判定生产性能达标。

[模拟器质量验证](../docs/mobile-quality.md)
