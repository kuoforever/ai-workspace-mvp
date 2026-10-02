package io.github.kuoforever.aiworkspace.benchmark

import androidx.benchmark.macro.CompilationMode
import androidx.benchmark.macro.FrameTimingMetric
import androidx.benchmark.macro.StartupMode
import androidx.benchmark.macro.StartupTimingMetric
import androidx.benchmark.macro.junit4.MacrobenchmarkRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Direction
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class WorkspaceBenchmark {
    @get:Rule val benchmark = MacrobenchmarkRule()
    private val packageName = "io.github.kuoforever.aiworkspace"

    @Test fun coldLaunch() {
        benchmark.measureRepeated(packageName, listOf(StartupTimingMetric()),
            compilationMode = CompilationMode.Full(), iterations = 10, startupMode = StartupMode.COLD,
            setupBlock = { pressHome() }) {
            startActivityAndWait()
            check(device.wait(Until.findObject(By.res("new-review")), 15000) != null)
            check(device.wait(Until.gone(By.res("busy")), 15000))
        }
    }

    @Test fun pasteEightThousandCharacters() {
        benchmark.measureRepeated(packageName, listOf(FrameTimingMetric()),
            compilationMode = CompilationMode.Full(), iterations = 5,
            setupBlock = {
                killProcess(); startActivityAndWait()
                check(device.wait(Until.gone(By.res("busy")), 15000))
                device.wait(Until.findObject(By.res("new-review")), 15000)!!.click()
                check(device.wait(Until.findObject(By.res("design")), 15000) != null)
            }) {
            val field = device.findObject(By.res("design"))
            for (character in listOf("a", "b", "c")) {
                field.text = character.repeat(8000)
                check(device.wait(Until.hasObject(By.res("save-state").text("输入已保存")), 15000))
            }
            assertTrue(field.text.endsWith("c".repeat(100)))
        }
    }

    @Test fun scrollTwentyReviewRows() {
        benchmark.measureRepeated(packageName, listOf(FrameTimingMetric()),
            compilationMode = CompilationMode.Full(), iterations = 5,
            setupBlock = {
                killProcess(); startActivityAndWait()
                check(device.wait(Until.gone(By.res("busy")), 15000))
                check(device.wait(Until.findObject(By.res("home-list")), 15000) != null)
            }) {
            val list: UiObject2 = device.findObject(By.res("home-list"))
            repeat(3) { list.scroll(Direction.DOWN, 0.8f) }
            repeat(3) { list.scroll(Direction.UP, 0.8f) }
        }
    }
}
