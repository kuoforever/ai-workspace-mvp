# 移动端提交恢复 · MCP 实测

模式：mcp · 状态：completed
评审：5bc64c0a-d3fe-4289-a428-1fd63d295951 · 版本：4
输入 SHA-256：bd79a28cb21067ed0b5455836adb5316d420ad0bc1dd39bd34eea8f56091318a
知识版本：2026.09.27-2

代码/实验：not_run；引用语义支持：未人工评估。
宿主模型调用次数与 token 用量：未知。

## 设计快照

客户端在发送前将请求键和完整正文原子保存。服务端使用请求键与正文摘要去重；相同键与相同正文返回已保存结果，相同键与不同正文返回 409。断网、超时和 5xx 保留原请求，用户可点击重试原提交。收到有效响应后，客户端先保存本机结果，再清除提交日志。幂等记录的保留期、过期后的订单核对方法，以及重试次数和时间预算尚未写入设计。

## 评审

补充回答明确了幂等作用域、七天保存窗口和有界重试规则。两项检查在设计材料层面有依据；服务端原子提交、过期核对及重试预算的实现效果仍需单独验证。

### CON-01 · supported

同键同正文复用结果、不同正文拒绝，配合租户与订单意图作用域，可表达同一业务操作的重试。回答还要求七天后先查稳定订单标识，未知结果进入核对流程，避免直接换新键再次创建。材料未说明去重记录与订单写入如何原子提交，因此不能据此断言并发故障下已无重复订单。

将作用域和七天窗口写入接口契约，并明确订单写入与去重记录的事务边界；验证并发同键、窗口过期及响应丢失后的查询行为。

来源 CON-01 · 专题/04-幂等与可靠性/检查项.json · SHA-256 ac00a539840361285701661a4bd991b52609f097356f26d74b2479a2011fbd19

> 同一业务意图如何识别，重复请求怎样返回？

来源 input · input.txt · SHA-256 2986bee5c74f893e1970255215a74be888df775a9001697b211042b13fe75480

> 相同键与相同正文返回已保存结果，相同键与不同正文返回 409。

来源 answer:retention · answers/retention.txt · SHA-256 3bdf9b037e57c5084554ef36eccfbad6d9d60b14d032f1762398ec06d3751298

> Scope is tenant + order intent + operation. Keep receipts for seven days. After expiry, query the stable order ID; an unknown result requires reconciliation, never a fresh create key.

### FAIL-01 · supported

回答将允许重试的情况限定为传输失败、超时和 503，并给出同一原请求最多三次、累计三十秒的预算；次数和截止时间跨重启保存，达到任一上限后停止并转入核对。设计中的保留原请求不能被理解为允许无限重试。

明确三次是否包含首次发送，补充等待策略以及预算到期时仍未结束请求的处理；用跨重启测试验证计数与截止时间不被重置。

来源 FAIL-01 · 专题/04-幂等与可靠性/检查项.json · SHA-256 5002e0d4c290054e317e224ef50bcf8e1051d5b8242ce7aca6764384e03cd2c9

> 可重试错误是否分类，并限制重试次数与总预算？

来源 answer:retry_budget · answers/retry_budget.txt · SHA-256 3d3d4453136c74e3bed87602364472f6116b79a8b1ee1216c29a076f99e4d7d1

> Retry only transport failures, timeouts and 503; at most three attempts within 30 seconds per original command.

来源 answer:retry_budget · answers/retry_budget.txt · SHA-256 3d3d4453136c74e3bed87602364472f6116b79a8b1ee1216c29a076f99e4d7d1

> Persist attempts and deadline across restarts; stop and ask for reconciliation when either limit is reached.

## 澄清记录

幂等键如何绑定租户和订单意图、保存多久？过期后的重试如何查询已有订单？

Scope is tenant + order intent + operation. Keep receipts for seven days. After expiry, query the stable order ID; an unknown result requires reconciliation, never a fresh create key.

哪些错误允许重试？最大尝试次数、累计时间预算和达到上限后的处理方式是什么？

Retry only transport failures, timeouts and 503; at most three attempts within 30 seconds per original command. Persist attempts and deadline across restarts; stop and ask for reconciliation when either limit is reached.
