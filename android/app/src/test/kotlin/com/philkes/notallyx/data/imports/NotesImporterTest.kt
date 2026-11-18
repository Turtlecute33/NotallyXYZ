package com.philkes.notallyx.data.imports

// TODO: wait for new roboelectric version for API 35
//  see https://github.com/robolectric/robolectric/pull/9680

import android.app.Application
import androidx.core.net.toUri
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.philkes.notallyx.data.NotallyDatabase
import com.philkes.notallyx.data.imports.google.GoogleKeepImporterTest.Companion.createBaseNote
import com.philkes.notallyx.data.model.FileAttachment
import com.philkes.notallyx.utils.decodeToBitmap
import com.philkes.notallyx.utils.getCurrentMediaRoot
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.assertj.core.api.Assertions.assertThat
import org.assertj.core.api.Condition
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class NotesImporterTest {
    private lateinit var application: Application
    private lateinit var database: NotallyDatabase

    @Before
    fun setup() {
        application = ApplicationProvider.getApplicationContext()
        database =
            Room.inMemoryDatabaseBuilder(application, NotallyDatabase::class.java)
                .allowMainThreadQueries()
                .build()
    }

    @Test
    fun `importFiles Google Keep`() {
        testImport(ImportSource.GOOGLE_KEEP, 8)
    }

    @Test
    fun `importFiles Google Keep german Takeout zip`() {
        testImport(
            prepareImportSources(ImportSource.GOOGLE_KEEP, "Takeout_German.zip"),
            ImportSource.GOOGLE_KEEP,
            8,
        )
    }

    @Test
    fun `importFiles Google Keep other Takeout zip`() {
        testImport(
            prepareImportSources(ImportSource.GOOGLE_KEEP, "Takeout_Other.zip"),
            ImportSource.GOOGLE_KEEP,
            8,
        )
    }

    @Test
    fun `importFiles Evernote`() {
        // Evernote does not export archived and deleted notes
        testImport(ImportSource.EVERNOTE, 6)
    }

    @Test
    fun `importFiles Quillpad`() {
        testImport(ImportSource.QUILLPAD, 9)
    }

    @Test
    fun `importFiles Evernote does not write outside the import folder`() {
        val escape = "../../escaped-${System.nanoTime()}.txt"
        val enex =
            Files.createTempFile("traversal", ".enex").toFile().apply {
                writeText(
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <en-export export-date="20241026T102349Z">
                      <note>
                        <title>Traversal</title>
                        <content><![CDATA[<en-note><div>Text</div></en-note>]]></content>
                        <created>20241024T072339Z</created>
                        <updated>20241024T072339Z</updated>
                        <resource>
                          <data encoding="base64">aGVsbG8=</data>
                          <mime>text/plain</mime>
                          <resource-attributes><file-name>$escape</file-name></resource-attributes>
                        </resource>
                      </note>
                    </en-export>
                    """
                        .trimIndent()
                )
            }
        runBlocking {
            NotesImporter(application, database).import(enex.toUri(), ImportSource.EVERNOTE)
        }
        val tempFolder = File(application.cacheDir, "${NotesImporter.IMPORT_CACHE_FOLDER}_x")
        assertThat(File(tempFolder, escape).canonicalFile).doesNotExist()
        val note = database.getBaseNoteDao().getAll().single()
        assertThat(note.body).isEqualTo("Text")
        assertThat(note.files).isEmpty()
    }

    @Test
    fun `import keeps notes that differ only in their attachments`() {
        val enex =
            enexFile(
                enexNote("Scan", "", "a.txt"),
                enexNote("Scan", "", "b.txt"),
                enexNote("Same", "Text", "c.txt"),
                enexNote("Same", "Text", "d.txt"),
            )
        val result = runBlocking {
            NotesImporter(application, database).import(enex.toUri(), ImportSource.EVERNOTE)
        }
        assertThat(result.duplicates).isEqualTo(0)
        val notes = database.getBaseNoteDao().getAll()
        assertThat(notes.map { it.files.single().originalName })
            .containsExactlyInAnyOrder("a.txt", "b.txt", "c.txt", "d.txt")
    }

    @Test
    fun `import still skips a note that is already there`() {
        val enex = enexFile(enexNote("Same", "Text", "a.txt"))
        val importer = NotesImporter(application, database)
        runBlocking { importer.import(enex.toUri(), ImportSource.EVERNOTE) }
        val result = runBlocking { importer.import(enex.toUri(), ImportSource.EVERNOTE) }
        assertThat(result.duplicates).isEqualTo(1)
        assertThat(database.getBaseNoteDao().getAll()).hasSize(1)
    }

    @Test
    fun `backup import with duplicate check keeps notes that differ only in their attachments`() {
        fun note(title: String, body: String, image: String) =
            createBaseNote(
                title = title,
                body = body,
                images = listOf(FileAttachment(image, image, "image/png")),
            )
        val notes = listOf(note("", "", "a.png"), note("", "", "b.png"), note("T", "x", "c.png"))
        runBlocking {
            database.getCommonDao().importBackup(notes, listOf(), 0, checkDuplicates = true)
            val again = database.getCommonDao().importBackup(notes, listOf(), 0, true)
            // Only the note with text is found again; the notes without text are kept.
            assertThat(again.duplicates).isEqualTo(1)
        }
        assertThat(database.getBaseNoteDao().getAll().map { it.images.single().localName })
            .containsExactlyInAnyOrder("a.png", "b.png", "c.png", "a.png", "b.png")
    }

    private fun enexNote(title: String, text: String, fileName: String) =
        """
        <note>
          <title>$title</title>
          <content><![CDATA[<en-note><div>$text</div></en-note>]]></content>
          <created>20241024T072339Z</created>
          <updated>20241024T072339Z</updated>
          <resource>
            <data encoding="base64">aGVsbG8=</data>
            <mime>text/plain</mime>
            <resource-attributes><file-name>$fileName</file-name></resource-attributes>
          </resource>
        </note>
        """

    private fun enexFile(vararg notes: String): File =
        Files.createTempFile("notes", ".enex").toFile().apply {
            writeText(
                """<?xml version="1.0" encoding="UTF-8"?>
                <en-export export-date="20241026T102349Z">${notes.joinToString("")}</en-export>"""
            )
        }

    private fun testImport(importSource: ImportSource, expectedAmountNotes: Int) {
        testImport(prepareImportSources(importSource), importSource, expectedAmountNotes)
    }

    private fun testImport(
        importSourceFile: File,
        importSource: ImportSource,
        expectedAmountNotes: Int,
    ) {
        val importOutputFolder = application.getCurrentMediaRoot()
        runBlocking {
            NotesImporter(application, database).import(importSourceFile.toUri(), importSource)

            val actual = database.getBaseNoteDao().getAll().sortedBy { it.title }
            assertThat(actual).hasSize(expectedAmountNotes)
            actual.forEach { note ->
                note.images.forEach {
                    val imageFile = File(importOutputFolder, "Images/${it.localName}")
                    assertThat(imageFile)
                        .exists()
                        .`is`(
                            Condition(
                                { file ->
                                    val bitmap = file.decodeToBitmap()
                                    bitmap != null && bitmap.width == 1200 && bitmap.height == 1600
                                },
                                "Image",
                            )
                        )
                }
                note.files.forEach {
                    assertThat(File(importOutputFolder, "Files/${it.localName}")).exists()
                }
                note.audios.forEach {
                    val audioFile = File(importOutputFolder, "Audios/${it.name}")
                    assertThat(audioFile).exists()
                    // TODO: Metadata is not properly stored
                    //                        .`is`(
                    //                            Condition(
                    //                                { file ->
                    //                                    val retriever = MediaMetadataRetriever()
                    //
                    // retriever.setDataSource(file.absolutePath)
                    //                                    val hasAudio =
                    //                                        retriever.extractMetadata(
                    //
                    // MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO
                    //                                        )
                    //                                    hasAudio != null
                    //                                },
                    //                                "Audio",
                    //                            )
                    //                        )
                }
            }
        }
    }

    private fun prepareImportSources(importSource: ImportSource, fileName: String? = null): File {
        val tempDir = Files.createTempDirectory("imports-${importSource.name.lowercase()}").toFile()
        copyTestFilesToTempDir("imports/${importSource.name.lowercase()}", tempDir)
        println("Input folder: ${tempDir.absolutePath}")
        if (fileName != null) {
            return File(tempDir, fileName)
        }
        return when (importSource) {
            ImportSource.GOOGLE_KEEP -> File(tempDir, "Takeout.zip")
            ImportSource.EVERNOTE -> File(tempDir, "Notebook.enex")
            ImportSource.PLAIN_TEXT -> File(tempDir, "text.txt")
            ImportSource.JSON -> File(tempDir, "text.json")
            ImportSource.QUILLPAD -> File(tempDir, "quillpad_backup.zip")
        }
    }

    private fun copyTestFilesToTempDir(resourceFolderPath: String, destination: File) {
        val files =
            javaClass.classLoader!!.getResources(resourceFolderPath).toList().flatMap { url ->
                File(url.toURI()).listFiles()?.toList() ?: listOf()
            }
        files
            .filter { !it.isDirectory }
            .forEach { file ->
                val outputFile = File(destination, file.name)
                file.inputStream().use { input ->
                    outputFile.outputStream().use { output -> input.copyTo(output) }
                }
            }
    }
}
