# 开发指南

## 环境

后端支持 Python 3.11–3.13，CI 使用 Python 3.12 和 uv 0.12.5。JavaScript 语法检查需要 Node.js，CI 使用 Node.js 22。移动端工具链分别见 [Android](../android/README.md) 和 [iOS](../ios/README.md)。

在项目根目录安装锁定依赖：

```sh
uv sync --frozen --python 3.12
```

## 目录

```text
app/         HTTP 服务、评审流程、存储与 MCP
static/      Web 界面
knowledge/   工程知识索引与来源信息
android/     Kotlin / Compose 客户端
ios/         SwiftUI 客户端
tests/       后端与协议测试
evals/       固定样本、评测工具与运行结果
scripts/     回放、诊断、构建与验证工具
docs/        使用和开发文档
evidence/    发布版本的测试报告与截图
```

## 配置与数据

| 配置 | 默认值 | 作用 |
|---|---|---|
| `AI_WORKSPACE_DATA` | `data` | 后端数据目录；相对路径以项目根目录为基准 |
| `AI_WORKSPACE_URL` | `http://127.0.0.1:8765` | MCP 适配器连接的本机服务地址 |

后端读取项目根目录的 `.env`，示例见 [`.env.example`](../.env.example)。为 MCP 适配器更改地址时，在宿主配置或启动环境中设置 `AI_WORKSPACE_URL`。HTTP 监听地址和端口通过 Uvicorn 参数配置；移动客户端当前固定使用 8765 端口。

数据库保存在数据目录中，不通过静态文件路由公开。备份前停止服务并复制完整数据目录。`.env`、运行数据、虚拟环境和构建输出均由 Git 忽略。

## 本地检查

```sh
uv run --no-sync pytest -q
uv run --no-sync ruff check app tests scripts evals
node --check static/ai-review-ui.js
npm ci --ignore-scripts --no-audit --no-fund
npm test
uv run --no-sync python -m evals.benchmark freeze
```

后端测试覆盖幂等、版本冲突、来源校验、状态恢复、提交限制和本机访问控制。MCP 协议测试会启动隔离的 Web 服务和 stdio 客户端，不使用日常数据库。

Web 回归使用真实的 AI 页面脚本和隔离 DOM，控制请求完成顺序及响应丢失，覆盖导航、版本单调接收、草稿恢复和原提交重试。浏览器依赖仅用于开发验证，不进入产品运行路径。Web 的输入与待确认请求保存在当前标签页的 sessionStorage；刷新可以恢复，关闭标签页不作为持久化保证。

CI 分别运行后端检查、Android 构建与模拟器测试、iOS 构建与模拟器测试。已发布版本的统计和运行链接见[测试报告](../evidence/README.md)。客户端协议测试使用固定数据，模型评测单独见 [evals](../evals/README.md)。

合并到 main 前须通过 Ubuntu、Windows、Android 和 iOS 四项检查。两端原生检查使用独立名称，所有 PR（包括仅改文档）都会运行，避免必需检查被路径过滤跳过后一直等待。push 仍按原生相关路径触发；iOS 手动 performance_only 运行不替代 PR 的完整功能检查。

## 新环境安装检查

以下命令验证已提交的 Git 快照，在临时目录创建新的 Python 环境，并执行安装和回归检查：

```sh
uv run python scripts/verify_release.py --work-dir work --out work/release-check.json
```

检查使用当前 `HEAD`，不包含未提交修改；下载缓存可复用。

## MCP 诊断

后端运行期间，可通过诊断客户端列出等待中的评审：

```sh
uv run python scripts/mcp_call.py list_pending_reviews
```

该工具执行协议调用，不生成模型输出。评审操作和工具用途见[使用指南](usage.md)。
