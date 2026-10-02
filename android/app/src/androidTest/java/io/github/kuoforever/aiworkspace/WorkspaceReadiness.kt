package io.github.kuoforever.aiworkspace

import androidx.compose.ui.test.*

/** Network callbacks are outside Compose's idling resources. A visible cached
 * status does not mean the operation finished or its controls are editable. */
fun ComposeTestRule.waitForEnabled(matcher: SemanticsMatcher) {
    waitUntil(30000) {
        onAllNodesWithTag("workspace-content").fetchSemanticsNodes().isNotEmpty() &&
            onAllNodesWithTag("busy").fetchSemanticsNodes().isEmpty() &&
            onAllNodes(matcher and isEnabled()).fetchSemanticsNodes().isNotEmpty()
    }
    onNode(matcher).assertIsEnabled()
}
