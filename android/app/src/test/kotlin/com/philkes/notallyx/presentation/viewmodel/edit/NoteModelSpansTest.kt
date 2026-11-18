package com.philkes.notallyx.presentation.viewmodel.edit

import android.app.Application
import android.graphics.Typeface
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.StyleSpan
import androidx.test.core.app.ApplicationProvider
import com.philkes.notallyx.data.model.SpanRepresentation
import com.philkes.notallyx.presentation.viewmodel.preference.NotallyXPreferences
import org.assertj.core.api.Assertions.assertThat
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [35])
class NoteModelSpansTest {

    @Test
    fun boldItalicTextKeepsBothStylesOnSave() {
        val app = ApplicationProvider.getApplicationContext<Application>()
        val model = NoteModel(app, NotallyXPreferences.getInstance(app))
        model.body =
            SpannableStringBuilder("Hello").apply {
                setSpan(StyleSpan(Typeface.BOLD_ITALIC), 0, 5, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }

        assertThat(model.getBaseNote().spans)
            .containsExactly(SpanRepresentation(0, 5, bold = true, italic = true))
    }
}
