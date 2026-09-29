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

ViewModel 管理页面状态，AtomicFile 保存草稿、最近记录和待确认请求。连接中断后可以用原幂等键重试；版本冲突时保留输入并提示刷新。仅在前台等待助手时自动刷新。

详细的数据与重试规则见[架构设计](../docs/architecture.md#移动端恢复)。

## 测试

在本目录执行：

```powershell
./gradlew.bat :app:testDebugUnitTest :app:lintDebug
adb reverse tcp:8765 tcp:8765
./gradlew.bat :app:connectedDebugAndroidTest
```

设备测试需要后端服务和已连接的模拟器。CI 使用隔离数据库，在 Android 15 / API 35 模拟器测试创建、澄清、Activity 重建、报告、引用与跨端接续，并保存截图和录屏。

[测试结果与截图](../evidence/android/README.md) · [来源与依赖](../ATTRIBUTION.md)
