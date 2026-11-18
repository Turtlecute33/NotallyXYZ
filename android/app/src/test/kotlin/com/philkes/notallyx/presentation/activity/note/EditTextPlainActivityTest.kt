package com.philkes.notallyx.presentation.activity.note

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Looper.getMainLooper
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.philkes.notallyx.R
import com.philkes.notallyx.data.ShadowContextImplMedia
import com.philkes.notallyx.test.FakeAndroidKeyStore
import com.philkes.notallyx.test.context
import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ActivityController
import org.robolectric.annotation.Config
import org.robolectric.annotation.SQLiteMode

@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], shadows = [ShadowContextImplMedia::class])
@SQLiteMode(SQLiteMode.Mode.NATIVE)
class EditTextPlainActivityTest {

    private val fileA = Uri.parse("content://com.example.files/a.txt")
    private val fileB = Uri.parse("content://com.example.files/b.txt")
    private val intent =
        Intent(context, EditTextPlainActivity::class.java)
            .setAction(Intent.ACTION_VIEW)
            .setData(fileA)

    @Test
    fun `Save As target stays after rotation`() {
        val controller = openFileA()
        saveAsFileB(controller.get())

        controller.recreate()
        idleUntilLoaded(controller.get())

        assertEquals(fileB, controller.get().originalFileUri.value)
    }

    @Test
    fun `Save As target and unsaved text stay after the app was stopped`() {
        val controller = openFileA()
        saveAsFileB(controller.get())
        // Typed text, not setText: setText does not reach the note model.
        controller.get().binding.EnterBody.editableText.replace(0, "Text of A".length, "Changed")
        shadowOf(getMainLooper()).idle()
        val state = Bundle()
        controller.pause().saveInstanceState(state).stop()

        // A new activity without the old ViewModel, as after Android stopped the app.
        val restored = Robolectric.buildActivity(EditTextPlainActivity::class.java, intent)
        restored.setup(state)
        idleUntilLoaded(restored.get())

        assertEquals(fileB, restored.get().originalFileUri.value)
        assertEquals("Changed", restored.get().binding.EnterBody.text.toString())
    }

    private fun openFileA(): ActivityController<EditTextPlainActivity> {
        shadowOf(context.contentResolver).registerInputStreamSupplier(fileA) {
            "Text of A".byteInputStream()
        }
        shadowOf(context.contentResolver).registerOutputStream(fileB, ByteArrayOutputStream())
        val controller = Robolectric.buildActivity(EditTextPlainActivity::class.java, intent)
        controller.setup()
        idleUntilLoaded(controller.get())
        assertEquals(fileA, controller.get().originalFileUri.value)
        assertEquals("Text of A", controller.get().binding.EnterBody.text.toString())
        return controller
    }

    private fun saveAsFileB(activity: EditTextPlainActivity) {
        val buttons = activity.binding.BottomAppBarRight
        (0 until buttons.childCount)
            .map { buttons.getChildAt(it) }
            .single { it.contentDescription == activity.getString(R.string.save_to_device) }
            .performClick()
        val request = shadowOf(activity).nextStartedActivityForResult
        shadowOf(activity)
            .receiveResult(request.intent, Activity.RESULT_OK, Intent().setData(fileB))
        idleUntil { activity.originalFileUri.value == fileB }
        assertEquals(fileB, activity.originalFileUri.value)
    }

    /** The editor reads the note on another thread, then adds the bottom bar buttons. */
    private fun idleUntilLoaded(activity: EditTextPlainActivity) = idleUntil {
        activity.binding.BottomAppBarRight.childCount > 0
    }

    private fun idleUntil(condition: () -> Boolean) {
        val end = System.currentTimeMillis() + 5_000
        do {
            shadowOf(getMainLooper()).idle()
            if (condition()) return
            Thread.sleep(10)
        } while (System.currentTimeMillis() < end)
    }

    companion object {
        @JvmStatic
        @BeforeClass
        fun beforeClass() {
            FakeAndroidKeyStore.setup
        }
    }
}
