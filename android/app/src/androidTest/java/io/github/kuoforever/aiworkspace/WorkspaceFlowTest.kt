package io.github.kuoforever.aiworkspace

import android.content.ContentValues
import android.graphics.Bitmap
import android.os.Build
import android.provider.MediaStore
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.UUID
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class WorkspaceFlowTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val api = LocalWorkspaceApi()

    private fun waitText(text: String) {
        compose.waitUntil(30000) { compose.onAllNodesWithText(text, substring = true).fetchSemanticsNodes().isNotEmpty() }
    }

    private fun ready() {
        compose.waitUntil(30000) { compose.onAllNodesWithTag("busy").fetchSemanticsNodes().isEmpty() }
    }

    private fun scrollClick(list: String, tag: String) {
        compose.onNodeWithTag(list).performScrollToNode(hasTestTag(tag))
        compose.onNodeWithTag(tag).performClick()
    }

    private fun shot(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.waitForIdleSync()
        val bitmap = instrumentation.uiAutomation.takeScreenshot()
        // AGP removes the test application after a connected run. Keep evidence in
        // MediaStore so uninstalling the app does not erase the captured frames.
        check(Build.VERSION.SDK_INT >= 29)
        val resolver = instrumentation.targetContext.contentResolver
        val uri = requireNotNull(resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "$name.png")
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/ai-workspace-evidence")
        }))
        requireNotNull(resolver.openOutputStream(uri)).use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }

    @Test fun nativeCreateClarifyRestoreReadSourceAndExport() {
        ready()
        val title = "Android 模拟验收 ${UUID.randomUUID().toString().take(8)}"
        compose.onNodeWithText("新建设计评审").performClick()
        compose.onNodeWithText("填入演示示例").performClick()
        compose.onNodeWithTag("title").performTextReplacement(title)
        // Activity recreation must retain the editable draft.
        compose.activityRule.scenario.recreate()
        ready()
        compose.onNodeWithTag("title").assertTextContains(title)
        scrollClick("create-list", "submit")
        waitText("等待补充")
        shot("01-clarification")
        compose.onNodeWithTag("answer:q1").performTextInput("先查询支付状态，再对明确失败执行有限重试。")
        compose.activityRule.scenario.recreate()
        ready()
        compose.onNodeWithTag("answer:q1").assertTextContains("先查询支付状态", substring = true)
        scrollClick("detail-list", "answer-submit")
        waitText("已完成")
        shot("02-report")
        scrollClick("detail-list", "source:CON-01:0")
        waitText("引用依据")
        shot("03-source")
        compose.onNodeWithText("返回").performClick()
        scrollClick("detail-list", "export")
        waitText("导出预览")
        compose.onNodeWithText("分享报告").assertIsDisplayed()
        shot("04-export")
        runBlocking {
            val matches = wireJson.decodeFromString<List<ReviewSummary>>(api.request("/reviews")).filter { it.title == title }
            assertEquals(1, matches.size)
            val saved = wireJson.decodeFromString<ReviewSnapshot>(api.request("/reviews/${matches.single().id}"))
            assertEquals("completed", saved.status)
            assertEquals("先查询支付状态，再对明确失败执行有限重试。", saved.answers["q1"])
        }
    }

    @Test fun desktopCreatedMcpReviewCanBeContinuedOnAndroid() = runBlocking {
        ready()
        val key = UUID.randomUUID().toString()
        val created = wireJson.decodeFromString<ReviewSnapshot>(api.request("/reviews", wireJson.encodeToString(ReviewInput(
            title = "跨端协议验收 $key", design = "订单请求使用请求键去重，错误恢复细节尚未确定。",
            mode = "mcp", checkIds = listOf("CON-01"), recordId = "desktop-fixture",
        )), "$key-create"))
        val context = wireJson.parseToJsonElement(api.request("/reviews/${created.id}/context")).jsonObject
        val questions = buildJsonObject {
            put("revision", created.revision)
            put("input_sha256", context.getValue("input_sha256"))
            putJsonObject("output") {
                put("kind", "questions"); put("summary", "协议夹具，不是模型评审")
                putJsonArray("findings") { }
                putJsonArray("questions") { addJsonObject { put("id", "cross-device"); put("check_id", "CON-01"); put("text", "幂等键保留多久？") } }
            }
        }
        api.request("/reviews/${created.id}/model-output", questions.toString(), "$key-question")
        compose.onNodeWithText("刷新").performClick()
        waitText("跨端协议验收 $key")
        compose.onNodeWithText("跨端协议验收 $key").performClick()
        waitText("幂等键保留多久？")
        compose.onNodeWithTag("answer:cross-device").performTextInput("保留七天，超过有效期需重新核对业务意图。")
        scrollClick("detail-list", "answer-submit")
        waitText("等待助手")
        val latest = wireJson.decodeFromString<ReviewSnapshot>(api.request("/reviews/${created.id}"))
        assertEquals("保留七天，超过有效期需重新核对业务意图。", latest.answers["cross-device"])
        val latestContext = wireJson.parseToJsonElement(api.request("/reviews/${created.id}/context")).jsonObject
        val output = buildJsonObject {
            put("revision", latest.revision)
            put("input_sha256", latestContext.getValue("input_sha256"))
            putJsonObject("output") {
                put("kind", "report"); put("summary", "跨端协议夹具已完成；本测试未调用模型。")
                putJsonArray("questions") { }
                putJsonArray("findings") { addJsonObject {
                    put("check_id", "CON-01"); put("verdict", "unknown")
                    put("explanation", "测试仅验证跨端状态接续。")
                    put("recommendation", "真实设计仍需独立评审。")
                    putJsonArray("citations") { addJsonObject {
                        put("source_id", "CON-01"); put("quote", latest.sources.getValue("CON-01").text.lineSequence().first())
                    } }
                } }
            }
        }
        api.request("/reviews/${created.id}/model-output", output.toString(), "$key-report")
        waitText("跨端协议夹具已完成")
        shot("05-cross-device")
    }
}
