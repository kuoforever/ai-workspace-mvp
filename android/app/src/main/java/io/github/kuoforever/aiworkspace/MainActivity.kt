package io.github.kuoforever.aiworkspace

import android.content.Intent
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.withStyle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import androidx.activity.compose.ReportDrawnWhen
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.delay

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val factory = object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T =
                WorkspaceViewModel(LocalWorkspaceApi(), DeviceStore(applicationContext)) as T
        }
        setContent {
            val colors = if (isSystemInDarkTheme()) darkColorScheme(
                primary = Color(0xFF8BD8C8), onPrimary = Color(0xFF063B32),
                primaryContainer = Color(0xFF244E44), onPrimaryContainer = Color(0xFFB4EDE0),
                secondary = Color(0xFFB9CBD2), secondaryContainer = Color(0xFF34474F),
                onSecondaryContainer = Color(0xFFDCEAF0),
                background = Color(0xFF111B19), surface = Color(0xFF18221F),
            ) else lightColorScheme(
                primary = Color(0xFF25675E), secondary = Color(0xFF596E78),
                primaryContainer = Color(0xFFD0E9E0), onPrimaryContainer = Color(0xFF092E26),
                secondaryContainer = Color(0xFFE0E8ED), onSecondaryContainer = Color(0xFF24353E),
                background = Color(0xFFF5F7F6), surface = Color.White,
            )
            MaterialTheme(colorScheme = colors) { Workspace(viewModel(factory = factory)) }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Workspace(vm: WorkspaceViewModel) {
    val state = vm.ui
    ReportDrawnWhen { !state.loadingLocal && !state.busy }
    val context = LocalContext.current
    var connectionHelp by rememberSaveable { mutableStateOf(false) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(vm, lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            try {
                while (true) { delay(3000); vm.poll() }
            } finally { vm.pausePolling() }
        }
    }
    BackHandler(state.page != Page.HOME) { vm.back() }
    if (connectionHelp) AlertDialog(
        onDismissRequest = { connectionHelp = false },
        title = { Text("连接电脑工作台") },
        text = { SelectionContainer { Text("1. 在电脑启动 AI Workspace 后端。\n2. 连接 USB 调试设备或模拟器，在电脑执行 adb reverse tcp:8765 tcp:8765。\n3. 回到应用检查连接，再刷新记录。\n\n当前地址：http://127.0.0.1:8765\n连接成功表示后端可用；评审仍需电脑上的 MCP 助手处理。", modifier = Modifier.verticalScroll(rememberScrollState())) } },
        confirmButton = { TextButton(onClick = { connectionHelp = false }) { Text("知道了") } },
    )
    Scaffold(
        modifier = Modifier.semantics { testTagsAsResourceId = true },
        topBar = { TopAppBar(
            title = { Text("AI Workspace", fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis) },
            navigationIcon = { if (state.page != Page.HOME) TextButton(onClick = vm::back, enabled = !state.busy) { Text("返回") } },
            actions = { if (state.page in listOf(Page.HOME, Page.DETAIL))
                TextButton(onClick = vm::refresh, enabled = !state.busy) { Text("刷新") }
            },
        ) },
    ) { inset ->
        Box(Modifier.fillMaxSize().padding(inset).consumeWindowInsets(inset).imePadding(), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.fillMaxHeight().widthIn(max = 840.dp).fillMaxWidth().testTag("workspace-content")) {
                if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth().testTag("busy"))
                val header: @Composable () -> Unit = { StatusPanel(state, vm) { connectionHelp = true } }
                if (state.startupError != null) {
                    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(20.dp)) { item { header() } }
                    return@Column
                }
                when (state.page) {
                    Page.HOME -> Home(state, vm, header)
                    Page.CREATE -> Create(state, vm, header)
                    Page.DETAIL -> Detail(state, vm, header)
                    Page.SOURCE -> SourcePage(state, header)
                    Page.EXPORT -> LazyColumn(Modifier.fillMaxSize().testTag("export-list"), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                        item { header() }
                        item { Text("导出预览", style = MaterialTheme.typography.headlineSmall) }
                        item { Button(onClick = {
                            context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_SUBJECT, state.review?.input?.title ?: "工程评审")
                                putExtra(Intent.EXTRA_TEXT, state.exported)
                            }, "分享 Markdown 报告"))
                        }) { Text("分享报告") } }
                        item { SelectionContainer { Text(state.exported, style = MaterialTheme.typography.bodySmall) } }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun StatusPanel(state: WorkspaceUi, vm: WorkspaceViewModel, help: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(state.saveState.label, style = MaterialTheme.typography.bodySmall, modifier = Modifier.testTag("save-state"))
        if (state.saveState == SaveState.FAILED) {
            Button(onClick = vm::retrySave, enabled = !state.busy, modifier = Modifier.testTag("retry-save")) { Text("重试保存") }
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(state.connection.label, style = MaterialTheme.typography.labelMedium,
                modifier = Modifier.padding(vertical = 14.dp).testTag("connection-status"))
            TextButton(onClick = vm::checkConnection, enabled = !state.busy && state.startupError == null,
                modifier = Modifier.testTag("check-connection")) { Text("检查连接") }
            TextButton(onClick = help) { Text("帮助") }
        }
        if (state.startupError != null) {
            Text(state.startupError, modifier = Modifier.testTag("startup-error"))
            Button(onClick = vm::reloadLocalData, modifier = Modifier.testTag("reload-local")) { Text("重新读取本机记录") }
        } else {
            if (state.error != null) Notice(state.error, error = true)
            if (state.pending != null) {
                Notice("上次提交结果尚未确认。重试会沿用原请求，输入暂时锁定。")
                Button(onClick = vm::retry, enabled = !state.busy, modifier = Modifier.testTag("retry-command")) { Text("重试原提交") }
            }
        }
    }
}

