package com.philkes.notallyx.sync

import com.philkes.notallyx.data.model.BaseNote
import com.philkes.notallyx.data.model.Converters
import com.philkes.notallyx.data.model.Folder
import com.philkes.notallyx.data.model.NoteViewMode
import com.philkes.notallyx.data.model.Type
import com.philkes.notallyx.data.model.isNoteUrl
import com.philkes.notallyx.utils.SUBFOLDER_AUDIOS
import com.philkes.notallyx.utils.SUBFOLDER_FILES
import com.philkes.notallyx.utils.SUBFOLDER_IMAGES
import org.json.JSONArray
import org.json.JSONObject

/**
 * Converts notes to and from the sync payload (PROTOCOL.md, section 5) and merges concurrent
 * changes field by field.
 */
object NotePayload {

    /** Fields that are merged as one unit. If both sides changed them, a conflict copy is made. */
    private val CONTENT = listOf("type", "title", "body", "spans", "items")
    private const val NOTE_URL = "note://"
    private val HEX_ID = Regex("^[0-9a-f]{32}$")

    /** @param remoteIdOf maps a local note id to its record id, null if unknown. */
    fun encode(note: BaseNote, remoteIdOf: (Long) -> String?): JSONObject {
        val spans =
            note.spans.map { span ->
                val url = span.linkData
                if (span.link && url.isNoteUrl())
                    span.copy(linkData = toRemoteUrl(url!!, remoteIdOf))
                else span
            }
        val reminders = Converters.remindersToJSONArray(note.reminders)
        for (i in 0 until reminders.length()) reminders
            .getJSONObject(i)
            .remove("isNotificationVisible")
        return JSONObject()
            .put("v", 1)
            .put("type", note.type.name)
            .put("folder", note.folder.name)
            .put("color", note.color)
            .put("title", note.title)
            .put("pinned", note.pinned)
            .put("timestamp", note.timestamp)
            .put("modifiedTimestamp", note.modifiedTimestamp)
            .put("labels", JSONArray(note.labels))
            .put("body", note.body)
            .put("spans", Converters.spansToJSONArray(spans))
            .put("items", Converters.itemsToJSONArray(note.items))
            .put("images", JSONArray(Converters.filesToJson(note.images)))
            .put("files", JSONArray(Converters.filesToJson(note.files)))
            .put("audios", JSONArray(Converters.audiosToJson(note.audios)))
            .put("reminders", reminders)
            .put("viewMode", note.viewMode.name)
    }

    /**
     * @param local the current local version; its id and device-local state are kept.
     * @param localIdOf maps a record id to a local note id, null if unknown.
     */
    fun decode(payload: JSONObject, local: BaseNote?, localIdOf: (String) -> Long?): BaseNote {
        val json = withoutNulls(payload) as JSONObject
        val now = System.currentTimeMillis()
        val spans =
            Converters.jsonToSpans(json.array("spans")).map { span ->
                val url = span.linkData
                if (span.link && url.isNoteUrl()) span.copy(linkData = toLocalUrl(url!!, localIdOf))
                else span
            }
        val visible =
            local?.reminders?.associate { it.id to it.isNotificationVisible } ?: emptyMap()
        val timestamp = json.optLong("timestamp", now)
        return BaseNote(
            id = local?.id ?: 0L,
            type = Type.valueOfOrDefault(json.string("type")),
            folder = Folder.valueOfOrDefault(json.string("folder")),
            color = json.string("color").takeIf { isColor(it) } ?: BaseNote.COLOR_DEFAULT,
            title = json.string("title"),
            pinned = json.optBoolean("pinned"),
            timestamp = timestamp,
            modifiedTimestamp = json.optLong("modifiedTimestamp", timestamp),
            labels = Converters.jsonToLabels(json.array("labels")),
            body = json.string("body"),
            spans = spans,
            items = Converters.jsonToItems(json.array("items")),
            images =
                Converters.jsonToFiles(json.array("images")).filter { isSafeName(it.localName) },
            files = Converters.jsonToFiles(json.array("files")).filter { isSafeName(it.localName) },
            audios = Converters.jsonToAudios(json.array("audios")).filter { isSafeName(it.name) },
            reminders =
                Converters.jsonToReminders(json.array("reminders")).map {
                    it.copy(isNotificationVisible = visible[it.id] ?: false)
                },
            viewMode = NoteViewMode.valueOfOrDefault(json.string("viewMode")),
            isPinnedToStatus = local?.isPinnedToStatus ?: false,
        )
    }

    /**
     * The converters read a JSON null as the text "null" (and a null repetition as "daily"), so
     * drop null values first: a missing key and a null mean the same (PROTOCOL.md, section 7).
     */
    private fun withoutNulls(value: Any): Any =
        when (value) {
            is JSONObject ->
                JSONObject().also { out ->
                    value.keys().forEach { key ->
                        val v = value.opt(key)
                        if (v != null && v != JSONObject.NULL) out.put(key, withoutNulls(v))
                    }
                }
            is JSONArray ->
                JSONArray().also { out ->
                    for (i in 0 until value.length()) {
                        val v = value.opt(i)
                        if (v != null && v != JSONObject.NULL) out.put(withoutNulls(v))
                    }
                }
            else -> value
        }

