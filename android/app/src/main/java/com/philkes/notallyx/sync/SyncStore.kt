package com.philkes.notallyx.sync

import androidx.room.RoomDatabase
import androidx.sqlite.db.SupportSQLiteDatabase
import com.philkes.notallyx.data.NotallyDatabase
import com.philkes.notallyx.data.model.Label

/**
 * Sync bookkeeping, stored in the notes database but unknown to Room, so that the Room schema stays
 * the same as upstream NotallyX.
 *
 * Triggers put every changed note and label into [OUTBOX]. This catches all write paths of the app
 * (editor, list actions, imports, label renames) without changes to the DAOs. While the sync engine
 * writes remote changes, a row in [PAUSE] disables the triggers.
 */
class SyncStore(private val database: NotallyDatabase) {

    private val db: SupportSQLiteDatabase
        get() = database.openHelper.writableDatabase

    class OutboxEntry(val kind: String, val localKey: String, val ver: Long)

    /**
     * @param localKey note id or label value; null if the record has no local counterpart.
     * @param fields hashes of the fields at the last synced version, for 3-way merges.
     */
    data class Record(
        val kind: String,
        val remoteId: String,
        val localKey: String?,
        val seq: Long,
        val hash: String?,
        val fields: String?,
    )

    fun getMeta(key: String): String? =
        db.query("SELECT value FROM $META WHERE key = ?", arrayOf(key)).use {
            if (it.moveToFirst()) it.getString(0) else null
        }

    fun setMeta(key: String, value: String?) {
        if (value == null) {
            db.execSQL("DELETE FROM $META WHERE key = ?", arrayOf(key))
        } else {
            db.execSQL(
                "INSERT OR REPLACE INTO $META(key, value) VALUES (?, ?)",
                arrayOf(key, value),
            )
        }
    }

    fun metaWithPrefix(prefix: String): List<Pair<String, String>> =
        db.query("SELECT key, value FROM $META WHERE key LIKE ? || '%'", arrayOf(prefix)).use { c ->
            buildList { while (c.moveToNext()) add(c.getString(0) to c.getString(1)) }
        }

    fun outbox(): List<OutboxEntry> =
        db.query("SELECT kind, localKey, ver FROM $OUTBOX ORDER BY ver").use { c ->
            buildList {
                while (c.moveToNext()) add(
                    OutboxEntry(c.getString(0), c.getString(1), c.getLong(2))
                )
            }
        }

    fun outboxSize(): Int =
        db.query("SELECT COUNT(*) FROM $OUTBOX").use { if (it.moveToFirst()) it.getInt(0) else 0 }

    fun isDirty(kind: String, localKey: String): Boolean =
        db.query("SELECT 1 FROM $OUTBOX WHERE kind = ? AND localKey = ?", arrayOf(kind, localKey))
            .use { it.moveToFirst() }

    /** Removes the entry only if it was not changed again since it was read. */
    fun removeOutbox(entry: OutboxEntry) {
        db.execSQL(
            "DELETE FROM $OUTBOX WHERE kind = ? AND localKey = ? AND ver = ?",
            arrayOf<Any?>(entry.kind, entry.localKey, entry.ver),
        )
    }

    fun clearOutbox(kind: String, localKey: String) {
        db.execSQL("DELETE FROM $OUTBOX WHERE kind = ? AND localKey = ?", arrayOf(kind, localKey))
    }

    fun enqueue(kind: String, localKey: String) {
        db.execSQL(
            "INSERT OR REPLACE INTO $OUTBOX(kind, localKey, ver) VALUES (?, ?, $NEXT_VER)",
            arrayOf(kind, localKey),
        )
    }

    /** Puts all notes and labels into the outbox, e.g. when sync is enabled. */
    fun enqueueAll() {
        db.execSQL(
            "INSERT OR REPLACE INTO $OUTBOX(kind, localKey, ver) " +
                "SELECT 'note', id, $NEXT_VER FROM BaseNote"
        )
        db.execSQL(
            "INSERT OR REPLACE INTO $OUTBOX(kind, localKey, ver) " +
                "SELECT 'label', value, $NEXT_VER FROM Label"
        )
    }

    private fun readRecord(where: String, args: Array<Any?>): Record? =
        db.query(
                "SELECT kind, remoteId, localKey, seq, hash, fields FROM $RECORD WHERE $where",
                args,
            )
            .use { c ->
                if (!c.moveToFirst()) null
                else
                    Record(
                        c.getString(0),
                        c.getString(1),
                        c.getString(2),
                        c.getLong(3),
                        c.getString(4),
                        c.getString(5),
                    )
            }

    fun recordByRemote(kind: String, remoteId: String) =
        readRecord("kind = ? AND remoteId = ?", arrayOf(kind, remoteId))

    fun recordByLocal(kind: String, localKey: String) =
        readRecord("kind = ? AND localKey = ?", arrayOf(kind, localKey))

    fun putRecord(record: Record) {
        db.execSQL(
            "INSERT OR REPLACE INTO $RECORD(kind, remoteId, localKey, seq, hash, fields) " +
                "VALUES (?, ?, ?, ?, ?, ?)",
            arrayOf<Any?>(
                record.kind,
                record.remoteId,
                record.localKey,
                record.seq,
                record.hash,
                record.fields,
            ),
        )
    }

