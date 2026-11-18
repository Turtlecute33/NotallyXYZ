package com.philkes.notallyx.presentation.view.misc

import android.app.Application
import android.text.style.URLSpan
import androidx.test.core.app.ApplicationProvider
import org.assertj.core.api.Assertions.assertThat
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class StylableEditTextWithHistoryTest {

    @Test
    fun aLinkAddedWithoutFocusGoesToTheEnd() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        val editText = StylableEditTextWithHistory(context, Robolectric.buildAttributeSet().build())
        editText.setText("Hello")

        editText.addSpans("Link", listOf(URLSpan("note://1")), pushChange = false)

        val text = editText.text!!
        assertThat(text.toString()).isEqualTo("HelloLink")
        val span = text.getSpans(0, text.length, URLSpan::class.java).single()
        assertThat(text.getSpanStart(span) to text.getSpanEnd(span)).isEqualTo(5 to 9)
    }
}
