package com.philkes.notallyx.sync

import android.app.Application
import android.content.Context
import android.content.ContextWrapper
import android.util.Log
import androidx.room.InvalidationTracker
import androidx.room.withTransaction
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.philkes.notallyx.BuildConfig
import com.philkes.notallyx.data.NotallyDatabase
import com.philkes.notallyx.presentation.viewmodel.preference.NotallyXPreferences
import com.philkes.notallyx.utils.log
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** Entry point of end-to-end encrypted sync. One instance per process. */
class SyncManager private constructor(private val app: Application) {

    data class State(val running: Boolean = false, val error: String? = null)

    val state: StateFlow<State>
        get() = mutableState.asStateFlow()

    private val mutableState = MutableStateFlow(State())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutex = Mutex()
    private val openNotes = ConcurrentHashMap<Long, Int>()
    private var scheduled: Job? = null
    private var liveJob: Job? = null
    private var foreground = false
    private var observedDatabase: NotallyDatabase? = null

    private val preferences
        get() = NotallyXPreferences.getInstance(app)

    val isEnabled: Boolean
        get() =
            preferences.syncServerUrl.value.isNotEmpty() && preferences.syncKey.value.isNotEmpty()

    private val context: ContextWrapper
        get() = app

    private val observer =
        object : InvalidationTracker.Observer(arrayOf("BaseNote", "Label")) {
            override fun onInvalidated(tables: Set<String>) {
                if (isEnabled && !mutex.isLocked)
                    requestSync(LOCAL_CHANGE_DELAY_MS, onlyIfDirty = true)
            }
        }

    /** Called once from [Application.onCreate]. */
    fun start() {
        scope.launch {
            NotallyDatabase.getDatabase(context).collect { database ->
                observedDatabase?.invalidationTracker?.removeObserver(observer)
                observedDatabase = database
                database?.invalidationTracker?.addObserver(observer)
            }
        }
        updatePeriodicWork()
    }

    fun setForeground(value: Boolean) {
        foreground = value
        if (value && isEnabled) {
            if (liveJob?.isActive != true) liveJob = scope.launch { liveUpdates() }
        } else {
            liveJob?.cancel()
            liveJob = null
        }
    }

    fun noteOpened(id: Long) {
        if (id != 0L) openNotes.merge(id, 1) { a, b -> a + b }
    }

    fun noteClosed(id: Long) {
        if (id == 0L) return
        openNotes.computeIfPresent(id) { _, count -> if (count > 1) count - 1 else null }
        // Also without local changes: remote changes may wait for this note.
        if (isEnabled) requestSync(LOCAL_CHANGE_DELAY_MS)
    }

    fun requestSync(delayMs: Long = 0, onlyIfDirty: Boolean = false) {
        if (!isEnabled) return
        scheduled?.cancel()
        scheduled = scope.launch {
            delay(delayMs)
            if (onlyIfDirty) {
                val database = NotallyDatabase.getDatabase(context).value ?: return@launch
                if (SyncStore(database).outboxSize() == 0) return@launch
            }
            sync()
        }
    }

    /** @return true on success. */
    suspend fun sync(): Boolean =
        withContext(Dispatchers.IO) {
            if (!isEnabled) return@withContext false
            val database = NotallyDatabase.getDatabase(context).value ?: return@withContext false
            mutex.withLock {
                mutableState.value = State(running = true, error = mutableState.value.error)
                try {
                    val engine = engine(database)
                    val consistent = engine.run()
                    val lastGc = SyncStore(database).getMeta(META_GC)?.toLongOrNull() ?: 0L
                    val now = System.currentTimeMillis()
                    if (consistent && now - lastGc > GC_INTERVAL_MS) {
                        engine.collectGarbage()
                        SyncStore(database).setMeta(META_GC, now.toString())
                    }
                    preferences.syncLastSuccess.save(now)
                    mutableState.value = State()
                    true
                } catch (e: Exception) {
                    Log.w(TAG, "Sync failed", e)
                    if (e !is IOException) context.log(TAG, msg = "Sync failed", throwable = e)
                    mutableState.value = State(error = describe(e))
                    false
                }
            }
        }

    private fun engine(database: NotallyDatabase): SyncEngine {
        val keys =
            SyncCrypto.deriveKeys(requireNotNull(SyncCrypto.parseKey(preferences.syncKey.value)))
        val api = SyncApi(preferences.syncServerUrl.value, keys.bearer)
        return SyncEngine(context, database, api, keys, openNotes.keys)
    }

    /** Long poll while the app is visible, so that changes from other devices show at once. */
    private suspend fun liveUpdates() {
        sync()
        var backoff = 5_000L
        while (scope.isActive && foreground && isEnabled) {
            try {
                val database = NotallyDatabase.getDatabase(context).value ?: break
                val cursor =
                    SyncStore(database).getMeta(SyncEngine.META_CURSOR)?.toLongOrNull() ?: 0L
                val keys =
                    SyncCrypto.deriveKeys(
                        requireNotNull(SyncCrypto.parseKey(preferences.syncKey.value))
                    )
                val page =
                    SyncApi(preferences.syncServerUrl.value, keys.bearer)
                        .changes(cursor, 1, LIVE_WAIT_S)
                if (page.changes.isNotEmpty() && foreground) sync()
                backoff = 5_000L
            } catch (e: Exception) {
                delay(backoff)
                backoff = (backoff * 2).coerceAtMost(5 * 60_000L)
            }
        }
    }

