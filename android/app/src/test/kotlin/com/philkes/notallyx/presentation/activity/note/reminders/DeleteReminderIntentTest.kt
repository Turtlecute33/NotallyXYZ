package com.philkes.notallyx.presentation.activity.note.reminders

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.philkes.notallyx.presentation.activity.note.reminders.ReminderReceiver.Companion.EXTRA_NOTE_ID
import com.philkes.notallyx.presentation.activity.note.reminders.ReminderReceiver.Companion.EXTRA_REMINDER_ID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], application = Application::class)
class DeleteReminderIntentTest {

    @Test
    fun `dismiss intents of different reminders stay separate`() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        // "878232-2".hashCode() == "738382-67".hashCode()
        val first = context.createDeleteReminderIntent(878232, 2)!!
        val second = context.createDeleteReminderIntent(738382, 67)!!

        assertNotEquals(first, second)
        val firstIntent = shadowOf(first).savedIntent
        assertEquals(878232L, firstIntent.getLongExtra(EXTRA_NOTE_ID, -1))
        assertEquals(2L, firstIntent.getLongExtra(EXTRA_REMINDER_ID, -1))
    }
}
