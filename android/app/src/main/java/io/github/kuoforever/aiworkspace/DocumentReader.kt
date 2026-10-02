package io.github.kuoforever.aiworkspace

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Copy the selected document immediately; no broad storage permission or retained URI is needed. */
suspend fun readDocument(context: Context, uri: Uri): ImportedDocument = withContext(Dispatchers.IO) {
    val resolver = context.contentResolver
    val name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
        if (cursor.moveToFirst()) cursor.getString(0) else null
    } ?: "设计材料.txt"
    val stream = resolver.openInputStream(uri) ?: error("文件无法读取，原草稿已保留。")
    stream.use { DocumentImport.read(name, it) }
}
