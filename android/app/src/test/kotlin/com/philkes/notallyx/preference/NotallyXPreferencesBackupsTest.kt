package com.philkes.notallyx.preference

import android.app.Application
import android.app.Notification
import android.app.NotificationManager
import android.os.Environment
import androidx.core.net.toUri
import androidx.test.core.app.ApplicationProvider
import com.philkes.notallyx.R
import com.philkes.notallyx.data.NotallyDatabase
import com.philkes.notallyx.data.NotallyDatabase.Companion.DATABASE_NAME
import com.philkes.notallyx.data.ShadowContextImplMedia
import com.philkes.notallyx.data.model.BaseNote
import com.philkes.notallyx.data.model.FileAttachment
import com.philkes.notallyx.data.model.Type
import com.philkes.notallyx.presentation.viewmodel.preference.BiometricLock
import com.philkes.notallyx.presentation.viewmodel.preference.Constants.PASSWORD_EMPTY
import com.philkes.notallyx.presentation.viewmodel.preference.NotallyXPreferences
import com.philkes.notallyx.presentation.viewmodel.preference.PeriodicBackup
import com.philkes.notallyx.test.FakeAndroidKeyStore
import com.philkes.notallyx.utils.SUBFOLDER_BACKUPS
import com.philkes.notallyx.utils.SUBFOLDER_IMAGES
import com.philkes.notallyx.utils.backup.ON_SAVE_BACKUP_FILE
import com.philkes.notallyx.utils.backup.autoBackupOnSave
import com.philkes.notallyx.utils.backup.autoBackupOnSaveFileExists
import com.philkes.notallyx.utils.backup.createBackup
import com.philkes.notallyx.utils.backup.deleteModifiedNoteBackup
import com.philkes.notallyx.utils.backup.modifiedNoteBackupExists
import com.philkes.notallyx.utils.getCurrentImagesDirectory
import com.philkes.notallyx.utils.getDocumentFolder
import com.philkes.notallyx.utils.getExternalBackupsDirectory
import java.io.File
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import net.lingala.zip4j.ZipFile
import org.assertj.core.api.Assertions.assertThat
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowEnvironment

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [35], shadows = [ShadowContextImplMedia::class])
class NotallyXPreferencesBackupsTest {

    private lateinit var application: Application
    private lateinit var preferences: NotallyXPreferences

    @Before
    fun setUp() {
        application = ApplicationProvider.getApplicationContext()
        androidx.preference.PreferenceManager.getDefaultSharedPreferences(application)
            .edit()
            .clear()
            .commit()
        NotallyXPreferences.clearInstance()
        preferences = NotallyXPreferences.getInstance(application)
        newDatabase()
        ShadowEnvironment.setExternalStorageState(Environment.MEDIA_MOUNTED)
    }

    @After
    fun tearDown() {
        newDatabase()
        NotallyXPreferences.clearInstance()
    }

    /** Each test closes the shared test database: use a new one, and leave none behind. */
    private fun newDatabase() {
        NotallyDatabase.clearInstance()
        NotallyDatabase::class
            .java
            .getDeclaredField("testInstance")
            .apply { isAccessible = true }
            .set(null, null)
    }

    @Test
    fun defaultPreferences_backupsFolderAndPeriodicBackupsConfiguredCorrectly() {
        val expectedBackupDir = application.getExternalBackupsDirectory()
        val expectedBackupUriString = expectedBackupDir.toUri().toString()

        assertThat(preferences.backupsFolder.value)
            .isEqualTo(expectedBackupUriString)
            .contains(SUBFOLDER_BACKUPS)

        assertThat(preferences.periodicBackups.value)
            .isEqualTo(PeriodicBackup(periodInDays = 1, maxBackups = 3))
    }

    @Test
    fun getDocumentFolder_resolvesDefaultBackupsFolder() {
        val backupUri = preferences.backupsFolder.value.toUri()
        val documentFolder = application.getDocumentFolder(backupUri)

        assertThat(documentFolder).isNotNull
        assertThat(documentFolder!!.exists()).isTrue()
        assertThat(documentFolder.isDirectory).isTrue()
        assertThat(documentFolder.name).isEqualTo(SUBFOLDER_BACKUPS)
    }

    private fun createSampleNote(title: String, body: String): BaseNote =
        BaseNote(
            id = 0,
            type = Type.NOTE,
            folder = com.philkes.notallyx.data.model.Folder.NOTES,
            color = "DEFAULT",
            title = title,
            pinned = false,
            timestamp = System.currentTimeMillis(),
            modifiedTimestamp = System.currentTimeMillis(),
            labels = emptyList(),
            body = body,
            spans = emptyList(),
            items = emptyList(),
            images = emptyList(),
            files = emptyList(),
            audios = emptyList(),
            reminders = emptyList(),
            viewMode = com.philkes.notallyx.data.model.NoteViewMode.EDIT,
            isPinnedToStatus = false,
        )

