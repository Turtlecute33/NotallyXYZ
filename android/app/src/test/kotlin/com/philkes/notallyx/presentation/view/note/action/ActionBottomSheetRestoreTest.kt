package com.philkes.notallyx.presentation.view.note.action

import android.app.Application
import android.os.Bundle
import android.os.Looper.getMainLooper
import androidx.appcompat.app.AppCompatActivity
import androidx.fragment.app.FragmentFactory
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.philkes.notallyx.R
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], application = Application::class)
class ActionBottomSheetRestoreTest {

    class HostActivity : AppCompatActivity() {
        override fun onCreate(savedInstanceState: Bundle?) {
            setTheme(R.style.AppTheme)
            super.onCreate(savedInstanceState)
        }
    }

    @Test
    fun `an open sheet closes when the activity is recreated`() {
        assertClosesOnRecreate(ActionBottomSheet(listOf(Action(R.string.item) { true })))
    }

    @Test
    fun `an open export sheet closes when the activity is recreated`() {
        assertClosesOnRecreate(ExportBottomSheet(null) {})
    }

    @Test
    fun `every sheet can be created by the fragment manager`() {
        listOf(
                ActionBottomSheet::class.java,
                ActionSelectionBottomSheet::class.java,
                AddBottomSheet::class.java,
                AddNoteBottomSheet::class.java,
                ExportBottomSheet::class.java,
                MoreListBottomSheet::class.java,
                MoreNoteBottomSheet::class.java,
            )
            .forEach { assertNotNull(FragmentFactory().instantiate(it.classLoader!!, it.name)) }
    }

    private fun assertClosesOnRecreate(sheet: ActionBottomSheet) {
        val controller = Robolectric.buildActivity(HostActivity::class.java).setup()
        sheet.show(controller.get().supportFragmentManager, TAG)
        shadowOf(getMainLooper()).idle()
        assertNotNull(controller.get().supportFragmentManager.findFragmentByTag(TAG))

        controller.recreate()
        shadowOf(getMainLooper()).idle()

        assertNull(controller.get().supportFragmentManager.findFragmentByTag(TAG))
    }

    companion object {
        private const val TAG = "sheet"
    }
}
