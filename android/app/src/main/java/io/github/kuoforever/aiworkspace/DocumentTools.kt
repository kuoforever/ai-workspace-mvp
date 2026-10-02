package io.github.kuoforever.aiworkspace

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

data class ImportedDocument(val name: String, val text: String)
data class SourceExcerpt(val before: String, val quote: String, val after: String, val firstLine: Int, val lastLine: Int)

fun String.scalarCount() = codePointCount(0, length)
fun String.takeScalars(limit: Int) = substring(0, offsetByCodePoints(0, minOf(limit, scalarCount())))

object DocumentImport {
    const val MAX_BYTES = 32768
    fun read(name: String, stream: InputStream): ImportedDocument {
        val extension = name.substringAfterLast('.', "").lowercase()
        require(extension in listOf("txt", "md", "markdown")) { "请选择 UTF-8 编码的 .txt 或 Markdown 文件。" }
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        while (true) {
            val size = stream.read(buffer, 0, minOf(buffer.size, MAX_BYTES + 1 - output.size()))
            if (size < 0) break
            output.write(buffer, 0, size)
            require(output.size() <= MAX_BYTES) { "文件过大，请选择不超过 8000 字符的材料。" }
        }
        val decoder = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        val decoded = try { decoder.decode(ByteBuffer.wrap(output.toByteArray())).toString() }
            catch (_: Exception) { throw IllegalArgumentException("文件不是有效的 UTF-8 文本，原草稿已保留。") }
        val text = decoded.removePrefix("\uFEFF")
        require('\u0000' !in text) { "文件包含非文本内容，原草稿已保留。" }
        require(text.codePointCount(0, text.length) in 10..8000) { "材料需要 10–8000 字符，原草稿已保留。" }
        return ImportedDocument(name, text)
    }
}

fun sourceExcerpt(text: String, quote: String): SourceExcerpt? {
    val start = text.indexOf(quote)
    if (start < 0 || quote.isEmpty()) return null
    val end = start + quote.length
    val firstLine = text.take(start).count { it == '\n' } + 1
    val lastLine = firstLine + quote.count { it == '\n' }
    var left = start
    repeat(3) { left = if (left > 0) text.lastIndexOf('\n', left - 1).let { if (it < 0) 0 else it } else 0 }
    if (left > 0) left++
    var right = end
    repeat(3) { right = text.indexOf('\n', right).let { if (it < 0) text.length else it + 1 } }
    return SourceExcerpt(text.substring(left, start), quote, text.substring(end, right), firstLine, lastLine)
}

fun ReviewSnapshot.summary() = ReviewSummary(id, input.title, status, input.mode)

/** Export the displayed snapshot, including offline sources, without contacting the server. */
fun ReviewSnapshot.markdown(): String = buildString {
    append("# ").append(input.title).append("\n\n")
    append("模式：").append(input.mode).append(" · 状态：").append(status).append("\n")
    append("评审：").append(id).append(" · 版本：").append(revision).append("\n\n")
    append("引用文本经服务校验；语义仍需人工判断。代码与实验未执行。\n")
    if (input.mode == "scripted") append("\n**离线模拟数据，未经模型评审。**\n")
    append("\n## 设计快照\n\n").append(input.design).append("\n")
    report?.let { report ->
        append("\n## 评审\n\n").append(report.summary).append("\n")
        report.findings.forEach { finding ->
            append("\n### ").append(finding.checkId).append(" · ").append(finding.verdict).append("\n\n")
            append(finding.explanation).append("\n\n").append(finding.recommendation).append("\n")
            finding.citations.forEach { citation ->
                sources[citation.sourceId]?.let { source ->
                    append("\n来源 ").append(citation.sourceId).append(" · ").append(source.path)
                        .append(" · SHA-256 ").append(source.sha256).append("\n\n")
                    citation.quote.lines().forEach { append("> ").append(it).append("\n") }
                }
            }
        }
    }
    if (questions.isNotEmpty()) {
        append("\n## 澄清记录\n")
        questions.forEach { append("\n").append(it.text).append("\n\n").append(answers[it.id] ?: "待回答").append("\n") }
    }
}