    @Test
    fun periodicBackupAndAutoBackupOnSave_workWithDefaultBackupsFolder() {
        runBlocking {
            val database =
                NotallyDatabase.getFreshDatabase(application, false, BiometricLock.DISABLED)
            val noteDao = database.getBaseNoteDao()
            noteDao.insert(createSampleNote(title = "Test Note", body = "Test Body"))

            val backupResult = application.createBackup()
            assertThat(backupResult).isNotNull

            val backupsFolderFile = application.getExternalBackupsDirectory()
            val createdFiles =
                backupsFolderFile.listFiles()?.filter { it.name.endsWith(".zip") } ?: emptyList()
            assertThat(createdFiles).isNotEmpty

            val note = noteDao.getAll().first()
            application.autoBackupOnSave(preferences.backupsFolder.value, "", note)

            assertThat(application.autoBackupOnSaveFileExists(preferences.backupsFolder.value))
                .isTrue()
            assertThat(application.modifiedNoteBackupExists(preferences.backupsFolder.value))
                .isTrue()

            application.deleteModifiedNoteBackup(preferences.backupsFolder.value)
            assertThat(application.modifiedNoteBackupExists(preferences.backupsFolder.value))
                .isFalse()

            // A corrupt backup is replaced with a full one (the mutex is not reentrant). The test
            // database is in memory: give the backup a database file to copy.
            NotallyDatabase.getCurrentDatabaseFile(application).apply {
                parentFile?.mkdirs()
                writeText("database")
            }
            val backup = File(backupsFolderFile, "$ON_SAVE_BACKUP_FILE.zip")
            backup.writeText("not a zip")
            withTimeout(30_000) {
                application.autoBackupOnSave(preferences.backupsFolder.value, PASSWORD_EMPTY, note)
            }
            assertThat(ZipFile(backup).isValidZipFile).isTrue()
            assertThat(ZipFile(backup).getFileHeader(DATABASE_NAME)).isNotNull
        }
    }

    @Test
    fun autoBackupOnSave_containsAttachmentsOfOtherNotes() {
        runBlocking {
            val noteDao =
                NotallyDatabase.getFreshDatabase(application, false, BiometricLock.DISABLED)
                    .getBaseNoteDao()
            noteDao.insert(createSampleNote(title = "Saved", body = "Body"))
            val savedNote = noteDao.getAll().first()
            // The test database is in memory: give the backups a database file to copy.
            NotallyDatabase.getCurrentDatabaseFile(application).apply {
                parentFile?.mkdirs()
                writeText("database")
            }
            val backupsFolder = preferences.backupsFolder.value
            application.autoBackupOnSave(backupsFolder, PASSWORD_EMPTY, null)

            // Then another note with an image arrives, for example by sync.
            val image = FileAttachment("other-5b2c.jpg", "other.jpg", "image/jpeg")
            File(application.getCurrentImagesDirectory(), image.localName).writeBytes(ByteArray(10))
            noteDao.insert(
                createSampleNote(title = "Other", body = "").copy(images = listOf(image))
            )

            application.autoBackupOnSave(backupsFolder, PASSWORD_EMPTY, savedNote)

            val backup = File(application.getExternalBackupsDirectory(), "$ON_SAVE_BACKUP_FILE.zip")
            assertThat(ZipFile(backup).getFileHeader("$SUBFOLDER_IMAGES/${image.localName}"))
                .isNotNull
        }
    }

    @Test
    fun automaticBackups_notWrittenWhenDatabaseEncryptedAndNoBackupPassword() {
        FakeAndroidKeyStore.setup
        runBlocking {
            val noteDao =
                NotallyDatabase.getFreshDatabase(application, false, BiometricLock.DISABLED)
                    .getBaseNoteDao()
            noteDao.insert(createSampleNote(title = "Test Note", body = "Test Body"))
            val note = noteDao.getAll().first()
            // The test database is in memory: give the backups a database file to copy.
            NotallyDatabase.getCurrentDatabaseFile(application).apply {
                parentFile?.mkdirs()
                writeText("database")
            }
            val backupsFolder = application.getExternalBackupsDirectory()
            backupsFolder.listFiles()?.forEach { it.delete() }
            fun zips() = backupsFolder.listFiles()?.filter { it.name.endsWith(".zip") }.orEmpty()

            preferences.biometricLock.save(BiometricLock.ENABLED)
            preferences.biometricLockEncryptsDb.save(true)
            assertThat(preferences.backupPassword.value).isEqualTo(PASSWORD_EMPTY)

            application.createBackup()
            application.autoBackupOnSave(
                preferences.backupsFolder.value,
                preferences.backupPassword.value,
                note,
            )
            application.autoBackupOnSave(preferences.backupsFolder.value, "", null)

            assertThat(zips()).isEmpty()
            val notifications =
                shadowOf(application.getSystemService(NotificationManager::class.java))
                    .allNotifications
            assertThat(notifications.map { it.extras.getString(Notification.EXTRA_TITLE) })
                .contains(application.getString(R.string.auto_backup_paused))

            // When encryption is off, the same backups are written again.
            preferences.biometricLockEncryptsDb.save(false)
            application.createBackup()
            application.autoBackupOnSave(
                preferences.backupsFolder.value,
                preferences.backupPassword.value,
                note,
            )
            assertThat(zips()).hasSize(2).allSatisfy {
                assertThat(ZipFile(it).isValidZipFile).isTrue()
            }
        }
    }
}