    // ---- Setup ----

    class SetupException(message: String) : Exception(message)

    /** Creates an account on the server and returns the new sync key in display form. */
    suspend fun createAccount(serverUrl: String, invite: String): String =
        withContext(Dispatchers.IO) {
            val url = checkUrl(serverUrl)
            val key = SyncCrypto.newSyncKey()
            val keys = SyncCrypto.deriveKeys(key)
            SyncApi(url, keys.bearer).createAccount(invite.trim())
            val display = SyncCrypto.formatKey(key)
            enable(url, display, keys)
            display
        }

    /** Connects to an existing account. */
    suspend fun connect(serverUrl: String, keyText: String) =
        withContext(Dispatchers.IO) {
            val url = checkUrl(serverUrl)
            val key = SyncCrypto.parseKey(keyText) ?: throw SetupException("invalid_key")
            val keys = SyncCrypto.deriveKeys(key)
            SyncApi(url, keys.bearer).account() // 401 if the key has no account here
            enable(url, SyncCrypto.formatKey(key), keys)
        }

    private suspend fun enable(url: String, display: String, keys: SyncCrypto.Keys) {
        val database =
            NotallyDatabase.getDatabase(context).value ?: throw SetupException("database_locked")
        val store = SyncStore(database)
        val account = SyncCrypto.sha256(keys.authToken).copyOf(8).toHex()
        database.withTransaction {
            if (store.getMeta(META_ACCOUNT) != account) {
                store.resetLinks()
                store.setMeta(META_ACCOUNT, account)
            }
            store.enqueueAll()
        }
        preferences.syncServerUrl.save(url)
        preferences.syncKey.save(display)
        updatePeriodicWork()
        setForeground(foreground)
        requestSync()
    }

    /** Stops syncing. Notes on this device stay. */
    suspend fun disconnect() =
        withContext(Dispatchers.IO) {
            liveJob?.cancel()
            mutex.withLock {
                preferences.syncKey.save("")
                preferences.syncLastSuccess.save(0L)
                NotallyDatabase.getDatabase(context).value?.let { SyncStore(it).resetLinks() }
                mutableState.value = State()
            }
            updatePeriodicWork()
        }

    /** Deletes the account and all data on the server, then disconnects. */
    suspend fun deleteServerData() {
        withContext(Dispatchers.IO) { engineApi().deleteAccount() }
        disconnect()
    }

    private fun engineApi(): SyncApi {
        val keys =
            SyncCrypto.deriveKeys(requireNotNull(SyncCrypto.parseKey(preferences.syncKey.value)))
        return SyncApi(preferences.syncServerUrl.value, keys.bearer)
    }

    private fun checkUrl(url: String): String {
        val trimmed = url.trim().trimEnd('/')
        if (!SyncApi.isAllowedUrl(trimmed, allowLocalHttp = BuildConfig.DEBUG)) {
            throw SetupException("invalid_url")
        }
        return trimmed
    }

    private fun updatePeriodicWork() {
        val workManager =
            try {
                WorkManager.getInstance(app)
            } catch (_: Exception) {
                return
            }
        if (isEnabled) {
            val request =
                PeriodicWorkRequestBuilder<SyncWorker>(1, TimeUnit.HOURS)
                    .setConstraints(
                        Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
                    )
                    .build()
            workManager.enqueueUniquePeriodicWork(
                WORK_NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                request,
            )
        } else {
            workManager.cancelUniqueWork(WORK_NAME)
        }
    }

    private fun describe(e: Exception): String =
        when (e) {
            is SyncApi.HttpException ->
                when (e.code) {
                    401 -> "unauthorized"
                    429 -> "rate_limited"
                    507 -> "quota_exceeded"
                    else -> e.error ?: "http_${e.code}"
                }
            is IOException -> "offline"
            else -> e.javaClass.simpleName
        }

    companion object {
        private const val TAG = "SyncManager"
        private const val WORK_NAME = "com.notallyxyz.Sync"
        private const val META_ACCOUNT = "account"
        private const val META_GC = "gc"
        private const val LOCAL_CHANGE_DELAY_MS = 3_000L
        private const val LIVE_WAIT_S = 25
        private const val GC_INTERVAL_MS = 24 * 3600 * 1000L

        @Volatile private var instance: SyncManager? = null

        fun get(context: Context): SyncManager =
            instance
                ?: synchronized(this) {
                    instance
                        ?: SyncManager(context.applicationContext as Application).also {
                            instance = it
                        }
                }
    }
}

class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result =
        if (SyncManager.get(applicationContext).sync()) Result.success() else Result.retry()
}
