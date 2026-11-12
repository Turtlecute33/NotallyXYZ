package com.philkes.notallyx.sync

import android.content.ContextWrapper
import android.util.Log
import androidx.room.withTransaction
import com.philkes.notallyx.data.NotallyDatabase
import com.philkes.notallyx.data.dao.BaseNoteDao
import com.philkes.notallyx.data.dao.BaseNoteDao.Companion.MAX_BODY_CHAR_LENGTH
import com.philkes.notallyx.data.model.BaseNote
import com.philkes.notallyx.data.model.Converters
import com.philkes.notallyx.data.model.Label
import com.philkes.notallyx.data.model.Type
import com.philkes.notallyx.data.model.hasUpcomingNotification
import com.philkes.notallyx.data.model.toText
import com.philkes.notallyx.presentation.widget.WidgetProvider
import com.philkes.notallyx.sync.SyncStore.Companion.KIND_LABEL
import com.philkes.notallyx.sync.SyncStore.Companion.KIND_NOTE
import com.philkes.notallyx.utils.SUBFOLDER_AUDIOS
import com.philkes.notallyx.utils.SUBFOLDER_FILES
import com.philkes.notallyx.utils.SUBFOLDER_IMAGES
import com.philkes.notallyx.utils.cancelPinAndReminders
import com.philkes.notallyx.utils.getCurrentAudioDirectory
import com.philkes.notallyx.utils.getCurrentFilesDirectory
import com.philkes.notallyx.utils.getCurrentImagesDirectory
import com.philkes.notallyx.utils.pinAndScheduleReminders
import com.philkes.notallyx.utils.resolveAttachmentFile
import java.io.File
import org.json.JSONObject

