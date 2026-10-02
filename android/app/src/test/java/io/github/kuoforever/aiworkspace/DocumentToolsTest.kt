package io.github.kuoforever.aiworkspace

import java.io.ByteArrayInputStream
import org.junit.Assert.*
import org.junit.Test

class DocumentToolsTest {
    @Test fun importsUtf8BomAndPreservesMarkdownAndLineEndings() {
        val text = "# 订单设计\r\n\r\n失败后先查询状态，不重复创建订单。😀"
        val imported = DocumentImport.read("orders.MD", ByteArrayInputStream(("\uFEFF" + text).toByteArray()))
        assertEquals(text, imported.text)
        assertEquals("orders.MD", imported.name)
    }
    @Test fun rejectsInvalidEncodingBinaryEmptyAndOversizedFiles() {
        val bad = listOf(byteArrayOf(0xC3.toByte(), 0x28), "short".toByteArray(),
            ("a".repeat(12) + "\u0000").toByteArray(), "a".repeat(8001).toByteArray(),
            "a".repeat(DocumentImport.MAX_BYTES + 1).toByteArray())
        bad.forEach { bytes ->
            assertThrows(IllegalArgumentException::class.java) { DocumentImport.read("design.txt", ByteArrayInputStream(bytes)) }
        }
        assertThrows(IllegalArgumentException::class.java) { DocumentImport.read("design.pdf", ByteArrayInputStream("long enough text".toByteArray())) }
    }
    @Test fun scalarLimitAcceptsEightThousandSupplementaryCharacters() {
        val text = "😀".repeat(8000)
        assertEquals(text, DocumentImport.read("emoji.md", ByteArrayInputStream(text.toByteArray())).text)
    }
    @Test fun locatesMultilineQuoteWithUnicodeAndCrLf() {
        val text = "标题😀\r\n前文\r\n支付超时\r\n先查询状态\r\n后文\r\n结束"
        val quote = "支付超时\r\n先查询状态"
        val excerpt = requireNotNull(sourceExcerpt(text, quote))
        assertEquals(3, excerpt.firstLine)
        assertEquals(4, excerpt.lastLine)
        assertTrue(excerpt.before.contains("前文"))
        assertTrue(excerpt.after.contains("后文"))
        assertEquals(quote, excerpt.quote)
        assertNull(sourceExcerpt(text, "不存在的片段"))
    }
    @Test fun offlineExportPreservesReportQuotesAndSourceIdentity() {
        val quote = "先查询状态"
        val review = ReviewSnapshot("saved", 3, "completed", ReviewInput(title = "订单", design = quote),
            mapOf("input" to Source("设计", quote, "input.txt", "digest")), report = Report("报告结论",
                listOf(Finding("CON-01", "risk", "解释", "建议", listOf(Citation("input", quote))))))
        val text = review.markdown()
        assertTrue(text.contains("报告结论") && text.contains("> " + quote) && text.contains("SHA-256 digest"))
    }
}
