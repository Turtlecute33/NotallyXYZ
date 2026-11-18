package com.philkes.notallyx.utils.audio

import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.MediaRecorder
import android.os.Build
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.getSystemService
import com.philkes.notallyx.R
import com.philkes.notallyx.utils.audio.Status.PAUSED
import com.philkes.notallyx.utils.audio.Status.RECORDING
import com.philkes.notallyx.utils.createChannelIfNotExists
import com.philkes.notallyx.utils.getTempAudioFile
import com.philkes.notallyx.utils.log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

class AudioRecordService : Service() {

    val status: StateFlow<Status>
        field = MutableStateFlow(Status.READY)
    private var lastStart = 0L
    private var audioDuration = 0L

    private lateinit var recorder: MediaRecorder

    override fun onCreate() {
        recorder =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(this)
            } else MediaRecorder()

        recorder.apply {
            setAudioSource(MediaRecorder.AudioSource.MIC)
            setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            setAudioEncoder(MediaRecorder.AudioEncoder.AAC)

            val output = this@AudioRecordService.getTempAudioFile()
            setOutputFile(output.path)
            prepare()
        }
    }

    override fun onDestroy() {
        recorder.release()
    }

    override fun onBind(intent: Intent?) = LocalBinder(this)

    fun start() {
        recorder.start()
        status.value = RECORDING
        lastStart = SystemClock.elapsedRealtime()
        startInForeground()
    }

    fun resume() {
        recorder.resume()
        status.value = RECORDING
        lastStart = SystemClock.elapsedRealtime()
    }

    fun pause() {
        recorder.pause()
        status.value = PAUSED
        audioDuration += SystemClock.elapsedRealtime() - lastStart
        lastStart = 0L
    }

    fun stop() {
        recorder.stop()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    fun getBase(): Long {
        return if (lastStart != 0L) {
            lastStart - audioDuration
        } else SystemClock.elapsedRealtime() - audioDuration
    }

    /**
     * Android gives silence to an app in the background that uses the microphone, unless a
     * foreground service of type microphone runs. The notification shows that the recording goes on
     * until the user stops it.
     */
    private fun startInForeground() {
        val manager = getSystemService<NotificationManager>() ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createChannelIfNotExists(
                NOTIFICATION_CHANNEL_ID,
                NotificationManager.IMPORTANCE_LOW,
            )
        }
        val openApp =
            packageManager.getLaunchIntentForPackage(packageName)?.let {
                PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE)
            }
        val notification =
            NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
                .setSmallIcon(R.drawable.record_audio)
                .setContentTitle(getString(R.string.recording))
                .setContentIntent(openApp)
                .setOngoing(true)
                .setSilent(true)
                .build()
        val type =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            } else 0
        try {
            ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, type)
        } catch (e: Exception) {
            // The recording goes on as before: only while the app is open.
            log(TAG, throwable = e)
        }
    }

    companion object {
        private const val TAG = "AudioRecordService"
        private const val NOTIFICATION_CHANNEL_ID = "Recording"
        private const val NOTIFICATION_ID = 123420
    }
}
