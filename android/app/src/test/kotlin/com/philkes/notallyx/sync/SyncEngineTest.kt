package com.philkes.notallyx.sync

import android.app.Application
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.philkes.notallyx.data.NotallyDatabase
import com.philkes.notallyx.data.model.BaseNote
import com.philkes.notallyx.data.model.FileAttachment
import com.philkes.notallyx.data.model.Folder
import com.philkes.notallyx.data.model.Label
import com.philkes.notallyx.data.model.ListItem
import com.philkes.notallyx.data.model.NoteViewMode
import com.philkes.notallyx.data.model.SpanRepresentation
import com.philkes.notallyx.data.model.Type
import com.philkes.notallyx.data.model.createNoteUrl
import com.philkes.notallyx.utils.getCurrentImagesDirectory
import java.io.File
import java.net.HttpURLConnection
import java.net.ServerSocket
import java.net.URL
import java.nio.file.Files
import kotlin.random.Random
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * End-to-end tests against the real server binary. Build it with `go build -o
 * /tmp/nxyz-android-test-server .` in the server repository (or set NXYZ_SERVER_BIN). The tests are
 * skipped if the binary is missing.
 */
@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [35])
class SyncEngineTest {

    private lateinit var app: Application
    private lateinit var server: Process
    private lateinit var dataDir: File
    private lateinit var url: String
    private lateinit var keys: SyncCrypto.Keys
    private val devices = ArrayList<Device>()

    inner class Device(val open: MutableSet<Long> = HashSet()) {
        val db: NotallyDatabase =
            Room.inMemoryDatabaseBuilder(app, NotallyDatabase::class.java)
                .addCallback(SyncStore.callback)
                .allowMainThreadQueries()
                .build()
        val dao = db.getBaseNoteDao()
        val labels = db.getLabelDao()
        val engine = SyncEngine(app, db, SyncApi(url, keys.bearer), keys, open)

        fun sync() = runBlocking { assertTrue("state not consistent", engine.run()) }

        fun notes() = dao.getAll().sortedBy { it.title }

        fun note(title: String) = notes().single { it.title == title }

        fun insert(note: BaseNote) = runBlocking { dao.insert(note) }
    }

    private fun device() = Device().also { devices.add(it) }

    private fun note(
        title: String,
        body: String = "",
        type: Type = Type.NOTE,
        items: List<ListItem> = emptyList(),
        spans: List<SpanRepresentation> = emptyList(),
        images: List<FileAttachment> = emptyList(),
    ) =
        BaseNote(
            0,
            type,
            Folder.NOTES,
            BaseNote.COLOR_DEFAULT,
            title,
            false,
            1000L,
            1000L,
            emptyList(),
            body,
            spans,
            items,
            images,
            emptyList(),
            emptyList(),
            emptyList(),
            NoteViewMode.EDIT,
            false,
        )

    @Before
    fun setUp() {
        val bin = File(System.getenv("NXYZ_SERVER_BIN") ?: "/tmp/nxyz-android-test-server")
        assumeTrue("server binary missing: $bin", bin.canExecute())
        app = ApplicationProvider.getApplicationContext()
        dataDir = Files.createTempDirectory("nxyz-test").toFile()
        val port = ServerSocket(0).use { it.localPort }
        url = "http://127.0.0.1:$port"
        server =
            ProcessBuilder(bin.path)
                .apply {
                    environment()["DATA_DIR"] = dataDir.path
                    environment()["LISTEN_ADDR"] = "127.0.0.1:$port"
                    environment()["SIGNUP_TOKEN"] = INVITE
                    environment()["MAX_BLOB_MB"] = "5"
                }
                .redirectErrorStream(true)
                .redirectOutput(File(dataDir, "server.log"))
                .start()
        repeat(100) {
            val up =
                try {
                    (URL("$url/v1/health").openConnection() as HttpURLConnection).responseCode ==
                        200
                } catch (_: Exception) {
                    false
                }
            if (up) return@repeat
            Thread.sleep(50)
        }
        keys = SyncCrypto.deriveKeys(SyncCrypto.newSyncKey())
        assertTrue(SyncApi(url, keys.bearer).createAccount(INVITE))
    }

    @After
    fun tearDown() {
        if (!::server.isInitialized) return
        devices.forEach { it.db.close() }
        server.destroy()
        server.waitFor()
        dataDir.deleteRecursively()
        app.getCurrentImagesDirectory().deleteRecursively()
    }

    @Test
    fun notesLabelsListsAndLinksReachTheOtherDevice() {
        val a = device()
        val target = a.insert(note("Target", "first"))
        val linkSpan =
            SpanRepresentation(0, 3, link = true, linkData = target.createNoteUrl(Type.NOTE))
        a.insert(
            note(
                "Linker",
                "see this",
                spans = listOf(linkSpan, SpanRepresentation(4, 8, bold = true)),
            )
        )
        // Change the target again so that it arrives after the note that links to it.
        runBlocking { a.dao.insert(a.note("Target").copy(body = "second")) }
        a.insert(
            note(
                "List",
                type = Type.LIST,
                items =
                    listOf(
                        ListItem("one", false, false, 0, mutableListOf()),
                        ListItem("child", true, true, 1, mutableListOf(), checkedTimestamp = 5L),
                    ),
            )
        )
        runBlocking { a.labels.insert(Label("Work", 3)) }
        a.sync()

        val b = device()
        b.sync()
        assertEquals(listOf("Linker", "List", "Target"), b.notes().map { it.title })
        assertEquals("second", b.note("Target").body)
        val link = b.note("Linker").spans.single { it.link }
        assertEquals(b.note("Target").id.createNoteUrl(Type.NOTE), link.linkData)
        assertTrue(b.note("Linker").spans.any { it.bold && it.start == 4 && it.end == 8 })
        assertEquals(a.note("List").items, b.note("List").items)
        assertEquals(listOf("Work"), runBlocking { b.labels.getArrayOfAll() }.toList())
        assertEquals(0, SyncStore(b.db).outboxSize())
    }