@Composable
private fun Notice(text: String, error: Boolean = false) {
    Text(text, color = if (error) MaterialTheme.colorScheme.onErrorContainer else MaterialTheme.colorScheme.onSecondaryContainer,
        modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp)
        .background(if (error) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.secondaryContainer,
            MaterialTheme.shapes.medium).padding(14.dp), style = MaterialTheme.typography.bodySmall)
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Home(state: WorkspaceUi, vm: WorkspaceViewModel, header: @Composable () -> Unit) {
    val context = LocalContext.current
    LazyColumn(Modifier.fillMaxSize().testTag("home-list"), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        item { header() }
        item {
            OutlinedButton(onClick = {
                runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("http://127.0.0.1:8765/workspace"))) }
                    .onFailure { Toast.makeText(context, "浏览器暂不可用，请在电脑打开通用工作台。", Toast.LENGTH_LONG).show() }
            }, enabled = !state.busy, modifier = Modifier.fillMaxWidth().testTag("general-workbench")) {
                Text("通用工作台 · 在浏览器中打开")
            }
        }
        item {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(!state.savedOnly, { vm.showSaved(false) }, enabled = !state.busy, label = { Text("全部评审") })
                FilterChip(state.savedOnly, { vm.showSaved(true) }, enabled = !state.busy,
                    label = { Text("已保存 · " + state.savedRows.size) }, modifier = Modifier.testTag("saved-library"))
            }
            Text("已打开的最近 20 份评审保存在设备，可离线阅读引用和分享报告。", style = MaterialTheme.typography.bodySmall)
        }
        item {
            Text("把设计，变成有依据的判断。", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(8.dp))
            Text(if (state.cached) "显示本机缓存 · 联网后刷新" else "与电脑工作台共享评审记录", style = MaterialTheme.typography.bodySmall)
            Spacer(Modifier.height(18.dp))
            Button(onClick = vm::createPage, enabled = state.editable, modifier = Modifier.fillMaxWidth().testTag("new-review")) { Text("新建设计评审") }
        }
        if ((if (state.savedOnly) state.savedRows else state.rows).isEmpty()) item {
            Text(if (state.savedOnly) "还没有保存的评审。打开记录后，会自动保存到设备。" else "还没有评审。先创建一份设计，或在电脑上提交后刷新。", style = MaterialTheme.typography.bodyMedium)
        }
        items(if (state.savedOnly) state.savedRows else state.rows, key = { it.id }) { row ->
            OutlinedCard(onClick = { vm.open(row.id) }, enabled = !state.busy, modifier = Modifier.fillMaxWidth().testTag("review:${row.id}")) {
                Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(row.title, fontWeight = FontWeight.SemiBold)
                    Text("${statusLabel(row.status)} · ${if (row.mode == "scripted") "离线模拟" else "助手评审"}",
                        style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
                }
            }
        }
        item { Text("人工检查由你确认。AI 报告单独保存。", style = MaterialTheme.typography.bodySmall) }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Create(state: WorkspaceUi, vm: WorkspaceViewModel, header: @Composable () -> Unit) {
    val context = LocalContext.current
    var replaceImport by rememberSaveable { mutableStateOf(false) }
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) vm.importDocument { readDocument(context, uri) }
    }
    fun chooseDocument() = importer.launch(arrayOf("text/*", "application/octet-stream"))
    if (replaceImport) AlertDialog(
        onDismissRequest = { replaceImport = false },
        title = { Text("替换设计材料？") },
        text = { Text("所选文件会替换当前设计材料。取消或导入失败会保留原草稿。") },
        confirmButton = { TextButton(onClick = { replaceImport = false; chooseDocument() }) { Text("选择文件") } },
        dismissButton = { TextButton(onClick = { replaceImport = false }) { Text("取消") } },
    )
    var picker by rememberSaveable { mutableStateOf(false) }
    var query by rememberSaveable { mutableStateOf("") }
    val enabled = state.editable
    val designRequester = remember { BringIntoViewRequester() }
    var designFocused by remember { mutableStateOf(false) }
    val keyboardVisible = WindowInsets.isImeVisible
    val compactEditor = LocalConfiguration.current.screenHeightDp < 480 || LocalDensity.current.fontScale > 1.3f
    LaunchedEffect(keyboardVisible, designFocused) {
        if (keyboardVisible && designFocused) designRequester.bringIntoView()
    }
    if (picker) AlertDialog(
        onDismissRequest = { picker = false },
        title = { Text("选择检查 · ${state.draft.checkIds.size}/8") },
        text = { Column {
            OutlinedTextField(query, { query = it }, label = { Text("编号或关键词") }, singleLine = true)
            LazyColumn(Modifier.weight(1f, fill = false).heightIn(max = 350.dp)) {
                items(state.checks.filter { (it.id + it.question).contains(query, ignoreCase = true) }, key = { it.id }) { check ->
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Checkbox(check.id in state.draft.checkIds, { vm.toggleCheck(check.id) },
                            enabled = enabled && (state.draft.checkIds.size < 8 || check.id in state.draft.checkIds))
                        Text("${check.id} ${check.question}", modifier = Modifier.weight(1f).padding(top = 12.dp), style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        } },
        confirmButton = { TextButton(onClick = { picker = false }) { Text("完成") } },
    )
    LazyColumn(Modifier.fillMaxSize().testTag("create-list"), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item { header() }
        item {
            Text("描述你的设计", style = MaterialTheme.typography.headlineSmall)
            TextButton(onClick = {
                if (state.draft.design.isBlank()) chooseDocument() else replaceImport = true
            }, enabled = enabled, modifier = Modifier.testTag("import-document")) { Text("导入 Markdown / 文本") }
            Text("支持 UTF-8 的 .md、.markdown、.txt，10–8000 字符。", style = MaterialTheme.typography.bodySmall)
            TextButton(onClick = vm::example, enabled = enabled, modifier = Modifier.testTag("fill-example")) { Text("填入演示示例") }
        }
        item { OutlinedTextField(state.draft.title, { if (it.scalarCount() <= 120) vm.edit(state.draft.copy(title = it)) },
            enabled = enabled, label = { Text("评审名称") }, modifier = Modifier.fillMaxWidth().testTag("title"), singleLine = true) }
        item { OutlinedTextField(state.draft.design, { if (it.scalarCount() <= 8000) vm.edit(state.draft.copy(design = it)) },
            enabled = enabled, label = { Text("设计材料") }, supportingText = { Text("${state.draft.design.scalarCount()}/8000 · " + state.saveState.label) },
            modifier = Modifier.fillMaxWidth().bringIntoViewRequester(designRequester)
                .onFocusChanged { designFocused = it.isFocused }.testTag("design"),
            minLines = if (compactEditor) 2 else 5, maxLines = if (compactEditor) 8 else 10) }
        item {
            Text("检查范围 · ${state.draft.checkIds.size}/8", fontWeight = FontWeight.SemiBold)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                state.draft.checkIds.forEach { id -> InputChip(selected = true, onClick = { vm.toggleCheck(id) }, enabled = enabled, label = { Text("$id ×") }) }
            }
            TextButton(onClick = { picker = true }, enabled = enabled && state.checks.isNotEmpty()) { Text("调整检查项") }
        }
        item {
            Text("评审方式", fontWeight = FontWeight.SemiBold)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(state.draft.mode == "mcp", { vm.edit(state.draft.copy(mode = "mcp")) }, enabled = enabled, label = { Text("助手评审") })
                FilterChip(state.draft.mode == "scripted", { vm.edit(state.draft.copy(mode = "scripted")) }, enabled = enabled, label = { Text("离线模拟") })
            }
            Text(if (state.draft.mode == "mcp") "提交后，让电脑中已连接 MCP 的助手处理；手机可继续回答和查看结果。"
                else "固定程序展示流程，本次不调用模型。", style = MaterialTheme.typography.bodySmall)
        }
        item { Button(onClick = vm::create, enabled = enabled, modifier = Modifier.fillMaxWidth().testTag("submit")) { Text("提交评审") } }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Detail(state: WorkspaceUi, vm: WorkspaceViewModel, header: @Composable () -> Unit) {
    val review = state.review ?: return
    val enabled = state.editable
    val context = LocalContext.current
    var copied by remember(review.id) { mutableStateOf(false) }
    val keyboardVisible = WindowInsets.isImeVisible
    val compactEditor = LocalConfiguration.current.screenHeightDp < 480 || LocalDensity.current.fontScale > 1.3f
    LazyColumn(Modifier.fillMaxSize().testTag("detail-list"), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        item { header() }
        item {
            Text(statusLabel(review.status), color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.labelLarge, modifier = Modifier.testTag("status"))
            Text(review.input.title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
            Text("${review.input.checkIds.size} 项检查 · 版本 ${review.revision}", style = MaterialTheme.typography.bodySmall)
            if (state.cached) Text("缓存快照 · 刷新以核对最新状态", color = MaterialTheme.colorScheme.error)
            if (review.input.mode == "scripted") Text("离线模拟 · 未经模型评审", color = MaterialTheme.colorScheme.secondary)
        }
        if (review.status == "waiting_model") item {
            Text(if (state.cached) "这是上次保存的等待状态，请先恢复连接并刷新。"
                else "材料已保存，等待电脑助手接手。将下面的指令发送给已连接 MCP 的助手；结果返回后，此页面会自动更新。")
            TextButton(onClick = {
                (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager)
                    .setPrimaryClip(ClipData.newPlainText("评审指令", assistantPrompt(review.id)))
                copied = true
            }, modifier = Modifier.testTag("copy-assistant-prompt")) { Text(if (copied) "指令已复制" else "复制助手指令") }
        }
        if (review.status == "running") item { Text("工作台正在保存或处理本次操作，完成后页面会自动更新。") }
        if (review.error != null) item { Text(review.error, color = MaterialTheme.colorScheme.error) }
        if (review.status == "waiting_input") {
            items(review.questions, key = { "question:${it.id}" }) { question ->
                val requester = remember { BringIntoViewRequester() }
                var focused by remember { mutableStateOf(false) }
                LaunchedEffect(keyboardVisible, focused) {
                    if (keyboardVisible && focused) requester.bringIntoView()
                }
                Text(question.text, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(state.answers[question.id].orEmpty(), { vm.editAnswer(question.id, it) },
                    label = { Text("你的回答") }, enabled = state.canEditAnswers,
                    minLines = if (compactEditor) 2 else 3, maxLines = 8,
                    modifier = Modifier.fillMaxWidth().bringIntoViewRequester(requester)
                        .onFocusChanged { focused = it.isFocused }.testTag("answer:${question.id}"))
            }
            item { Button(onClick = vm::answer, enabled = enabled, modifier = Modifier.fillMaxWidth().testTag("answer-submit")) { Text("保存回答并继续") } }
        }
        if (review.report != null) {
            item { Text(review.report.summary) }
            items(review.report.findings, key = { "finding:${it.checkId}" }) { finding ->
                OutlinedCard(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text("${finding.checkId} · ${verdictLabel(finding.verdict)}", fontWeight = FontWeight.Bold)
                        Text(finding.explanation, style = MaterialTheme.typography.bodyMedium)
                        Text("下一步", color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.SemiBold)
                        Text(finding.recommendation, style = MaterialTheme.typography.bodyMedium)
                        finding.citations.forEachIndexed { index, citation ->
                            TextButton(onClick = { vm.source(citation) }, enabled = !state.busy, modifier = Modifier.testTag("source:${finding.checkId}:$index")) { Text("查看依据 · ${citation.sourceId}") }
                        }
                    }
                }
            }
            item { Text("引用已通过程序校验；语义仍需人工判断。代码与实验未执行，宿主 token 未知。", style = MaterialTheme.typography.bodySmall) }
        }
        item { OutlinedButton(onClick = vm::export, enabled = !state.busy, modifier = Modifier.fillMaxWidth().testTag("export")) { Text("导出 Markdown") } }
        item {
            Text("设计快照", fontWeight = FontWeight.SemiBold)
            SelectionContainer { Text(review.input.design, style = MaterialTheme.typography.bodySmall) }
        }
    }
}

@Composable
private fun SourcePage(state: WorkspaceUi, header: @Composable () -> Unit) {
    val source = state.source ?: return
    val excerpt = sourceExcerpt(source.text, state.quote)
    val highlight = MaterialTheme.colorScheme.primaryContainer
    var complete by rememberSaveable(source.sha256, state.quote) { mutableStateOf(false) }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item { header() }
        item { Text("引用依据", style = MaterialTheme.typography.headlineSmall) }
        item { Text(source.title, fontWeight = FontWeight.SemiBold) }
        if (excerpt != null) {
            item { Text("原文第 " + excerpt.firstLine + "–" + excerpt.lastLine + " 行", modifier = Modifier.testTag("source-location")) }
            item { SelectionContainer {
                Text(buildAnnotatedString {
                    append(excerpt.before)
                    withStyle(SpanStyle(background = highlight, fontWeight = FontWeight.Bold)) { append(excerpt.quote) }
                    append(excerpt.after)
                }, modifier = Modifier.fillMaxWidth().testTag("source-context"))
            } }
        } else {
            item { Text("未在此快照找到对应片段，请核对来源。", color = MaterialTheme.colorScheme.error) }
            item { SelectionContainer { Text(state.quote) } }
        }
        item { Text(source.path, style = MaterialTheme.typography.bodySmall) }
        item { SelectionContainer { Text("SHA-256 " + source.sha256, style = MaterialTheme.typography.bodySmall) } }
        item { TextButton(onClick = { complete = !complete }) { Text(if (complete) "收起完整来源" else "查看完整来源") } }
        if (complete) item { SelectionContainer { Text(source.text) } }
    }
}
