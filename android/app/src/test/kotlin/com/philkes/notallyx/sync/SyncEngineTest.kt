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
import com.sun.net.httpserver.HttpServer
import java.io.File
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.URL
import java.nio.file.Files
import kotlin.random.Random
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
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
    private val proxies = ArrayList<HttpServer>()

    inner class Device(val open: MutableSet<Long> = HashSet(), serverUrl: String = url) {
        val db: NotallyDatabase =
            Room.inMemoryDatabaseBuilder(app, NotallyDatabase::class.java)
                .addCallback(SyncStore.callback)
                .allowMainThreadQueries()
                .build()
        val dao = db.getBaseNoteDao()
        val labels = db.getLabelDao()
        val engine = SyncEngine(app, db, SyncApi(serverUrl, keys.bearer), keys, open)

        fun sync() = runBlocking { assertTrue("state not consistent", engine.run()) }

        fun notes() = dao.getAll().sortedBy { it.title }

        fun note(title: String) = notes().single { it.title == title }

        fun insert(note: BaseNote) = runBlocking { dao.insert(note) }
    }

    private fun device(serverUrl: String = url) =
        Device(serverUrl = serverUrl).also { devices.add(it) }

    private fun Device.remoteId(title: String) =
        SyncStore(db).recordByLocal("note", note(title).id.toString())!!.remoteId

    /**
     * A malicious server: passes requests to the real server and lets [rewrite] change the changes
     * of each pull response.
     */
    private fun proxy(rewrite: (JSONObject) -> Unit): String {
        val proxy = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        proxy.createContext("/") { exchange ->
            val conn = URL(url + exchange.requestURI).openConnection() as HttpURLConnection
            conn.requestMethod = exchange.requestMethod
            for (header in listOf("Authorization", "Content-Type")) {
                exchange.requestHeaders.getFirst(header)?.let {
                    conn.setRequestProperty(header, it)
                }
            }
            val request = exchange.requestBody.readBytes()
            if (request.isNotEmpty()) {
                conn.doOutput = true
                conn.outputStream.use { it.write(request) }
            }
            val code = conn.responseCode
            var body =
                (if (code < 400) conn.inputStream else conn.errorStream)?.use { it.readBytes() }
                    ?: ByteArray(0)
            if (exchange.requestURI.path == "/v1/changes" && exchange.requestMethod == "GET") {
                body = JSONObject(body.decodeToString()).also(rewrite).toString().toByteArray()
            }
            exchange.sendResponseHeaders(code, if (body.isEmpty()) -1 else body.size.toLong())
            exchange.responseBody.use { it.write(body) }
        }
        proxy.start()
        proxies.add(proxy)
        return "http://127.0.0.1:${proxy.address.port}"
    }

    private fun JSONObject.forEachChange(block: (JSONObject) -> Unit) {
        val changes = getJSONArray("changes")
        for (i in 0 until changes.length()) block(changes.getJSONObject(i))
    }

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
        proxies.forEach { it.stop(0) }
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
        runBlocking { a.labels.insert(Label("Old", 1)) }
        a.sync()
        b.sync()
        assertEquals(listOf("Old"), runBlocking { b.labels.getArrayOfAll() }.toList())
        runBlocking {
            a.dao.delete(a.note("Gone").id)
            a.dao.delete(a.note("Kept").id)
            a.labels.delete("Old")
            b.dao.insert(b.note("Kept").copy(body = "edited"))
        }
        a.sync()
        b.sync()
        a.sync()
        for (device in listOf(a, b)) {
            assertEquals(listOf("Kept"), device.notes().map { it.title })
            assertEquals("edited", device.note("Kept").body)
            assertEquals(0, runBlocking { device.labels.getArrayOfAll() }.size)
        }
    }

    @Test
    fun deletionsThatDoNotOpenAreNotAppliedAndTheServerIsRepaired() {
        val a = device()
        a.insert(note("Note", "keep me"))
        runBlocking { a.labels.insert(Label("Work", 1)) }
        a.sync()
        // Someone with the bearer token writes deletions whose data does not open.
        val api = SyncApi(url, keys.bearer)
        val seqs = api.changes(0).changes.associate { it.id to it.seq }
        val noteId = a.remoteId("Note")
        val labelId = SyncCrypto.labelId(keys.idKey, "Work")
        api.push(
            listOf(
                SyncApi.OutChange("note", noteId, seqs.getValue(noteId), ByteArray(400), true),
                SyncApi.OutChange("label", labelId, seqs.getValue(labelId), ByteArray(400), true),
            )
        )
        a.sync()
        assertEquals("keep me", a.note("Note").body)
        assertEquals(listOf("Work"), runBlocking { a.labels.getArrayOfAll() }.toList())
        // a wrote both records again, so a new device gets them.
        val b = device()
        b.sync()
        assertEquals("keep me", b.note("Note").body)
        assertEquals(listOf("Work"), runBlocking { b.labels.getArrayOfAll() }.toList())
    }

    @Test
    fun theDeletedFlagWithoutSealedDataIsNotTrusted() {
        val a = device()
        a.insert(note("Deleted", "one"))
        a.insert(note("Changed", "two"))
        a.sync()
        // The server removes the sealed data, so that only its deleted flag remains.
        var strip = false
        val b = device(proxy { page -> if (strip) page.forEachChange { it.remove("data") } })
        b.sync()
        runBlocking {
            a.dao.delete(a.note("Deleted").id)
            a.dao.insert(a.note("Changed").copy(body = "three"))
        }
        a.sync()
        strip = true
        b.sync()
        assertEquals(listOf("Changed", "Deleted"), b.notes().map { it.title })
        assertEquals("two", b.note("Changed").body)
        assertEquals("one", b.note("Deleted").body)
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
