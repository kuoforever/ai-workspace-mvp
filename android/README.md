# Android 原生评审客户端

Kotlin + Jetpack Compose + ViewModel，复用现有 FastAPI HTTP 契约。Gradle Wrapper、AGP 8.10.1 / Kotlin 2.1.20 构建起点来自个人 SWE `android-work` 实验；页面、HTTP 适配、草稿、提交日志和跨端测试为本项目新增。

## 本机连接

1. 在电脑运行仓库根目录的 `start.ps1`。
2. 用 Android Studio 打开此目录，选择 JDK 17，安装 Android SDK Platform 36 与 Build Tools 35.0.0；或使用 GitHub Actions 输出的 Debug APK。
3. USB 连接已开启调试的设备，或启动 Android 模拟器，然后运行 `adb reverse tcp:8765 tcp:8765`。
4. 安装 `app/build/outputs/apk/debug/app-debug.apk`，打开 AI Workspace。

Android 固定连接 `127.0.0.1:8765`，ADB 将端口转发到电脑；服务仍绑定电脑 loopback。这里只验证开发环境连接，没有实现互联网账号、远程认证或生产发布。设备断开、模拟器重启后应重新建立转发。多个设备时对 `adb` 加 `-s <设备序列号>`。

## 原生流程

- 任务列表从共享后端读取，电脑提交的任务也可在手机继续。
- 原生表单创建评审，按关键词选择 1–8 项检查，支持 MCP 与明确标记的离线模拟模式。
- 回答澄清、查看逐项结论和来源快照、预览 Markdown 并调起系统分享。
- ViewModel 保持页面状态；草稿和最近列表／报告存在设备应用目录中。缓存明确标记，提交需要连接服务。
- 每次写操作先用 AtomicFile 保存请求正文和幂等键；网络结果未知时锁定输入，由用户重试同一请求。重新打开应用不会自动发送。
- 明确的 HTTP 4xx 拒绝结束该次待确认请求；草稿仍保留。409 提示刷新核对，不用旧版本覆盖新状态。
- 仅在前台的等待详情页轮询状态；出现连接错误后停止自动轮询，用户可手动刷新。

MCP 推理仍由电脑宿主提供。Android 不存模型密钥，也不直接提交模型结论。模拟流程与测试夹具不作为真实模型质量证据。

## 构建与验证

```powershell
./gradlew.bat :app:assembleDebug :app:testDebugUnitTest :app:lintDebug
adb reverse tcp:8765 tcp:8765
./gradlew.bat :app:connectedDebugAndroidTest
```

Windows 构建工具可能受中文路径影响；必要时将仓库 clone 到 `C:/dev/ai-workspace-mvp`。SDK 路径放在忽略入库的 `local.properties` 或 `ANDROID_HOME`，不要改共享构建文件。

CI 在隔离 FastAPI 数据库和 Android API 35 模拟器中验收：创建 → 澄清 → Activity 重建 → 完成 → 来源 → 导出，以及电脑端创建／提交、手机回答、电脑再提交报告的同任务接续。测试过程中会记录屏幕并保存截图；录屏内容是模拟／协议夹具，不是实时模型评审。结果以实际 GitHub Actions 记录为准。

单元测试覆盖丢失响应后的持久重试、禁止替换未确认正文、保存失败不发送、409 / 503 的区别和损坏响应。原生状态层与 Web 后端测试分别统计。

参考：[Compose BOM](https://developer.android.com/develop/ui/compose/bom)、[Compose UI testing](https://developer.android.com/develop/ui/compose/testing)、[ADB reverse](https://developer.android.com/develop/ui/views/layout/webapps/access-local-server)。Compose 依赖固定为 2025.04.01 BOM，与复用的构建起点一起验证，不在本轮顺带升级工具链。
