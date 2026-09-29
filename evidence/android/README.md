# Android 测试报告

| 项目 | 记录 |
|---|---|
| 日期 | 2026-09-29 |
| 环境 | Android 15 / API 35，x86_64，Pixel 6 模拟器配置 |
| 源码 | `538aa3ca25b791eeda16bdbbff5c46e71b488d66` |
| 结果 | 构建、Lint、5 项单元测试和 2 条界面流程通过 |
| CI | [36549563579](https://github.com/kuoforever/ai-workspace-mvp/actions/runs/36549563579) |

## 覆盖范围

- 原生创建、澄清回答、Activity 重建后的输入恢复、报告、来源和 Markdown 导出。
- 电脑端 HTTP 夹具创建评审与提交问题，手机回答后显示最终报告。
- 单元测试覆盖响应丢失、原请求重试、写入失败、版本冲突与损坏响应。

界面测试连接隔离的 FastAPI 服务，使用模拟数据和协议夹具。测试环境为模拟器，未覆盖实体设备或远程认证。

## 文件

[验证摘要](verification.json) · [设备测试 XML](device-tests.xml) · [单元测试统计](unit-tests.json) · [Lint 输出](lint-results.txt) · [APK 与录屏](https://github.com/kuoforever/ai-workspace-mvp/releases/tag/android-v0.2.0)

完整构建报告保存在对应 CI artifact 中；安装方法见 [Android README](../../android/README.md)。录屏包含测试启动等待，无讲解音轨。

## 截图

| 澄清回答 | 完成报告 |
|---|---|
| ![澄清](01-clarification.png) | ![报告](02-report.png) |

| 来源快照 | 导出预览 |
|---|---|
| ![来源](03-source.png) | ![导出](04-export.png) |

![跨端接续](05-cross-device.png)
