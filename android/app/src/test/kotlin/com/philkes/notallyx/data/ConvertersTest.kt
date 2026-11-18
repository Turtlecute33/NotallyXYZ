package com.philkes.notallyx.data

import com.philkes.notallyx.data.model.Converters
import com.philkes.notallyx.data.model.FileAttachment
import com.philkes.notallyx.data.model.Repetition
import com.philkes.notallyx.data.model.RepetitionTimeUnit
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Robolectric: the app runs with Android's org.json, which differs from the plain JVM one. */
@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [35])
class ConvertersTest {

    @Test
    fun `jsonToFiles input with localName and originalName fields`() {
        val json =
            """
            [
                {
                    "localName": "content://some/random/path/123435",
                    "originalName": "file1.pdf",
                    "mimeType": "application/pdf"
                },
                 {
                    "localName": "content://some/other/random/path/123435",
                    "originalName": "random.jpeg",
                    "mimeType": "image/jpeg"
                }
            ]
            """
                .trimIndent()

        val files = Converters.jsonToFiles(json)

        assertEquals(2, files.size)
        assertEquals(
            FileAttachment("content://some/random/path/123435", "file1.pdf", "application/pdf"),
            files[0],
        )
        assertEquals(
            FileAttachment("content://some/other/random/path/123435", "random.jpeg", "image/jpeg"),
            files[1],
        )
    }

    @Test
    fun `jsonToFiles input with only name field`() {
        val json =
            """
            [
                {
                    "name": "content://some/random/path/123435",
                    "mimeType": "application/pdf"
                },
                 {
                    "name": "content://some/other/random/path/123435",
                    "mimeType": "image/jpeg"
                }
            ]
            """
                .trimIndent()

        val files = Converters.jsonToFiles(json)

        assertEquals(2, files.size)
        assertEquals(
            FileAttachment("content://some/random/path/123435", "123435", "application/pdf"),
            files[0],
        )
        assertEquals(
            FileAttachment("content://some/other/random/path/123435", "123435", "image/jpeg"),
            files[1],
        )
    }

    @Test
    fun `jsonToReminders unknown or broken repetition means no repetition`() {
        val json =
            """
            [
                {"id": 1, "dateTime": 1000, "repetition": {"value": 2, "unit": "FORTNIGHTS"}},
                {"id": 2, "dateTime": 1000, "repetition": {"unit": "DAYS"}},
                {"id": 3, "dateTime": 1000, "repetition": {"value": 2, "unit": "WEEKS"}}
            ]
            """
                .trimIndent()

        val reminders = Converters.jsonToReminders(json)

        assertEquals(
            listOf(null, null, Repetition(2, RepetitionTimeUnit.WEEKS)),
            reminders.map { it.repetition },
        )
    }
}
