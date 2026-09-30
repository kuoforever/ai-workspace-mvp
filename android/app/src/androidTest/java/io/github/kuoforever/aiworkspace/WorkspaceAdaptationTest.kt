package io.github.kuoforever.aiworkspace

import android.content.ContentValues
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import android.os.Build
import android.provider.MediaStore
import android.view.inputmethod.InputMethodManager
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class WorkspaceAdaptationTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()

    private fun shell(command: String): String = instrumentation.uiAutomation.executeShellCommand(command)
        .let { android.os.ParcelFileDescriptor.AutoCloseInputStream(it).bufferedReader().use { reader -> reader.readText().trim() } }

    private fun waitReady() {
        compose.waitUntil(30000) { compose.onAllNodesWithTag("busy").fetchSemanticsNodes().isEmpty() }
    }

    private fun show(tag: String) {
        compose.onNodeWithTag("create-list").performScrollToNode(hasTestTag(tag))
        compose.onNodeWithTag(tag).assertIsDisplayed()
    }

    private fun shot(name: String) {
        compose.waitForIdle()
        val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
        val resolver = instrumentation.targetContext.contentResolver
        val uri = requireNotNull(resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "$name.png")
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/ai-workspace-evidence")
        }))
        requireNotNull(resolver.openOutputStream(uri)).use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }

    @Test fun darkLargeTextKeepsDraftAndActionsReachableAcrossWindowSizes() {
        // These system settings belong to the isolated CI emulator. Restore each
        // override so later recovery tests exercise the original device profile.
        assumeTrue("Window overrides require an isolated emulator", Build.HARDWARE in listOf("ranchu", "goldfish"))
        val oldFont = shell("settings get system font_scale").takeUnless { it == "null" } ?: "1.0"
        val oldSize = Regex("Override size: (\\d+x\\d+)").find(shell("wm size"))?.groupValues?.get(1) ?: "reset"
        val oldDensity = Regex("Override density: (\\d+)").find(shell("wm density"))?.groupValues?.get(1) ?: "reset"
        val wasDark = (compose.activity.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        val oldNight = Regex("Night mode: (yes|no|auto)").find(shell("cmd uimode night"))?.groupValues?.get(1)
            ?: if (wasDark) "yes" else "no"
        try {
            shell("wm size 720x1280")
            shell("wm density 320")
            shell("settings put system font_scale 2.0")
            shell("cmd uimode night yes")
            compose.activity.runOnUiThread { compose.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT }
            compose.waitUntil(15000) {
                val config = compose.activity.resources.configuration
                config.fontScale >= 1.9f && config.screenWidthDp <= 360 &&
                    (config.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
            }
            waitReady()
            compose.onNodeWithTag("home-list").performScrollToNode(hasTestTag("new-review"))
            compose.onNodeWithTag("new-review").performClick()
            val title = "Layout ${UUID.randomUUID().toString().take(8)}"
            val design = "Order API queries payment status before retrying a failed request."
            show("title")
            compose.onNodeWithTag("title").performTextReplacement(title)
            show("design")
            compose.onNodeWithTag("design").performClick().performTextReplacement(design)
            shot("06-compact-dark-keyboard")
            compose.activity.runOnUiThread {
                val manager = compose.activity.getSystemService(InputMethodManager::class.java)
                manager.hideSoftInputFromWindow(compose.activity.window.decorView.windowToken, 0)
                compose.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
            }
            compose.waitUntil(15000) { compose.activity.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE }
            waitReady()
            show("title")
            compose.onNodeWithTag("title").assertTextContains(title)
            show("design")
            compose.onNodeWithTag("design").assertTextContains(design)
            show("submit")
            shot("07-landscape-large-text")
            compose.onNodeWithTag("submit").performClick()
            compose.waitUntil(30000) { compose.onAllNodesWithTag("status").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithTag("status").assertTextEquals("等待助手")

            shell("wm size 2048x2732")
            compose.waitUntil(15000) { compose.activity.resources.configuration.screenWidthDp > 840 }
            waitReady()
            val panel = compose.onNodeWithTag("workspace-content").fetchSemanticsNode().boundsInRoot
            val density = compose.activity.resources.displayMetrics.density
            assertTrue("Wide windows must retain a readable content width", panel.width <= 840 * density + 1)
            assertEquals(Configuration.UI_MODE_NIGHT_YES,
                compose.activity.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK)
            shot("08-tablet-dark")
        } finally {
            shell("settings put system font_scale $oldFont")
            shell("cmd uimode night $oldNight")
            shell("wm size $oldSize")
            shell("wm density $oldDensity")
            compose.activity.runOnUiThread { compose.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED }
            compose.waitForIdle()
        }
    }
}
