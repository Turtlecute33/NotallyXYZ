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
import java.net.UnknownHostException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLPeerUnverifiedException
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONException

/** Entry point of end-to-end encrypted sync. One instance per process. */
class SyncManager private constructor(private val app: Application) {

    data class State(val running: Boolean = false, val error: String? = null)

    val state: StateFlow<State>
        get() = mutableState.asStateFlow()

    private val mutableState = MutableStateFlow(State())
    private val scope =
        CoroutineScope(
            SupervisorJob() +
                Dispatchers.IO +
                CoroutineExceptionHandler { _, e ->
                    Log.w(TAG, "Sync task failed: ${e.javaClass.simpleName}")
                }
        )
    private val mutex = Mutex()
    private val openNotes = ConcurrentHashMap<Long, Int>()
    private var scheduled: Job? = null
    /** A sync was requested that must run also without local changes, and has not run yet. */
    @Volatile private var fullSyncPending = false
    private var liveJob: Job? = null
    @Volatile private var foreground = false
    private var observedDatabase: NotallyDatabase? = null

    /** The sync key, read once off the main thread (Keystore). Null until then, "" if none. */
    @Volatile private var key: String? = null

    /**
     * Sync was set up, but the Keystore cannot give the key back. Sync is off until it is entered.
     */
    @Volatile
    var keyUnreadable = false
        private set

    private val preferences
        get() = NotallyXPreferences.getInstance(app)

    val isEnabled: Boolean
        get() = !key.isNullOrEmpty() && preferences.syncServerUrl.value.isNotEmpty()

    private val context: ContextWrapper
        get() = app

    private val observer =
        object : InvalidationTracker.Observer(arrayOf("BaseNote", "Label")) {
            override fun onInvalidated(tables: Set<String>) {
                // Also during a sync: a change made meanwhile must not wait for the next trigger.
                if (isEnabled) requestSync(LOCAL_CHANGE_DELAY_MS, onlyIfDirty = true)
            }
        }

    /** Called once from [Application.onCreate]. */
    fun start() {
        scope.launch {
            loadKey()
            updatePeriodicWork()
            setForeground(foreground)
        }
        scope.launch {
            NotallyDatabase.getDatabase(context).collect { database ->
                observedDatabase?.invalidationTracker?.removeObserver(observer)
                observedDatabase = database
                database?.invalidationTracker?.addObserver(observer)
            }
        }
    }

    /** Reads the key on first use. Call it off the main thread. */
    private fun loadKey(): String {
        key?.let {
            return it
        }
        val value =
            try {
                preferences.syncKey.value
            } catch (e: Exception) {
                // For example a Keystore error. Sync stays off until the key is entered again.
                Log.w(TAG, "Cannot read the sync key: ${e.javaClass.simpleName}")
                keyUnreadable = preferences.syncServerUrl.value.isNotEmpty()
                ""
            }
        key = value
        return value
    }

