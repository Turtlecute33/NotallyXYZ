package com.philkes.notallyx.data.imports.evernote

import android.app.Application
import android.net.Uri
import android.util.Base64
import android.webkit.MimeTypeMap
import com.philkes.notallyx.R
import com.philkes.notallyx.data.imports.ExternalImporter
import com.philkes.notallyx.data.imports.ImportException
import com.philkes.notallyx.data.imports.ImportProgress
import com.philkes.notallyx.data.imports.ImportStage
import com.philkes.notallyx.data.imports.containsFile
import com.philkes.notallyx.data.imports.evernote.EvernoteImporter.Companion.parseTimestamp
import com.philkes.notallyx.data.imports.parseBodyAndSpansFromHtml
import com.philkes.notallyx.data.model.Audio
import com.philkes.notallyx.data.model.BaseNote
import com.philkes.notallyx.data.model.FileAttachment
import com.philkes.notallyx.data.model.Folder
import com.philkes.notallyx.data.model.ListItem
import com.philkes.notallyx.data.model.NoteViewMode
import com.philkes.notallyx.data.model.Type
import com.philkes.notallyx.presentation.view.misc.Progress
import com.philkes.notallyx.utils.log
import com.philkes.notallyx.utils.startsWithAnyOf
import com.philkes.notallyx.utils.write
import java.io.File
import java.io.InputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlinx.coroutines.flow.MutableStateFlow
import org.jsoup.Jsoup
import org.simpleframework.xml.Serializer
import org.simpleframework.xml.convert.AnnotationStrategy
import org.simpleframework.xml.core.Persister

class EvernoteImporter : ExternalImporter {
    private val serializer: Serializer = Persister(AnnotationStrategy())

    override fun import(
        app: Application,
        source: Uri,
        destination: File,
        progress: MutableStateFlow<Progress?>?,
    ): Pair<List<BaseNote>, File> {
        progress?.value = ImportProgress(indeterminate = true)
        if (MimeTypeMap.getFileExtensionFromUrl(source.toString()) != "enex") {
            throw ImportException(
                R.string.invalid_evernote,
                IllegalArgumentException("Provided file is not in ENEX format"),
            )
        }
        val evernoteExport: EvernoteExport =
            parseExport(app.contentResolver.openInputStream(source)!!)!!

        val total = evernoteExport.notes.size
        progress?.value = ImportProgress(total = total)
        var counter = 1
        try {
            var firstResourceIndex = 0
            val notes =
                evernoteExport.notes.map {
                    val note = it.mapToBaseNote(firstResourceIndex)
                    firstResourceIndex += it.resources.size
                    progress?.value = ImportProgress(current = counter++, total = total)
                    note
                }
            val resources = evernoteExport.notes.flatMap { it.resources }
            saveResourcesToFiles(app, resources, destination, progress)
            return Pair(notes, destination)
        } catch (e: Exception) {
            throw ImportException(R.string.invalid_evernote, e)
        }
    }

    fun parseExport(inputStream: InputStream): EvernoteExport? =
        try {
            serializer.read(EvernoteExport::class.java, inputStream)
        } catch (e: Exception) {
            throw ImportException(R.string.invalid_evernote, e)
        }

    private fun saveResourcesToFiles(
        app: Application,
        resources: Collection<EvernoteResource>,
        dir: File,
        progress: MutableStateFlow<Progress?>? = null,
    ) {
        progress?.value = ImportProgress(total = resources.size, stage = ImportStage.EXTRACT_FILES)
        resources.forEachIndexed { idx, it ->
            val name = it.stagedName(idx)
            val file = File(dir, name)
            try {
                // Never write outside the import folder.
                if (!dir.containsFile(name)) throw IllegalArgumentException("Unsafe file name")
                val data = Base64.decode(it.data!!.content.trimStart(), Base64.DEFAULT)
                file.write(data)
            } catch (e: Exception) {
                app.log(TAG, throwable = e)
            }
            progress?.value =
                ImportProgress(
                    current = idx + 1,
                    total = resources.size,
                    stage = ImportStage.EXTRACT_FILES,
                )
        }
    }

