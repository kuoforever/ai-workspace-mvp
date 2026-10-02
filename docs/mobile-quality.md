# 移动端模拟器质量验证

本轮在既有原生导入、离线阅读和后台保存基础上，补充在途请求取消、完整并发检查、优化构建及可重复的性能基线。真机与生产签名不属于本轮验证范围。

## 行为边界

- Android 在离开前台时取消自动刷新及其网络调用；手动提交继续遵循提交日志规则。
- 两端拒绝被取消操作的迟到响应，未确认提交保留原幂等键与正文，重试取得结果后再清除。
- iOS 使用 complete 并发检查；应用目标将 Swift 警告视为错误，存储访问通过串行队列。
- Android 的 benchmark 应用继承 Release 的 R8 与资源缩减，使用调试签名，保持 non-debuggable 并允许性能分析。
- iOS 性能阶段单独构建 Release，关闭代码覆盖率，保留 x86_64 与 arm64 模拟器架构；仅测试构建启用内部符号读取，Swift 优化仍为 Release 配置。
- Android 长材料与回答使用有高度上限的原生滚动编辑框，避免 8000 字粘贴撑成超长页面；测量含保存确认时的表单回滚。
- Android 保留 OkHttp 的连接故障恢复，复用原正文和幂等键；HTTP 拒绝与重定向仍按错误处理，未确认请求保留设备日志。

## 固定测量

| 平台 | 场景 | 重复次数 | 指标与范围 |
|---|---|---|---|
| Android | 冷启动 | 10 | StartupTimingMetric，包含首帧与应用报告就绪的时间 |
| Android | 8000 字文本批量替换与后台保存 | 5 | 每轮三次完整文本替换，FrameTimingMetric；不等同逐键输入延迟 |
| Android | 20 条评审列表滚动 | 5 | FrameTimingMetric，固定往返滚动动作 |
| iOS | 应用启动 | 10 | XCTApplicationLaunchMetric，等待应用响应 |
| iOS | 8000 字文档导入、引用定位、Markdown 导出 | 10 | 原生管线耗时与内存；不包含系统选择器和页面操作 |
| iOS | 20 份完整报告缓存重载 | 10 | 文件读取与解码耗时、内存 |

CI 性能阶段使用独立数据目录的后端和固定程序生成资料，不调用模型。Android 的应用数据清理入口只接受 GitHub CI 的隔离模拟器。手动运行 benchmark 时，应使用独立测试服务并保存实际数据量。

## 记录与复现

在 GitHub Actions 手动运行 Android 或 iOS 工作流，可复现功能检查与性能测量。下载对应产物后查看：

- Android：android-evidence/performance/summary.json、fixture.json、benchmark 模块原始 JSON 与 Perfetto 文件。
- iOS：ios-evidence/performance/summary.json、fixture.json、原始 metrics.json、tests.log、Performance.xcresult 与构建设置。
- 结果解析：scripts/mobile-performance-summary.py；固定资料：scripts/mobile-performance-fixture.py。

解析工具要求全部场景均有有效测量样本，保留原始值，并按线性插值计算 P50/P95。Android 帧时长的统计样本是采集到的帧；启动和 iOS 管线的样本是重复执行次数。两者不能混作相同样本单位。

Android 的 frameOverrunMs 是相对帧截止时间的差值，负数表示提前完成，并非无效耗时；普通时长仍禁止负值。

模拟器运行共享宿主资源，结果受 CI 机器负载与图形环境影响。本轮数据作为后续同环境比较的起点，不作为真机性能、耗电、温控或生产稳定性的结论。首次记录也不代表已经证明优化收益；需要同环境的前后对照。