    @Synchronized
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
        // A new request replaces the waiting one, but does not make it smaller.
        if (!onlyIfDirty) fullSyncPending = true
        scheduled?.cancel()
        scheduled = scope.launch {
            delay(delayMs)
            sync(onlyIfDirty)
        }
    }

    /**
     * @param onlyIfDirty sync only if there are local changes. Checked after a running sync ends.
     * @return true on success.
     */
    suspend fun sync(onlyIfDirty: Boolean = false): Boolean =
        withContext(Dispatchers.IO) {
            if (loadKey().isEmpty() || !isEnabled) return@withContext false
            val database = NotallyDatabase.getDatabase(context).value ?: return@withContext false
            mutex.withLock {
                if (onlyIfDirty && !fullSyncPending && SyncStore(database).outboxSize() == 0) {
                    return@withLock true
                }
                fullSyncPending = false
                // The server can have the push already. Record it also if the caller cancels.
                withContext(NonCancellable) {
                    mutableState.value = State(running = true, error = mutableState.value.error)
                    try {
                        val engine = engine(database)
                        // false: other devices kept writing, local changes wait. Not a success.
                        val consistent = engine.run()
                        val lastGc = SyncStore(database).getMeta(META_GC)?.toLongOrNull() ?: 0L
                        val now = System.currentTimeMillis()
                        if (consistent && now - lastGc > GC_INTERVAL_MS) {
                            engine.collectGarbage()
                            SyncStore(database).setMeta(META_GC, now.toString())
                        }
                        if (consistent) preferences.syncLastSuccess.save(now)
                        mutableState.value = State(error = if (consistent) null else INCOMPLETE)
                        consistent
                    } catch (e: Exception) {
                        // Only the class and the stack: a message can hold note content.
                        Log.w(TAG, "Sync failed: ${e.javaClass.simpleName}")
                        if (e !is IOException) {
                            context.log(
                                TAG,
                                msg = "Sync failed: ${e.javaClass.name}",
                                stackTrace = e.stackTrace.joinToString("\n") { "\tat $it" },
                            )
                        }
                        mutableState.value = State(error = errorCode(e))
                        false
                    }
                }
            }
        }

    private fun engine(database: NotallyDatabase): SyncEngine {
        val keys = SyncCrypto.deriveKeys(requireNotNull(SyncCrypto.parseKey(loadKey())))
        val api = SyncApi(preferences.syncServerUrl.value, keys.bearer)
        return SyncEngine(context, database, api, keys, openNotes.keys)
    }

    /** Long poll while the app is visible, so that changes from other devices show at once. */
    private suspend fun liveUpdates() {
        sync()
        var backoff = 5_000L
        while (currentCoroutineContext().isActive && foreground && isEnabled) {
            try {
                val database = NotallyDatabase.getDatabase(context).value ?: break
                val cursor =
                    SyncStore(database).getMeta(SyncEngine.META_CURSOR)?.toLongOrNull() ?: 0L
                val keys = SyncCrypto.deriveKeys(requireNotNull(SyncCrypto.parseKey(loadKey())))
                val page =
                    SyncApi(preferences.syncServerUrl.value, keys.bearer)
                        .changes(cursor, 1, LIVE_WAIT_S)
                if (page.changes.isNotEmpty() && foreground && !sync()) {
                    throw IOException("sync failed")
                }
                backoff = 5_000L
            } catch (e: Exception) {
                delay(backoff)
                backoff = (backoff * 2).coerceAtMost(5 * 60_000L)
            }
        }
    }

    // ---- Setup ----

    class SetupException(message: String) : Exception(message)

    /** The account exists on the server, but sync could not start. Show [key] to the user. */
    class KeyNotSavedException(val key: String, cause: Exception) : Exception(cause)

    /**
     * Creates an account on the server and returns the new sync key in display form.
     *
     * @throws KeyNotSavedException if the account exists but this device could not save the key.
     */
    suspend fun createAccount(serverUrl: String, invite: String): String =
        withContext(Dispatchers.IO) {
            val url = checkUrl(serverUrl)
            val key = SyncCrypto.newSyncKey()
            val keys = SyncCrypto.deriveKeys(key)
            val api = SyncApi(url, keys.bearer)
            // false: the account exists already, e.g. from a repeated request. Make sure it does.
            if (!api.createAccount(invite.trim())) api.account()
            val display = SyncCrypto.formatKey(key)
            // The server has the account now. Save the key also if the caller cancels.
            try {
                withContext(NonCancellable) { enable(url, display, keys) }
            } catch (e: Exception) {
                throw KeyNotSavedException(display, e)
            }
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
        key = display
        keyUnreadable = false
        updatePeriodicWork()
        setForeground(foreground)
        requestSync()
    }

    /** Stops syncing. Notes on this device stay. */
    suspend fun disconnect() =
        withContext(Dispatchers.IO + NonCancellable) {
            liveJob?.cancel()
            mutex.withLock {
                preferences.syncKey.save("")
                key = ""
                preferences.syncLastSuccess.save(0L)
                NotallyDatabase.getDatabase(context).value?.let { SyncStore(it).resetLinks() }
                mutableState.value = State()
            }
            updatePeriodicWork()
        }

    /** Deletes the account and all data on the server, then disconnects. */
    suspend fun deleteServerData() {
        withContext(Dispatchers.IO + NonCancellable) {
            engineApi().deleteAccount()
            disconnect()
        }
    }

    private fun engineApi(): SyncApi {
        val keys = SyncCrypto.deriveKeys(requireNotNull(SyncCrypto.parseKey(loadKey())))
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

    companion object {
        private const val TAG = "SyncManager"
        const val INCOMPLETE = "incomplete"
        private val SERVER_ERRORS =
            setOf("invalid_invite", "signup_disabled", "accounts_limit", "cursor_ahead")

        /** A short code for [e] that Settings shows as text. Never the message or the class. */
        fun errorCode(e: Throwable): String =
            when (e) {
                is SetupException -> e.message ?: "error"
                is KeyNotSavedException -> e.cause?.let(::errorCode) ?: "error"
                is SyncApi.HttpException ->
                    when (e.code) {
                        in 300..399 -> "redirect"
                        401 -> "unauthorized"
                        429 -> "rate_limited"
                        507 -> "quota_exceeded"
                        else -> e.error?.takeIf { it in SERVER_ERRORS } ?: "http_${e.code}"
                    }
                is UnknownHostException -> "unknown_host"
                is SSLHandshakeException,
                is SSLPeerUnverifiedException -> "tls"
                is IOException -> "offline"
                is JSONException -> "bad_response"
                else -> "error"
            }

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