    private fun JSONObject.string(key: String) = if (isNull(key)) "" else optString(key)

    private fun JSONObject.array(key: String) = optJSONArray(key) ?: JSONArray()

    private fun isColor(value: String) =
        value == BaseNote.COLOR_DEFAULT ||
            value.matches(Regex("^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$"))

    /** Attachment names become file names; reject anything that could leave the folder. */
    fun isSafeName(name: String) =
        name.isNotEmpty() &&
            name.length <= 255 &&
            !name.startsWith(".") &&
            name.none { it == '/' || it == '\\' || it.code < 32 }

    private fun toRemoteUrl(url: String, remoteIdOf: (Long) -> String?): String {
        val target = url.substringAfter(NOTE_URL).substringBefore("/")
        val type = url.substringAfterLast("/")
        if (HEX_ID.matches(target)) return url // not resolved locally yet, keep it
        val remote = target.toLongOrNull()?.let(remoteIdOf) ?: "-1"
        return "$NOTE_URL$remote/$type"
    }

    private fun toLocalUrl(url: String, localIdOf: (String) -> Long?): String {
        val target = url.substringAfter(NOTE_URL).substringBefore("/")
        val type = url.substringAfterLast("/")
        if (!HEX_ID.matches(target)) return "$NOTE_URL-1/$type"
        // Unknown targets keep the record id; [SyncManager] resolves them after the pull.
        return localIdOf(target)?.let { "$NOTE_URL$it/$type" } ?: url
    }

    fun hasUnresolvedLinks(note: BaseNote) =
        note.spans.any { span ->
            span.link &&
                span.linkData.isNoteUrl() &&
                HEX_ID.matches(span.linkData!!.substringAfter(NOTE_URL).substringBefore("/"))
        }

    private fun shortHash(value: String) = SyncCrypto.sha256(value.toByteArray()).copyOf(8).toHex()

    /** Hashes of each field (content fields as one), used as merge base. */
    fun fieldHashes(json: JSONObject): JSONObject {
        val out = JSONObject()
        out.put(
            "content",
            shortHash(CONTENT.joinToString("\u0000") { json.opt(it)?.toString() ?: "" }),
        )
        json.keys().forEach { key ->
            if (key !in CONTENT && key != "v") out.put(key, shortHash(json.opt(key).toString()))
        }
        return out
    }

    class Merge(val merged: JSONObject, val contentConflict: Boolean)

    /**
     * 3-way merge of [local] and [remote] against [base] (field hashes of the last synced version).
     * A field changed on one side only takes that side. A field changed on both sides keeps the
     * local value, except for timestamps (newest), labels and attachments (union).
     */
    fun merge(base: JSONObject?, local: JSONObject, remote: JSONObject): Merge {
        val lh = fieldHashes(local)
        val rh = fieldHashes(remote)
        val merged = JSONObject(local.toString())
        var conflict = false
        val baseContent = base?.optString("content")
        if (lh.optString("content") != rh.optString("content")) {
            when (baseContent) {
                lh.optString("content") -> CONTENT.forEach { merged.put(it, remote.opt(it)) }
                rh.optString("content") -> Unit
                else -> conflict = true
            }
        }
        val keys = (local.keys().asSequence() + remote.keys().asSequence()).toSet()
        for (key in keys) {
            if (key in CONTENT || key == "v") continue
            val l = lh.optString(key)
            val r = rh.optString(key)
            if (l == r) continue
            val b = base?.optString(key)
            when {
                l == b -> merged.put(key, remote.opt(key))
                r == b -> Unit
                key == "modifiedTimestamp" ->
                    merged.put(key, maxOf(local.optLong(key), remote.optLong(key)))
                key == "labels" ->
                    merged.put(
                        key,
                        union(local.optJSONArray(key), remote.optJSONArray(key)) { it.toString() },
                    )
                key == "images" || key == "files" ->
                    merged.put(
                        key,
                        union(local.optJSONArray(key), remote.optJSONArray(key)) {
                            (it as? JSONObject)?.optString("localName") ?: it.toString()
                        },
                    )
                key == "audios" ->
                    merged.put(
                        key,
                        union(local.optJSONArray(key), remote.optJSONArray(key)) {
                            (it as? JSONObject)?.optString("name") ?: it.toString()
                        },
                    )
            }
        }
        return Merge(merged, conflict)
    }

    private fun union(a: JSONArray?, b: JSONArray?, keyOf: (Any) -> String): JSONArray {
        val out = JSONArray()
        val seen = HashSet<String>()
        for (array in listOfNotNull(a, b)) {
            for (i in 0 until array.length()) {
                val item = array.get(i)
                if (seen.add(keyOf(item))) out.put(item)
            }
        }
        return out
    }

    /** All attachment names of a note, with the media subfolder they live in. */
    fun attachments(note: BaseNote): List<Pair<String, String>> =
        note.images.map { SUBFOLDER_IMAGES to it.localName } +
            note.files.map { SUBFOLDER_FILES to it.localName } +
            note.audios.map { SUBFOLDER_AUDIOS to it.name }

    fun labelJson(value: String, order: Int): JSONObject =
        JSONObject().put("v", 1).put("value", value).put("order", order)
}
