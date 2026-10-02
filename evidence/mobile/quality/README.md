# 模拟器质量与性能基线

验证源码为 `632f03fa2cb23b9ed089bd17213fedd76a9b8c58`。本轮补齐在途请求取消、迟到成功和错误的丢弃、原请求重试保护、iOS 完整并发检查，以及优化构建后的固定性能测量。Android 的长材料和回答使用可在框内滚动的编辑器。

## 回归结果

| 范围 | 通过的检查 | 记录 |
|---|---|---|
| 后端 | Windows / Ubuntu 各 30 项测试，Ruff、Web 语法及冻结评测协议检查 | [CI](https://github.com/kuoforever/ai-workspace-mvp/actions/runs/36969617844) |
| Android | 31 项单元测试、5 项设备测试、6 项进程恢复检查；Debug、R8 Release/benchmark 构建与两种构建的 Lint | [CI](https://github.com/kuoforever/ai-workspace-mvp/actions/runs/36969617826) |
| iOS | 24 项单元测试、5 条界面流程，iPhone SE 与 iPad 各 1 项大字体/深色模式检查；应用完整并发检查及警告视为错误 | [CI](https://github.com/kuoforever/ai-workspace-mvp/actions/runs/36969617831) |
| 性能 | Android、iOS 各 3 个场景全部通过，未跳过测试 | [Android 摘要](android-performance-tests.xml) · [iOS 摘要](ios-performance-tests.json) |

取消不能证明后端没有接受请求。客户端保留原幂等键和正文，核对并保存结果后才清除设备日志；连接检查不会重新发送请求。测试还覆盖连接中断后的原正文重发，以及取消后迟到的版本冲突不会清除回执。

## 固定基线

两端使用独立后端、20 条固定程序生成的评审和全新 CI 应用数据，不调用模型。Android 为 API 35、x86_64、软件图形渲染，采用 R8 优化、non-debuggable/profileable 和 Full 编译模式。iOS 为 iPhone 16 / iOS 18.5，Release `-O`、测试可访问内部符号，覆盖率关闭；应用包包含 arm64/x86_64。

| 平台与指标 | 样本 | P50 | P95 |
|---|---|---|---|
| Android 冷启动首帧 | 10 次 | 1045.36 ms | 1161.20 ms |
| Android 冷启动应用报告就绪 | 10 次 | 1451.47 ms | 1574.22 ms |
| Android 8000 字批量替换、保存确认的 frameDurationCpuMs | 5 轮，26 帧 | 30.37 ms | 83.69 ms |
| Android 20 条列表滚动的 frameDurationCpuMs | 5 轮，563 帧 | 69.68 ms | 90.14 ms |
| iOS 启动至可响应 | 10 次 | 1854.72 ms | 2708.34 ms |
| iOS 8000 字导入、引用定位、Markdown 导出管线 | 10 次 | 1.07 ms | 1.83 ms |
| iOS 20 份完整报告缓存重载 | 10 次 | 5.73 ms | 7.12 ms |

Android 帧样本与重复次数不同；长文本每轮进行三次完整替换，包含保存确认所需的页面回滚，不代表逐键输入延迟。iOS 管线不包括系统选择器、键盘和页面操作；缓存重复读取受到文件系统缓存影响。两平台的启动定义也不同，不能据此排名。

Android 滚动的 frameOverrunMs P50/P95 为 80.12/109.16 ms；8000 字替换为 22.60/82.59 ms。当前软件渲染模拟器有明显超时帧，这组结果不代表性能已经达标。该指标的负数表示提前于帧截止时间完成，解析器保留其符号。

iOS 原始记录同时保留物理内存峰值和变化量。这些值属于 XCTest 测试宿主，不能解释为文档单独占用的内存，也不能从零净增量推断没有分配。

原始样本与指标见 [Android](android-performance-summary.json)、[iOS](ios-performance-summary.json)、[Android 原生 JSON](android-native-metrics.json)及 [iOS 原生指标](ios-native-metrics.json)。数据与包摘要见 [verification.json](verification.json)。

## 轨迹定位

检查全部 5 轮滚动和 5 轮长文本替换的 Perfetto 轨迹，保存查询、每条轨迹的 SHA-256 和统计，见 [轨迹摘要](android-trace-summary.json)。

滚动各轮中，主线程 `postAndWait` 的累计墙钟时间约为其父级 `traversal` 的 97.6%–98.8%；布局切片的平均时间为 0.63–1.23 ms。渲染线程同时出现较长的交换缓冲及模拟器同步等待。这支持先调查渲染与模拟器同步的推断，而不足以把全部卡顿归因于 Compose 重组或业务计算。

长文本替换的布局切片平均为 8.44–10.28 ms，最长达到 25.33 ms，仍有可定位的布局工作。后续应在同一台支持图形加速的模拟器上进行可复现的优化对照，并保持原文字与保存确认检查。

这些是整条迭代轨迹中的嵌套墙钟切片，统计窗口与 FrameTimingMetric 的选帧窗口不同；切片时间重叠，不能相加或当作 CPU 利用率。复现方法按 [Perfetto Python API](https://perfetto.dev/docs/analysis/trace-processor-python)执行：

```sh
uv run --with perfetto==0.58.2 python scripts/mobile-trace-summary.py \
  --input <解压后的Android产物目录> --out work/trace-summary.json
```

## 面向 3–5 年原生岗位仍需补的证据

这轮能证明状态恢复、取消和重试边界、后台存储、平台适配、优化构建及性能定位。项目还应继续补：

1. **数据演进**：当前兼容旧单报告缓存；继续建立显式格式版本、多版本迁移、迁移中断与部分文件损坏的恢复案例。
2. **无障碍**：已有大字体、横屏和深色检查；还需 TalkBack/VoiceOver 焦点顺序、控件语义、触达尺寸和平台无障碍审计。
3. **可维护结构**：创建、详情、来源等页面仍集中在主要视图文件，进一步划定页面与业务操作边界，并保留可注入的存储和网络实现。
4. **优化对照**：保留本轮基线，以相同资料、编译模式和环境完成一次前后比较，再依据轨迹解释收益；当前尚未证明优化收益。
5. **AI 应用评测**：已有报告回放及同会话预实验；仍需独立 direct/MCP 盲测、人工语义评分与端到端耗时记录，不能把引用格式通过当成回答质量通过。

真机系统差异、耗电与温控、稳定签名与分发、真实用户的崩溃/ANR 数据留待后续设备与发布阶段。模拟器结果不能单独判定个人已经达到某个年限的能力水平。

复现入口、取消约定及测量范围见 [移动端质量文档](../../../docs/mobile-quality.md)。完整原始 `.xcresult`、Perfetto 轨迹、混淆映射与录像保存在上述 CI 产物中；仓库保存摘要和原始指标。
