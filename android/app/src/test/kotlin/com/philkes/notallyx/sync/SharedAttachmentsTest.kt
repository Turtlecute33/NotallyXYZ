package com.philkes.notallyx.sync

import android.app.Application
import android.content.ContextWrapper
import androidx.test.core.app.ApplicationProvider
import com.philkes.notallyx.data.NotallyDatabase
import com.philkes.notallyx.data.model.BaseNote
import com.philkes.notallyx.data.model.FileAttachment
import com.philkes.notallyx.data.model.Folder
import com.philkes.notallyx.data.model.NoteViewMode
import com.philkes.notallyx.data.model.Type
import com.philkes.notallyx.utils.SUBFOLDER_IMAGES
import com.philkes.notallyx.utils.deleteAttachments
import com.philkes.notallyx.utils.getExternalMediaDirectory
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Conflict copies and duplicated notes share attachment files with the original note. */
@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [35])
class SharedAttachmentsTest {

    /** Other tests close the shared test database: use a new one, and leave none behind. */
    @Before
    @After
    fun newDatabase() {
        NotallyDatabase.clearInstance()
        NotallyDatabase::class
            .java
            .getDeclaredField("testInstance")
            .apply { isAccessible = true }
            .set(null, null)
    }

    @Test
    fun deletingACopyKeepsTheFilesOfTheOriginal() {
        val media = Files.createTempDirectory("nxyz-media").toFile()
        val app =
            object : ContextWrapper(ApplicationProvider.getApplicationContext<Application>()) {
                @Deprecated("Deprecated in Java")
                override fun getExternalMediaDirs() = arrayOf(media)
            }
        val dao = NotallyDatabase.getDatabase(app).value!!.getBaseNoteDao()
        val image = FileAttachment("shared-7d1e.jpg", "a.jpg", "image/jpeg")
        val note =
            BaseNote(
                0,
                Type.NOTE,
                Folder.NOTES,
                BaseNote.COLOR_DEFAULT,
                "Photo",
                false,
                1000L,
                1000L,
                emptyList(),
                "",
                emptyList(),
                emptyList(),
                listOf(image),
                emptyList(),
                emptyList(),
                emptyList(),
                NoteViewMode.EDIT,
                false,
            )
        val original = runBlocking { dao.insert(note) }
        val copy = runBlocking { dao.insert(note) }
        val file = File(app.getExternalMediaDirectory(SUBFOLDER_IMAGES), image.localName)
        file.writeBytes(ByteArray(10))
        try {
            runBlocking { dao.delete(copy) }
            app.deleteAttachments(listOf(image), longArrayOf(copy))
            assertTrue(file.exists())

            // Also when the caller deletes the files before the note rows.
            app.deleteAttachments(listOf(image), longArrayOf(original))
            assertFalse(file.exists())
        } finally {
            runBlocking { dao.delete(longArrayOf(original, copy)) }
            media.deleteRecursively()
        }
    }
}