    fun deleteRecord(kind: String, remoteId: String) {
        db.execSQL("DELETE FROM $RECORD WHERE kind = ? AND remoteId = ?", arrayOf(kind, remoteId))
    }

    /** Local note ids that are already linked to a remote record. */
    fun linkedNoteIds(): Set<Long> =
        db.query("SELECT localKey FROM $RECORD WHERE kind = 'note' AND localKey IS NOT NULL").use {
            c ->
            buildSet { while (c.moveToNext()) c.getString(0).toLongOrNull()?.let { add(it) } }
        }

    fun noteIdsWithLinks(): List<Long> =
        // org.json writes "/" as "\/", so match only the scheme.
        db.query("SELECT id FROM BaseNote WHERE spans LIKE '%note:%'").use { c ->
            buildList { while (c.moveToNext()) add(c.getLong(0)) }
        }

    fun getLabel(value: String): Label? =
        db.query("SELECT value, `order` FROM Label WHERE value = ?", arrayOf(value)).use {
            if (it.moveToFirst()) Label(it.getString(0), it.getInt(1)) else null
        }

    /** Forgets all links to the server, e.g. when the account changes. Notes stay. */
    fun resetLinks() {
        db.execSQL("DELETE FROM $RECORD")
        db.execSQL("DELETE FROM $META")
    }

    /** Runs [block] with the triggers disabled. Call it inside a database transaction. */
    inline fun <T> paused(block: () -> T): T {
        pause(true)
        try {
            return block()
        } finally {
            pause(false)
        }
    }

    fun pause(paused: Boolean) {
        if (paused) db.execSQL("INSERT OR IGNORE INTO $PAUSE(id) VALUES (1)")
        else db.execSQL("DELETE FROM $PAUSE")
    }

    companion object {
        const val OUTBOX = "SyncOutbox"
        const val RECORD = "SyncRecord"
        const val META = "SyncMeta"
        const val PAUSE = "SyncPause"
        const val KIND_NOTE = "note"
        const val KIND_LABEL = "label"

        private const val NEXT_VER = "(SELECT IFNULL(MAX(ver), 0) + 1 FROM $OUTBOX)"
        private const val ACTIVE = "WHEN NOT EXISTS (SELECT 1 FROM $PAUSE)"

        private fun enqueueSql(kind: String, key: String) =
            "INSERT OR REPLACE INTO $OUTBOX(kind, localKey, ver) VALUES ('$kind', $key, $NEXT_VER);"

        /** Creates the tables and triggers. Safe to run on every open. */
        fun create(db: SupportSQLiteDatabase) {
            db.execSQL(
                "CREATE TABLE IF NOT EXISTS $OUTBOX (kind TEXT NOT NULL, localKey TEXT NOT NULL, " +
                    "ver INTEGER NOT NULL, PRIMARY KEY(kind, localKey))"
            )
            db.execSQL(
                "CREATE TABLE IF NOT EXISTS $RECORD (kind TEXT NOT NULL, remoteId TEXT NOT NULL, " +
                    "localKey TEXT, seq INTEGER NOT NULL, hash TEXT, fields TEXT, " +
                    "PRIMARY KEY(kind, remoteId))"
            )
            db.execSQL("CREATE INDEX IF NOT EXISTS ${RECORD}Local ON $RECORD(kind, localKey)")
            db.execSQL(
                "CREATE TABLE IF NOT EXISTS $META (key TEXT PRIMARY KEY NOT NULL, value TEXT)"
            )
            db.execSQL("CREATE TABLE IF NOT EXISTS $PAUSE (id INTEGER PRIMARY KEY)")
            // A crash cannot leave a pause behind (it is written in a transaction), but be safe.
            db.execSQL("DELETE FROM $PAUSE")
            val triggers =
                mapOf(
                    "SyncNoteInsert" to "AFTER INSERT ON BaseNote" to enqueueSql("note", "NEW.id"),
                    "SyncNoteUpdate" to "AFTER UPDATE ON BaseNote" to enqueueSql("note", "NEW.id"),
                    "SyncNoteDelete" to "AFTER DELETE ON BaseNote" to enqueueSql("note", "OLD.id"),
                    "SyncLabelInsert" to
                        "AFTER INSERT ON Label" to
                        enqueueSql("label", "NEW.value"),
                    "SyncLabelUpdate" to
                        "AFTER UPDATE ON Label" to
                        (enqueueSql("label", "OLD.value") + enqueueSql("label", "NEW.value")),
                    "SyncLabelDelete" to
                        "AFTER DELETE ON Label" to
                        enqueueSql("label", "OLD.value"),
                )
            triggers.forEach { (nameAndEvent, body) ->
                val (name, event) = nameAndEvent
                db.execSQL("CREATE TRIGGER IF NOT EXISTS $name $event $ACTIVE BEGIN $body END")
            }
        }

        val callback =
            object : RoomDatabase.Callback() {
                override fun onOpen(db: SupportSQLiteDatabase) {
                    create(db)
                }
            }
    }
}