/** One sync run: pull, merge, push. See PROTOCOL.md, section 7. */
class SyncEngine(
    private val app: ContextWrapper,
    private val database: NotallyDatabase,
    private val api: SyncApi,
    private val keys: SyncCrypto.Keys,
    private val openNotes: Set<Long>,
) {
    private val store = SyncStore(database)
    private val dao = database.getBaseNoteDao()
    private val labelDao = database.getLabelDao()

    /** Unlinked local notes by title, read once per pull for [findSameNote]. */
    private var unlinkedByTitle: Map<String, List<Long>>? = null

    /**
     * A remote change whose data opened. [json] is null for an authentic deletion. [attachments]
     * are the attachments of a note.
     */
    private class Incoming(
        val change: SyncApi.RemoteChange,
        val json: JSONObject?,
        val attachments: List<Pair<String, String>> = emptyList(),
    )

    private class Pending(
        val entry: SyncStore.OutboxEntry,
        val change: SyncApi.OutChange,
        val record: SyncStore.Record,
        val hash: String?,
    )

    /** Side effects that must run after the database transaction. */
    private inner class Effects {
        val cancel = ArrayList<BaseNote>()
        val schedule = ArrayList<BaseNote>()
        val widgets = HashSet<Long>()
        val removedAttachments = ArrayList<Pair<String, String>>()

        fun inserted(note: BaseNote) {
            schedule.add(note)
        }

        fun updated(old: BaseNote, new: BaseNote) {
            cancel.add(old)
            schedule.add(new)
            widgets.add(old.id)
            removedAttachments.addAll(
                NotePayload.attachments(old) - NotePayload.attachments(new).toSet()
            )
        }

        fun deleted(old: BaseNote) {
            cancel.add(old)
            widgets.add(old.id)
            removedAttachments.addAll(NotePayload.attachments(old))
        }

        suspend fun run() {
            cancel.forEach { app.cancelPinAndReminders(it.id, it.reminders) }
            app.pinAndScheduleReminders(
                schedule.map { note ->
                    note.copy(reminders = note.reminders.filter { it.hasUpcomingNotification() })
                }
            )
            if (widgets.isNotEmpty()) WidgetProvider.sendBroadcast(app, widgets.toLongArray())
            if (removedAttachments.isNotEmpty()) {
                val referenced = referencedAttachments()
                removedAttachments
                    .filter { it !in referenced }
                    .forEach { (folder, name) -> app.resolveAttachmentFile(folder, name)?.delete() }
            }
        }
    }

    /** @return true if the server and this device have the same state afterwards. */
    suspend fun run(): Boolean {
        deleteTempFiles()
        repeat(3) {
            pull()
            if (!push()) return true
        }
        return false
    }

    // ---- Pull ----

    suspend fun pull() {
        unlinkedByTitle = null
        applyDeferred()
        var cursor = store.getMeta(META_CURSOR)?.toLongOrNull() ?: 0L
        var appliedNotes = false
        do {
            val page = api.changes(cursor)
            val incoming = ArrayList<Incoming>()
            val rejected = ArrayList<SyncApi.RemoteChange>()
            val unreadable = ArrayList<SyncApi.RemoteChange>()
            for (change in page.changes) {
                val plain = open(change)
                val item = plain?.let { read(change, it) }
                when {
                    plain == null -> rejected.add(change)
                    item == null -> unreadable.add(change)
                    else -> incoming.add(item)
                }
            }
            download(incoming.flatMap { it.attachments })
            val effects = Effects()
            database.withTransaction {
                store.paused {
                    val linked = store.linkedNoteIds().toMutableSet()
                    incoming.forEach { item ->
                        when (item.change.kind) {
                            KIND_NOTE -> {
                                store.setMeta(UNREADABLE + item.change.id, null)
                                applyNote(item, linked, effects)
                                appliedNotes = true
                            }
                            KIND_LABEL -> applyLabel(item)
                        }
                    }
                    rejected.forEach(::repair)
                    unreadable.forEach(::skip)
                    store.setMeta(META_CURSOR, page.seq.toString())
                }
            }
            effects.run()
            cursor = page.seq
        } while (page.more)
        if (appliedNotes) resolveLinks()
        downloadMissing()
    }

    /**
     * A remote change for a note that is open in the editor waits until the editor is closed;
     * otherwise the next save of the editor would overwrite it. Then it is merged as usual.
     */
    private fun defer(item: Incoming) {
        val value = JSONObject().put("seq", item.change.seq).put("json", item.json)
        store.setMeta(DEFERRED + item.change.id, value.toString())
    }

    private suspend fun applyDeferred() {
        val ready =
            store.metaWithPrefix(DEFERRED).mapNotNull { (key, value) ->
                val id = key.removePrefix(DEFERRED)
                val localId = store.recordByRemote(KIND_NOTE, id)?.localKey?.toLongOrNull()
                if (localId != null && localId in openNotes) return@mapNotNull null
                val stored = JSONObject(value)
                val json = stored.optJSONObject("json")
                val change = SyncApi.RemoteChange(KIND_NOTE, id, stored.getLong("seq"), null)
                val attachments = if (json == null) emptyList() else attachmentsOf(json)
                if (attachments == null) {
                    // Kept aside by an older version of the app, which did not check it.
                    store.setMeta(key, null)
                    skip(change)
                    return@mapNotNull null
                }
                Incoming(change, json, attachments) to key
            }
        if (ready.isEmpty()) return
        download(ready.flatMap { it.first.attachments })
        val effects = Effects()
        database.withTransaction {
            store.paused {
                val linked = store.linkedNoteIds().toMutableSet()
                ready.forEach { (item, key) ->
                    store.setMeta(key, null)
                    applyNote(item, linked, effects)
                }
            }
        }
        effects.run()
    }

    /**
     * Opens the data of a change. Returns null if the data is missing or does not open (forged
     * deletion, wrong key, tampered data).
     */
    private fun open(change: SyncApi.RemoteChange): ByteArray? {
        val data = change.data ?: return null
        return try {
            SyncCrypto.open(keys.encKey, SyncCrypto.ad(change.kind, change.id), data)
        } catch (e: Exception) {
            Log.w(TAG, "Skipping undecryptable ${change.kind} record: ${e.javaClass.simpleName}")
            null
        }
    }

    /**
     * Reads opened data. A deletion counts only if its sealed payload says so: the `deleted` flag
     * of the server is not authenticated. Returns null if this app cannot read the data.
     */
    private fun read(change: SyncApi.RemoteChange, plain: ByteArray): Incoming? {
        val json =
            try {
                JSONObject(plain.decodeToString())
            } catch (e: Exception) {
                Log.w(TAG, "Skipping unreadable ${change.kind} record: ${e.javaClass.simpleName}")
                return null
            }
        return when {
            NotePayload.isTombstone(json) -> Incoming(change, null)
            change.kind != KIND_NOTE -> Incoming(change, json)
            else -> attachmentsOf(json)?.let { Incoming(change, json, it) }
        }
    }

    /**
     * Decodes a remote note once before it is applied, so that a note that this app cannot read
     * (for example an image without a type) cannot stop the pull. Null if it cannot be read.
     */
    private fun attachmentsOf(json: JSONObject): List<Pair<String, String>>? =
        try {
            NotePayload.attachments(NotePayload.decode(json, null) { null })
        } catch (e: Exception) {
            Log.w(TAG, "Skipping unreadable note record: ${e.javaClass.simpleName}")
            null
        }

    /**
     * An authentic change that this app cannot read is skipped, so that the cursor moves on. The
     * local copy stays as it is and is not written over the change; a later local edit is. Blob
     * cleanup waits while such a change is the newest version of a note, as it can use blobs.
     */
    private fun skip(change: SyncApi.RemoteChange) {
        val record = store.recordByRemote(change.kind, change.id)
        if (record != null && change.seq > record.seq)
            store.putRecord(record.copy(seq = change.seq))
        if (change.kind == KIND_NOTE) store.setMeta(UNREADABLE + change.id, change.seq.toString())
    }

    /**
     * A change that does not open is never applied. If this device has the record, it keeps its
     * copy and writes it to the server again on top of that change, which repairs the server copy.
     */
    private fun repair(change: SyncApi.RemoteChange) {
        val record = store.recordByRemote(change.kind, change.id) ?: return
        if (change.seq <= record.seq) return
        val key = record.localKey ?: return
        // hash = null: push must send the copy even though it did not change here.
        store.putRecord(record.copy(seq = change.seq, hash = null))
        val exists =
            when (change.kind) {
                KIND_NOTE -> key.toLongOrNull()?.let { dao.get(it) } != null
                else -> store.getLabel(key) != null
            }
        if (exists) store.enqueue(change.kind, key)
    }

    private fun remoteIdOf(localId: Long) =
        store.recordByLocal(KIND_NOTE, localId.toString())?.remoteId

    private fun localIdOf(remoteId: String) =
        store.recordByRemote(KIND_NOTE, remoteId)?.localKey?.toLongOrNull()

    private fun canonical(
        note: BaseNote,
        unknown: JSONObject? = remoteIdOf(note.id)?.let(store::getUnknownFields),
    ) = NotePayload.encode(note, ::remoteIdOf, unknown)

    private suspend fun applyNote(item: Incoming, linked: MutableSet<Long>, effects: Effects) {
        val id = item.change.id
        val record = store.recordByRemote(KIND_NOTE, id)
        // This version is known already, e.g. the echo of our own push.
        if (record != null && item.change.seq <= record.seq) return
        val localId = record?.localKey?.toLongOrNull()
        if (localId != null && localId in openNotes) {
            defer(item)
            return
        }
        val local = localId?.let { dao.get(it) }
        val dirty = localId != null && store.isDirty(KIND_NOTE, localId.toString())
        val json = item.json
        val unknown = json?.let(NotePayload::unknownFields)

        if (json == null) {
            when {
                record == null -> Unit
                local == null -> {
                    store.deleteRecord(KIND_NOTE, id)
                    localId?.let { store.clearOutbox(KIND_NOTE, it.toString()) }
                }
                // A local edit wins over a remote deletion: push writes the note again.
                dirty -> store.putRecord(record.copy(seq = item.change.seq))
                else -> {
                    dao.delete(local.id)
                    store.deleteRecord(KIND_NOTE, id)
                    effects.deleted(local)
                }
            }
            return
        }

        if (record == null || local == null) {
            val remote = fitting(NotePayload.decode(json, null, ::localIdOf))
            val adopt = if (record == null) findSameNote(remote, linked) else null
            val targetId =
                if (adopt != null) {
                    val note = remote.copy(id = adopt.id, isPinnedToStatus = adopt.isPinnedToStatus)
                    dao.insert(note)
                    effects.updated(adopt, note)
                    adopt.id
                } else {
                    // New note, or a note deleted here but changed elsewhere (it comes back).
                    localId?.let { store.clearOutbox(KIND_NOTE, it.toString()) }
                    dao.insert(remote.copy(id = 0)).also { effects.inserted(remote.copy(id = it)) }
                }
            store.clearOutbox(KIND_NOTE, targetId.toString())
            linked.add(targetId)
            putNoteRecord(id, targetId, item.change.seq, canonical(remote, unknown), unknown)
            return
        }

        val remote = fitting(NotePayload.decode(json, local, ::localIdOf))
        val remoteJson = canonical(remote, unknown)
        if (!dirty) {
            if (differs(remote, local)) {
                dao.insert(remote)
                effects.updated(local, remote)
            }
            putNoteRecord(id, local.id, item.change.seq, remoteJson, unknown)
            return
        }

        val base = record.fields?.let { JSONObject(it) }
        val merge = NotePayload.merge(base, canonical(local), remoteJson)
        val merged = fitting(NotePayload.decode(merge.merged, local, ::localIdOf))
        if (differs(merged, local)) {
            dao.insert(merged)
            effects.updated(local, merged)
        }
        if (merge.contentConflict) {
            val copy =
                remote.copy(
                    id = 0,
                    title = conflictTitle(remote.title),
                    pinned = false,
                    reminders = emptyList(),
                )
            val copyId = dao.insert(copy)
            store.enqueue(KIND_NOTE, copyId.toString())
            effects.inserted(copy.copy(id = copyId))
        }
        // The remote version is the new merge base; the local result stays in the outbox.
        putNoteRecord(id, local.id, item.change.seq, remoteJson, unknown)
    }

    private fun differs(a: BaseNote, b: BaseNote) =
        a != b || a.modifiedTimestamp != b.modifiedTimestamp

    /** Same limit as [BaseNoteDao.insertSafe]; larger rows cannot be read back on Android. */
    private fun fitting(note: BaseNote): BaseNote {
        if (note.body.length <= MAX_BODY_CHAR_LENGTH) return note
        return note.copy(
            body = note.body.take(MAX_BODY_CHAR_LENGTH),
            spans = note.spans.filter { it.isInsideBounds() },
        )
    }

    private fun putNoteRecord(
        remoteId: String,
        localId: Long,
        seq: Long,
        json: JSONObject,
        unknown: JSONObject?,
    ) {
        store.setUnknownFields(remoteId, unknown)
        store.putRecord(
            SyncStore.Record(
                KIND_NOTE,
                remoteId,
                localId.toString(),
                seq,
                hash(json),
                NotePayload.fieldHashes(json).toString(),
            )
        )
    }

    /**
     * An unsynced local note with the same content and attachments, so that a first sync makes no
     * duplicates. The remote version replaces it, so nothing of it may get lost. A note that is
     * open in the editor is not used: the next save of the editor would overwrite the remote one.
     */
    private fun findSameNote(remote: BaseNote, linked: Set<Long>): BaseNote? {
        val byTitle =
            unlinkedByTitle ?: store.unlinkedNoteIdsByTitle(linked).also { unlinkedByTitle = it }
        return byTitle[remote.title]
            .orEmpty()
            .asSequence()
            .filter { it !in linked && it !in openNotes }
            .mapNotNull { dao.get(it) }
            .firstOrNull {
                it.type == remote.type &&
                    it.title == remote.title &&
                    contentOf(it) == contentOf(remote) &&
                    NotePayload.attachments(it).toSet() == NotePayload.attachments(remote).toSet()
            }
    }

    private fun contentOf(note: BaseNote) =
        (if (note.type == Type.NOTE) note.body else note.items.toText())
            .replace("\r\n", "\n")
            .trim()

    private suspend fun applyLabel(item: Incoming) {
        val id = item.change.id
        val record = store.recordByRemote(KIND_LABEL, id)
        if (record != null && item.change.seq <= record.seq) return
        val json = item.json
        if (json == null) {
            val value = record?.localKey ?: return
            if (store.isDirty(KIND_LABEL, value)) {
                store.putRecord(record.copy(seq = item.change.seq))
            } else {
                labelDao.delete(value)
                store.deleteRecord(KIND_LABEL, id)
            }
            return
        }
        val value = if (json.isNull("value")) return else json.optString("value")
        if (SyncCrypto.labelId(keys.idKey, value) != id) return // id must match the content
        val order = json.optInt("order")
        val exists = store.getLabel(value) != null
        // A local change wins, but a remote change beats a local deletion that is not pushed yet.
        if (!exists || !store.isDirty(KIND_LABEL, value)) {
            val label = Label(value, order)
            if (exists) labelDao.update(label) else labelDao.insert(label)
            store.clearOutbox(KIND_LABEL, value)
        }
        store.putRecord(
            SyncStore.Record(
                KIND_LABEL,
                id,
                value,
                item.change.seq,
                hash(NotePayload.labelJson(value, order)),
                null,
            )
        )
    }

    /** Rewrites links to notes that arrived after the note that links to them. */
    private suspend fun resolveLinks() {
        val ids = store.noteIdsWithLinks()
        if (ids.isEmpty()) return
        database.withTransaction {
            store.paused {
                ids.forEach { id ->
                    val note = dao.get(id) ?: return@forEach
                    if (!NotePayload.hasUnresolvedLinks(note)) return@forEach
                    val fixed = NotePayload.decode(canonical(note), note, ::localIdOf)
                    if (fixed != note) dao.insert(fixed)
                }
            }
        }
    }

    // ---- Attachments ----

    private fun directory(folder: String): File =
        when (folder) {
            SUBFOLDER_IMAGES -> app.getCurrentImagesDirectory()
            SUBFOLDER_FILES -> app.getCurrentFilesDirectory()
            else -> app.getCurrentAudioDirectory()
        }

    /**
     * A blob that the server refuses or that does not open is skipped, not the sync: the next pull
     * tries it again ([downloadMissing]). Network errors stop the sync.
     */
    private fun download(attachments: Collection<Pair<String, String>>) {
        attachments.forEach { (folder, name) ->
            val existing = app.resolveAttachmentFile(folder, name)
            if (existing != null && existing.exists()) return@forEach
            val dir = directory(folder)
            val target = File(dir, name)
            val temp = File(dir, TEMP_PREFIX + name)
            val id = SyncCrypto.blobId(keys.idKey, name)
            try {
                val found =
                    api.getBlob(id) { input ->
                        temp.outputStream().use { out ->
                            SyncCrypto.openStream(
                                keys.encKey,
                                SyncCrypto.ad("blob", id),
                                input,
                                out,
                            )
                        }
                    }
                if (!found) Log.w(TAG, "Attachment not on server yet")
                else if (!temp.renameTo(target)) Log.w(TAG, "Attachment could not be saved")
            } catch (e: java.security.GeneralSecurityException) {
                Log.w(TAG, "Attachment does not open, skipped: ${e.javaClass.simpleName}")
            } catch (e: SyncApi.HttpException) {
                Log.w(TAG, "Attachment download failed: HTTP ${e.code}")
            } finally {
                temp.delete()
            }
        }
    }

    /**
     * Downloads attachments that notes use but that are missing here, for example after a failed
     * download. Only blobs that the server has, at most [MAX_DOWNLOADS] per pull.
     */
    private suspend fun downloadMissing() {
        val dirs = HashMap<String, File>()
        val missing = HashMap<String, Pair<String, String>>()
        referencedAttachments().forEach { attachment ->
            val (folder, name) = attachment
            if (File(dirs.getOrPut(folder) { directory(folder) }, name).exists()) return@forEach
            if (app.resolveAttachmentFile(folder, name)?.exists() == true) return@forEach
            missing[SyncCrypto.blobId(keys.idKey, name)] = attachment
        }
        if (missing.isEmpty()) return
        val notOnServer = missing.keys.chunked(1000).flatMap { api.missingBlobs(it) }.toSet()
        download(missing.filterKeys { it !in notOnServer }.values.take(MAX_DOWNLOADS))
    }

    /** Removes the partial downloads that an interrupted sync left behind. */
    private fun deleteTempFiles() {
        listOf(SUBFOLDER_IMAGES, SUBFOLDER_FILES, SUBFOLDER_AUDIOS).forEach { folder ->
            directory(folder)
                .listFiles { file -> file.name.startsWith(TEMP_PREFIX) }
                ?.forEach { it.delete() }
        }
    }

    private fun upload(notes: Collection<BaseNote>) {
        val files = HashMap<String, File>()
        notes.forEach { note ->
            NotePayload.attachments(note).forEach { (folder, name) ->
                val file = app.resolveAttachmentFile(folder, name)
                if (file != null && file.exists()) files[SyncCrypto.blobId(keys.idKey, name)] = file
            }
        }
        if (files.isEmpty()) return
        val missing = files.keys.chunked(1000).flatMap { api.missingBlobs(it) }
        missing.forEach { id ->
            val file = files.getValue(id)
            val length = file.length()
            try {
                api.putBlob(id, SyncCrypto.sealedSize(length)) { out ->
                    file.inputStream().buffered().use { input ->
                        SyncCrypto.sealStream(
                            keys.encKey,
                            SyncCrypto.ad("blob", id),
                            input,
                            length,
                            out,
                        )
                    }
                }
            } catch (e: SyncApi.HttpException) {
                if (e.code != 413) throw e
                Log.w(TAG, "Attachment is larger than the server allows, not synced")
            }
        }
    }

    private suspend fun referencedAttachments(): Set<Pair<String, String>> {
        val out = HashSet<Pair<String, String>>()
        dao.getAllImages().forEach { json ->
            Converters.jsonToFiles(json).forEach { out.add(SUBFOLDER_IMAGES to it.localName) }
        }
        dao.getAllFiles().forEach { json ->
            Converters.jsonToFiles(json).forEach { out.add(SUBFOLDER_FILES to it.localName) }
        }
        dao.getAllAudios().forEach { json ->
            Converters.jsonToAudios(json).forEach { out.add(SUBFOLDER_AUDIOS to it.name) }
        }
        return out
    }

    // ---- Push ----

    /** @return true if the server reported a conflict and a new pull is needed. */
    suspend fun push(): Boolean {
        val entries = store.outbox()
        if (entries.isEmpty()) return false
        // Give every local note a record id first, so that links between new notes resolve.
        database.withTransaction {
            entries
                .filter { it.kind == KIND_NOTE }
                .forEach { entry ->
                    if (
                        store.recordByLocal(KIND_NOTE, entry.localKey) == null &&
                            entry.localKey.toLongOrNull()?.let { dao.get(it) } != null
                    ) {
                        store.putRecord(
                            SyncStore.Record(
                                KIND_NOTE,
                                SyncCrypto.newRecordId(),
                                entry.localKey,
                                0,
                                null,
                                null,
                            )
                        )
                    }
                }
        }

        val pending = ArrayList<Pending>()
        val notes = ArrayList<BaseNote>()
        entries.forEach { entry ->
            when (entry.kind) {
                KIND_NOTE -> prepareNote(entry, notes)?.let { pending.add(it) }
                KIND_LABEL -> prepareLabel(entry)?.let { pending.add(it) }
                else -> store.removeOutbox(entry)
            }
        }
        upload(notes)

        var conflict = false
        batches(pending).forEach { batch ->
            val results = api.push(batch.map { it.change })
            database.withTransaction {
                results.forEach { result ->
                    val item =
                        batch.firstOrNull {
                            it.change.id == result.id && it.change.kind == result.kind
                        } ?: return@forEach
                    if (result.conflict) {
                        conflict = true
                        return@forEach
                    }
                    if (item.change.deleted) {
                        store.deleteRecord(item.record.kind, item.record.remoteId)
                    } else {
                        store.putRecord(item.record.copy(seq = result.seq, hash = item.hash))
                    }
                    store.removeOutbox(item.entry)
                }
            }
        }
        return conflict
    }

    private fun prepareNote(entry: SyncStore.OutboxEntry, notes: MutableList<BaseNote>): Pending? {
        val note = entry.localKey.toLongOrNull()?.let { dao.get(it) }
        val record = store.recordByLocal(KIND_NOTE, entry.localKey)
        if (record == null) {
            store.removeOutbox(entry)
            return null
        }
        // Wait until the waiting remote change is merged, or the server reports a conflict.
        if (store.getMeta(DEFERRED + record.remoteId) != null) return null
        if (note == null) {
            if (record.seq == 0L) {
                store.deleteRecord(KIND_NOTE, record.remoteId)
                store.removeOutbox(entry)
                return null
            }
            val change =
                SyncApi.OutChange(
                    KIND_NOTE,
                    record.remoteId,
                    record.seq,
                    tombstone(KIND_NOTE, record.remoteId),
                    deleted = true,
                )
            return Pending(entry, change, record, null)
        }
        val json = canonical(note, store.getUnknownFields(record.remoteId))
        val hash = hash(json)
        if (record.seq > 0 && record.hash == hash) {
            store.removeOutbox(entry)
            return null
        }
        notes.add(note)
        val sealed =
            SyncCrypto.seal(
                keys.encKey,
                SyncCrypto.ad(KIND_NOTE, record.remoteId),
                json.toString().toByteArray(),
            )
        val change = SyncApi.OutChange(KIND_NOTE, record.remoteId, record.seq, sealed)
        return Pending(
            entry,
            change,
            record.copy(fields = NotePayload.fieldHashes(json).toString()),
            hash,
        )
    }

    private fun prepareLabel(entry: SyncStore.OutboxEntry): Pending? {
        val value = entry.localKey
        val id = SyncCrypto.labelId(keys.idKey, value)
        val label = store.getLabel(value)
        val record =
            store.recordByRemote(KIND_LABEL, id)
                ?: SyncStore.Record(KIND_LABEL, id, value, 0, null, null)
        if (label == null) {
            if (record.seq == 0L) {
                store.removeOutbox(entry)
                return null
            }
            val change =
                SyncApi.OutChange(
                    KIND_LABEL,
                    id,
                    record.seq,
                    tombstone(KIND_LABEL, id),
                    deleted = true,
                )
            return Pending(entry, change, record, null)
        }
        val json = NotePayload.labelJson(label.value, label.order)
        val hash = hash(json)
        if (record.seq > 0 && record.hash == hash) {
            store.removeOutbox(entry)
            return null
        }
        val sealed =
            SyncCrypto.seal(
                keys.encKey,
                SyncCrypto.ad(KIND_LABEL, id),
                json.toString().toByteArray(),
            )
        return Pending(entry, SyncApi.OutChange(KIND_LABEL, id, record.seq, sealed), record, hash)
    }

    private fun tombstone(kind: String, id: String) =
        SyncCrypto.seal(
            keys.encKey,
            SyncCrypto.ad(kind, id),
            NotePayload.tombstoneJson().toString().toByteArray(),
        )

    private fun batches(pending: List<Pending>): List<List<Pending>> {
        val out = ArrayList<List<Pending>>()
        var current = ArrayList<Pending>()
        var size = 0
        pending.forEach { item ->
            val itemSize = item.change.data.size * 4 / 3 + 200
            if (
                current.isNotEmpty() && (current.size >= 100 || size + itemSize > MAX_BATCH_BYTES)
            ) {
                out.add(current)
                current = ArrayList()
                size = 0
            }
            current.add(item)
            size += itemSize
        }
        if (current.isNotEmpty()) out.add(current)
        return out
    }

    // ---- Server cleanup ----

    /**
     * Deletes blobs that no note references and that are older than one day. Not while remote
     * versions wait (open notes, unreadable records): they can use blobs that no note uses here.
     */
    suspend fun collectGarbage() {
        if (store.outboxSize() > 0) return
        if (store.metaWithPrefix(DEFERRED).isNotEmpty()) return
        if (store.metaWithPrefix(UNREADABLE).isNotEmpty()) return
        val referenced =
            referencedAttachments().map { SyncCrypto.blobId(keys.idKey, it.second) }.toSet()
        val dayAgo = System.currentTimeMillis() / 1000 - 24 * 3600
        api.listBlobs()
            .filter { it.id !in referenced && it.created < dayAgo }
            .forEach { api.deleteBlob(it.id) }
    }

    companion object {
        private const val TAG = "SyncEngine"
        const val META_CURSOR = "cursor"
        private const val DEFERRED = "deferred:"
        private const val UNREADABLE = "unreadable:"
        private const val TEMP_PREFIX = ".sync-"
        private const val MAX_DOWNLOADS = 100
        private const val MAX_BATCH_BYTES = 8 shl 20
        const val CONFLICT_SUFFIX = " (conflict)"

        fun conflictTitle(title: String) =
            if (title.isEmpty()) CONFLICT_SUFFIX.trim() else title + CONFLICT_SUFFIX

        fun hash(json: JSONObject) = SyncCrypto.sha256(json.toString().toByteArray()).toHex()
    }
}