    companion object {
        private const val TAG = "EvernoteImporter"

        fun parseTimestamp(timestamp: String): Long {
            val format = SimpleDateFormat(EVERNOTE_DATE_FORMAT, Locale.getDefault())
            format.timeZone = TimeZone.getTimeZone("UTC")
            return try {
                val date: Date = format.parse(timestamp) ?: Date()
                date.time // Return milliseconds since epoch
            } catch (e: Exception) {
                System.currentTimeMillis()
            }
        }
    }
}

private const val EVERNOTE_DATE_FORMAT = "yyyyMMdd'T'HHmmss'Z'"
private const val EVERNOTE_NOTE_XML_TAG = "en-note"

/**
 * [firstResourceIndex] is the position of the first resource of this note among all resources of
 * the export, so that each attachment names the file that [EvernoteImporter] writes for it.
 */
fun EvernoteNote.mapToBaseNote(firstResourceIndex: Int = 0): BaseNote {
    val (text, spans) =
        parseBodyAndSpansFromHtml(
            content.withoutTaskPlaceholder(),
            EVERNOTE_NOTE_XML_TAG,
            useInnermostRootTag = true,
            brTagsAsNewLine = false,
        )
    val items = tasks.mapToListItem()
    // A list shows only its items, so a note with tasks and text becomes a note with task lines.
    val isList = items.isNotEmpty() && text.isBlank()
    val body =
        if (isList) text
        else text + items.joinToString("") { "\n${if (it.checked) "☑" else "☐"} ${it.body}" }
    val staged = resources.mapIndexed { i, it -> it to it.stagedName(firstResourceIndex + i) }
    val images = staged.filter { it.first.mime.startsWith("image") }.toFileAttachments()
    val files =
        staged.filter { !it.first.mime.startsWithAnyOf("image", "audio") }.toFileAttachments()
    val audios =
        staged
            .filter { it.first.mime.startsWith("audio") }
            .map { (_, name) -> Audio(name, -1, System.currentTimeMillis()) }

    return BaseNote(
        0L,
        type = if (isList) Type.LIST else Type.NOTE,
        folder = Folder.NOTES, // There is no archive in Evernote, also deleted notes are not
        // exported
        color = BaseNote.COLOR_DEFAULT, // TODO: possible in Evernote?
        title = title,
        pinned = false, // not exported from Evernote
        timestamp = parseTimestamp(created),
        modifiedTimestamp = parseTimestamp(updated),
        labels = tag.map { it.name },
        body = body,
        spans = spans,
        items = if (isList) items else listOf(),
        images = images,
        files = files,
        audios = audios,
        reminders = mutableListOf(),
        NoteViewMode.EDIT,
        false,
    )
}

/**
 * Removes the block that Evernote puts where the tasks are. It only says that tasks are not
 * supported.
 */
private fun String.withoutTaskPlaceholder(): String {
    if (!contains("--en-task-group")) return this
    val document = Jsoup.parse(this)
    document.outputSettings().prettyPrint(false)
    document.getElementsByAttributeValueContaining("style", "--en-task-group").remove()
    return document.outerHtml()
}

/**
 * The name of the file that holds the resource at [index] during the import. Many resources have
 * the same file name (for example "image.png"), so each one gets its own name. The app shows the
 * file name from the export.
 */
private fun EvernoteResource.stagedName(index: Int): String {
    val extension = attributes?.fileName.orEmpty().substringAfterLast('.', "")
    return if (extension.matches(SAFE_EXTENSION)) "$index.$extension" else "$index"
}

private val SAFE_EXTENSION = Regex("[A-Za-z0-9]{1,10}")

private fun List<Pair<EvernoteResource, String>>.toFileAttachments(): List<FileAttachment> {
    return map { (resource, name) ->
        FileAttachment(name, resource.attributes?.fileName.orEmpty(), resource.mime)
    }
}

fun Collection<EvernoteTask>.mapToListItem(): List<ListItem> {
    return sortedBy { it.sortWeight }
        .mapIndexed { index, evernoteTask ->
            ListItem(
                body = evernoteTask.title,
                checked = evernoteTask.taskStatus == TaskStatus.COMPLETED,
                isChild = false, // You cant indent tasks in Evernote
                order = index,
                children = mutableListOf(),
            )
        }
}
