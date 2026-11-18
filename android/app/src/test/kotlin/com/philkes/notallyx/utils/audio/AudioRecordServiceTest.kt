package com.philkes.notallyx.utils.audio

import android.app.Application
import android.content.pm.ServiceInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], application = Application::class)
class AudioRecordServiceTest {

    @Test
    fun `a recording runs in the foreground until it stops`() {
        val service = Robolectric.buildService(AudioRecordService::class.java).create().get()
        val shadow = shadowOf(service)
        assertNull(shadow.lastForegroundNotification)

        service.start()
        assertNotNull(shadow.lastForegroundNotification)
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE, service.foregroundServiceType)

        service.pause()
        service.resume()
        assertFalse(shadow.isForegroundStopped)

        service.stop()
        assertTrue(shadow.isForegroundStopped)
        assertTrue(shadow.notificationShouldRemoved)
        assertTrue(shadow.isStoppedBySelf)
    }
}
