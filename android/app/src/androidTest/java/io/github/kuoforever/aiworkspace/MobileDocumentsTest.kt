package io.github.kuoforever.aiworkspace

import android.content.ContentValues
import android.os.Build
import android.provider.MediaStore
import android.view.accessibility.AccessibilityNodeInfo
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MobileDocumentsTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    @Test fun systemPickerImportsMarkdownAndRestoresSavedDraft() {
        check(Build.VERSION.SDK_INT >= 29)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val resolver = instrumentation.targetContext.contentResolver
        val name = "workspace-import-" + UUID.randomUUID().toString().take(8) + ".md"
        val text = "# 订单设计\n\n支付超时后先查询状态，再决定是否重试。"
        val uri = requireNotNull(resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, "text/plain")
            put(MediaStore.Downloads.RELATIVE_PATH, "Download")
        }))
        try {
            requireNotNull(resolver.openOutputStream(uri)).use { it.write(text.toByteArray()) }
            compose.waitForEnabled(hasTestTag("new-review"))
            compose.onNodeWithTag("home-list").performScrollToNode(hasTestTag("new-review"))
            compose.onNodeWithTag("new-review").performClick()
            compose.onNodeWithTag("create-list").performScrollToNode(hasTestTag("design"))
            compose.waitForEnabled(hasTestTag("design"))
            compose.onNodeWithTag("design").performTextReplacement("")
            compose.onNodeWithTag("create-list").performScrollToNode(hasTestTag("import-document"))
            compose.onNodeWithTag("import-document").performClick()
            val deadline = System.currentTimeMillis() + 20000
            var selected = false
            while (System.currentTimeMillis() < deadline && !selected) {
                val matches = instrumentation.uiAutomation.rootInActiveWindow?.findAccessibilityNodeInfosByText(name).orEmpty()
                for (match in matches) {
                    var current: AccessibilityNodeInfo? = match
                    while (current != null && !selected) {
                        selected = current.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                        current = current.parent
                    }
                }
                if (!selected) Thread.sleep(250)
            }
            assertTrue("System document picker must select the actual Downloads document", selected)
            compose.onNodeWithTag("create-list").performScrollToNode(hasTestTag("design"))
            compose.waitUntil(15000) {
                compose.onAllNodesWithTag("design").fetchSemanticsNodes().any {
                    it.config[androidx.compose.ui.semantics.SemanticsProperties.EditableText].text == text
                }
            }
            compose.onNodeWithTag("design").assertTextContains(text)
            compose.onNodeWithTag("create-list").performScrollToNode(hasTestTag("save-state"))
            compose.waitUntil(15000) { compose.onNodeWithTag("save-state").fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.Text].any { it.text == SaveState.SAVED.label } }
            compose.activityRule.scenario.recreate()
            compose.waitForIdle()
            compose.onNodeWithTag("design").assertTextContains(text)
        } finally { resolver.delete(uri, null, null) }
    }

    @Test fun deviceCacheMigratesAndRetainsTwentyReportsAcrossStoreInstances() = runBlocking<Unit> {
        // Instrumentation code runs under the target UID, so use that app's writable storage.
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        context.getSharedPreferences("workspace-drafts", 0).edit().clear().commit()
        val store = DeviceStore(context)
        fun snapshot(id: String) = ReviewSnapshot(id, 1, "completed", ReviewInput(title = id), emptyMap())
        context.getSharedPreferences("workspace-drafts", 0).edit()
            .putString("review", wireJson.encodeToString(ReviewSnapshot.serializer(), snapshot("legacy"))).commit()
        val disk = DiskExecutor()
        disk.run { store.saveReview(snapshot("second")) }
        assertEquals(setOf("legacy", "second"), disk.run { DeviceStore(context).cachedReviews().map { it.id }.toSet() })
        repeat(23) { index -> disk.run { store.saveReview(snapshot(index.toString())) } }
        val cached = disk.run { DeviceStore(context).cachedReviews() }
        assertEquals(20, cached.size)
        assertEquals("22", cached.first().id)
        assertNull(disk.run { DeviceStore(context).cachedReview("legacy") })
    }
}
