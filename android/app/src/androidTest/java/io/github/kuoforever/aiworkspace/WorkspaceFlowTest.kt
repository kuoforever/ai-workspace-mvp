package io.github.kuoforever.aiworkspace

import android.content.ContentValues
import android.graphics.Bitmap
import android.os.Build
import android.provider.MediaStore
import androidx.compose.ui.graphics.asAndroidBitmap
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

    private fun ready(tag: String = "new-review") = compose.waitForEnabled(hasTestTag(tag))

    private fun scrollClick(list: String, tag: String) {
        compose.onNodeWithTag(list).performScrollToNode(hasTestTag(tag))
        ready(tag)
        compose.onNodeWithTag(tag).performClick()
    }

    private fun shot(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        // Capture the rendered Compose frame after its semantics assertion, rather
        // than a possibly older system compositor frame.
        compose.waitForIdle()
        val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
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
        ready("fill-example")
        compose.onNodeWithText("填入演示示例").performClick()
        compose.onNodeWithTag("title").performTextReplacement(title)
        // Activity recreation must retain the editable draft.
        compose.activityRule.scenario.recreate()
        ready("title")
        compose.onNodeWithTag("title").assertTextContains(title)
        scrollClick("create-list", "submit")
        waitText("等待补充")
        ready("answer:q1")
        shot("01-clarification")
        compose.onNodeWithTag("answer:q1").performTextInput("先查询支付状态，再对明确失败执行有限重试。")
        compose.activityRule.scenario.recreate()
        ready("answer:q1")
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

    @Test fun recordedModelReviewCanBeContinuedOnAndroid() = runBlocking<Unit> {
        ready()
        compose.onNodeWithTag("check-connection").performClick()
        ready()
        compose.onNodeWithTag("connection-status").assertTextEquals("工作台已连接")
        val fixture = wireJson.parseToJsonElement(InstrumentationRegistry.getInstrumentation()
            .context.assets.open("mobile-review.json").bufferedReader().use { it.readText() }).jsonObject
        val key = UUID.randomUUID().toString()
        val title = "模型报告回放 ${key.take(8)}"
        val created = wireJson.decodeFromString<ReviewSnapshot>(api.request("/reviews", wireJson.encodeToString(ReviewInput(
            title = title, design = fixture.getValue("design").jsonPrimitive.content,
            mode = "mcp", checkIds = fixture.getValue("check_ids").jsonArray.map { it.jsonPrimitive.content },
            recordId = "recorded-model-fixture",
        )), "$key-create"))
        suspend fun submitRecorded(name: String) {
            val context = wireJson.parseToJsonElement(api.request("/reviews/${created.id}/context")).jsonObject
            api.request("/reviews/${created.id}/model-output", buildJsonObject {
                put("revision", context.getValue("revision"))
                put("input_sha256", context.getValue("input_sha256"))
                put("output", fixture.getValue(name))
            }.toString(), "$key-$name")
        }
        submitRecorded("questions")
        compose.onNodeWithText("刷新").performClick()
        waitText(title)
        compose.waitForEnabled(hasText(title))
        compose.onNodeWithText(title).performClick()
        waitText("等待补充")
        val answers = fixture.getValue("answers").jsonObject
        for ((id, answer) in answers) {
            compose.onNodeWithTag("detail-list").performScrollToNode(hasTestTag("answer:$id"))
            ready("answer:$id")
            compose.onNodeWithTag("answer:$id").performTextReplacement(answer.jsonPrimitive.content)
        }
        scrollClick("detail-list", "answer-submit")
        waitText("等待助手")
        scrollClick("detail-list", "copy-assistant-prompt")
        compose.onNodeWithTag("copy-assistant-prompt").assertTextContains("指令已复制")
        val latest = wireJson.decodeFromString<ReviewSnapshot>(api.request("/reviews/${created.id}"))
        assertEquals(answers.mapValues { it.value.jsonPrimitive.content }, latest.answers)
        submitRecorded("report")
        waitText(fixture.getValue("report").jsonObject.getValue("summary").jsonPrimitive.content)
        compose.onNodeWithTag("status").assertTextEquals("已完成")
        shot("05-cross-device")
        scrollClick("detail-list", "export")
        waitText("导出预览")
        compose.onNodeWithText("分享报告").assertIsDisplayed()
    }
}