    @Test
    fun changesToDifferentFieldsMerge() {
        val a = device()
        a.insert(note("Note", "text"))
        a.sync()
        val b = device()
        b.sync()
        runBlocking {
            a.dao.updateColor(longArrayOf(a.note("Note").id), "#FAAFA9")
            b.dao.updateLabels(b.note("Note").id, listOf("X"))
        }
        a.sync()
        b.sync()
        a.sync()
        for (device in listOf(a, b)) {
            val n = device.notes().single()
            assertEquals("#FAAFA9", n.color)
            assertEquals(listOf("X"), n.labels)
        }
    }

    @Test
    fun conflictingContentKeepsBothVersions() {
        val a = device()
        a.insert(note("Note", "base"))
        a.sync()
        val b = device()
        b.sync()
        runBlocking {
            a.dao.insert(a.note("Note").copy(body = "from a"))
            b.dao.insert(b.note("Note").copy(body = "from b"))
        }
        a.sync()
        b.sync()
        a.sync()
        for (device in listOf(a, b)) {
            assertEquals(listOf("Note", "Note (conflict)"), device.notes().map { it.title })
            assertEquals("from b", device.note("Note").body)
            assertEquals("from a", device.note("Note (conflict)").body)
        }
    }

    @Test
    fun deletionsPropagateButLoseAgainstEdits() {
        val a = device()
        a.insert(note("Gone", "x"))
        a.insert(note("Kept", "x"))
        a.sync()
        val b = device()
        b.sync()
        runBlocking {
            a.dao.delete(a.note("Gone").id)
            a.dao.delete(a.note("Kept").id)
            b.dao.insert(b.note("Kept").copy(body = "edited"))
        }
        a.sync()
        b.sync()
        a.sync()
        for (device in listOf(a, b)) {
            assertEquals(listOf("Kept"), device.notes().map { it.title })
            assertEquals("edited", device.note("Kept").body)
        }
    }

    @Test
    fun attachmentsAreTransferred() {
        val a = device()
        val bytes = Random.nextBytes(150_000)
        val file = File(app.getCurrentImagesDirectory(), "4f1c.jpg")
        file.writeBytes(bytes)
        a.insert(note("Photo", images = listOf(FileAttachment("4f1c.jpg", "me.jpg", "image/jpeg"))))
        a.sync()
        file.delete()
        val b = device()
        b.sync()
        assertArrayEquals(bytes, file.readBytes())
        assertEquals("me.jpg", b.note("Photo").images.single().originalName)
    }

    @Test
    fun firstSyncAdoptsIdenticalNotes() {
        val a = device()
        a.insert(note("Same", "body"))
        a.sync()
        val c = device()
        c.insert(note("Same", "body"))
        c.insert(note("Own", "only here"))
        c.sync()
        assertEquals(listOf("Own", "Same"), c.notes().map { it.title })
        a.sync()
        assertEquals(listOf("Own", "Same"), a.notes().map { it.title })
    }

    @Test
    fun undecryptableRecordsAreSkipped() {
        val api = SyncApi(url, keys.bearer)
        api.push(listOf(SyncApi.OutChange("note", SyncCrypto.newRecordId(), 0, ByteArray(400))))
        val b = device()
        b.sync()
        assertEquals(0, b.notes().size)
    }

    @Test
    fun remoteChangesWaitWhileTheNoteIsOpen() {
        val a = device()
        a.insert(note("Note", "base"))
        a.sync()
        val b = device()
        b.sync()
        val id = b.note("Note").id

        // Only read on b: the remote edit is applied when the editor closes.
        b.open.add(id)
        runBlocking { a.dao.insert(a.note("Note").copy(body = "remote 1")) }
        a.sync()
        b.sync()
        assertEquals("base", b.note("Note").body)
        b.open.clear()
        b.sync()
        assertEquals("remote 1", b.note("Note").body)

        // Edited on b while open: both versions survive.
        b.open.add(id)
        runBlocking { a.dao.insert(a.note("Note").copy(body = "remote 2")) }
        a.sync()
        b.sync()
        runBlocking { b.dao.insert(b.note("Note").copy(body = "local 2")) }
        b.sync()
        b.open.clear()
        b.sync()
        a.sync()
        for (device in listOf(a, b)) {
            assertEquals(listOf("Note", "Note (conflict)"), device.notes().map { it.title })
            assertEquals("local 2", device.note("Note").body)
            assertEquals("remote 2", device.note("Note (conflict)").body)
        }
    }

    @Test
    fun explicitNullsMeanMissing() {
        val json =
            org.json.JSONObject(
                """{"v":1,"type":"NOTE","title":"N","body":"abc","timestamp":5,
                "spans":[{"start":0,"end":1,"bold":true,"link":false,"linkData":null}],
                "items":[{"body":"x","checked":false,"isChild":false,"order":null,"checkedTimestamp":null}],
                "reminders":[{"id":0,"dateTime":1000,"repetition":null}],"color":null}"""
            )
        val note = NotePayload.decode(json, null) { null }
        assertEquals(null, note.spans.single().linkData)
        assertEquals(null, note.items.single().order)
        assertEquals(null, note.reminders.single().repetition)
        assertEquals(BaseNote.COLOR_DEFAULT, note.color)
    }

    companion object {
        private const val INVITE = "android-test-invite-0123456789"
    }
}
