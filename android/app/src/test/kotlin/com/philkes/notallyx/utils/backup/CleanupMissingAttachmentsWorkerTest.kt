package com.philkes.notallyx.utils.backup

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import androidx.work.ListenableWorker
import com.philkes.notallyx.data.NotallyDatabase
import com.philkes.notallyx.data.model.BaseNote
import com.philkes.notallyx.data.model.FileAttachment
import com.philkes.notallyx.data.model.Folder
import com.philkes.notallyx.data.model.NoteViewMode
import com.philkes.notallyx.data.model.Type
import com.philkes.notallyx.presentation.viewmodel.preference.NotallyXPreferences
import com.philkes.notallyx.test.FakeAndroidKeyStore
import io.mockk.mockk
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** With sync, a file that is missing here can still arrive: the clean-up must not remove it. */
@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [35])
class CleanupMissingAttachmentsWorkerTest {

    private lateinit var app: Application

    @Before
    fun setUp() {
        app = ApplicationProvider.getApplicationContext()
        FakeAndroidKeyStore.setup
        reset()
    }

    @After
    fun tearDown() {
        reset()
    }

    /** Other tests close the shared test database: use a new one, and leave none behind. */
    private fun reset() {
        NotallyDatabase.clearInstance()
        NotallyDatabase::class
            .java
            .getDeclaredField("testInstance")
            .apply { isAccessible = true }
            .set(null, null)
        NotallyXPreferences.clearInstance()
    }

    @Test
    fun withSyncSetUp_keepsReferencesToMissingFiles() {
        val preferences = NotallyXPreferences.getInstance(app)
        preferences.syncServerUrl.save("https://sync.example.com")
        preferences.syncKey.save("sync-key")
        val id = insertNoteWithMissingImage()

        assertEquals(ListenableWorker.Result.success(), runWorker())

        assertEquals(1, imagesOf(id).size)
    }

    @Test
    fun withoutSync_removesReferencesToMissingFiles() {
        val id = insertNoteWithMissingImage()

        assertEquals(ListenableWorker.Result.success(), runWorker())

        assertEquals(0, imagesOf(id).size)
    }

    private fun runWorker() = runBlocking {
        CleanupMissingAttachmentsWorker(app, mockk(relaxed = true)).doWork()
    }

    private fun imagesOf(id: Long) = runBlocking {
        NotallyDatabase.getDatabase(app).value!!.getBaseNoteDao().get(id)!!.images
    }

    private fun insertNoteWithMissingImage(): Long {
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
                listOf(FileAttachment("missing-4e1a.jpg", "a.jpg", "image/jpeg")),
                emptyList(),
                emptyList(),
                emptyList(),
                NoteViewMode.EDIT,
                false,
            )
        return runBlocking {
            NotallyDatabase.getDatabase(app).value!!.getBaseNoteDao().insert(note)
        }
    }
}
