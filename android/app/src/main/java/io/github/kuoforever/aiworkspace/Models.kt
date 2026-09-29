package io.github.kuoforever.aiworkspace

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

val wireJson = Json { ignoreUnknownKeys = true; encodeDefaults = true }

@Serializable data class CheckCard(val id: String, val question: String)
@Serializable data class Catalog(val checks: List<CheckCard>)
@Serializable data class ServerConfig(val modes: List<String>)
enum class Connection(val label: String) {
    UNKNOWN("尚未检查连接"), CHECKING("正在检查连接"), CONNECTED("工作台已连接"),
    OFFLINE("工作台未连接"), UNAVAILABLE("工作台暂不可用"),
}

fun assistantPrompt(id: String) = "请通过 swe-workspace 读取评审 $id 的最新上下文，按选定检查项继续评审。需要澄清时提交问题；材料充分时提交带原文引用的报告。"
@Serializable data class ReviewSummary(
    val id: String, val title: String, val status: String, val mode: String,
)
@Serializable data class ReviewInput(
    val title: String = "",
    val design: String = "",
    val mode: String = "mcp",
    @SerialName("check_ids") val checkIds: List<String> = listOf("CON-01", "FAIL-01"),
    @SerialName("workbench_record_id") val recordId: String = "android",
)
@Serializable data class Source(val title: String, val text: String, val path: String, val sha256: String)
@Serializable data class Citation(@SerialName("source_id") val sourceId: String, val quote: String)
@Serializable data class Finding(
    @SerialName("check_id") val checkId: String,
    val verdict: String, val explanation: String, val recommendation: String,
    val citations: List<Citation>,
)
@Serializable data class Report(val summary: String, val findings: List<Finding>)
@Serializable data class Question(val id: String, val text: String)
@Serializable data class ReviewSnapshot(
    val id: String, val revision: Int, val status: String, val input: ReviewInput,
    val sources: Map<String, Source>,
    val questions: List<Question> = emptyList(),
    val answers: Map<String, String> = emptyMap(),
    val report: Report? = null, val error: String? = null,
)
@Serializable data class AnswerCommand(val revision: Int, val answers: Map<String, String>)
@Serializable data class PendingCommand(
    val key: String, val path: String, val body: String, val kind: String, val reviewId: String? = null,
)

fun statusLabel(status: String) = when (status) {
    "waiting_model" -> "等待助手"
    "waiting_input" -> "等待补充"
    "completed" -> "已完成"
    "running" -> "正在处理"
    "failed" -> "失败"
    "interrupted" -> "已中断"
    else -> status
}

fun verdictLabel(verdict: String) = when (verdict) {
    "supported" -> "有材料支持"
    "risk" -> "存在风险"
    "unknown" -> "信息不足"
    "not_applicable" -> "不适用"
    else -> verdict
}
