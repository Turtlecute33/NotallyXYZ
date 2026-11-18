package com.philkes.notallyx.data.model

import com.philkes.notallyx.data.imports.google.GoogleKeepImporterTest.Companion.createBaseNote
import java.nio.file.Files
import org.assertj.core.api.Assertions.assertThat
import org.jsoup.Jsoup
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class HtmlExportTest {

    @Test
    fun `toHtml escapes image names and link addresses`() {
        val imageName = "x\" srcset=\"https://example.org/p.png 1x"
        val url = "https://example.org/?a=1&b=\" style=\"background:url(https://example.org/p.png)"
        val folder = Files.createTempDirectory("images").toFile()
        folder.resolve("image.png").writeBytes(byteArrayOf(1, 2, 3))
        val note =
            createBaseNote(
                title = "Title",
                body = "Click",
                spans = listOf(SpanRepresentation(0, 5, link = true, linkData = url)),
                images = listOf(FileAttachment("image.png", imageName, "image/png")),
            )

        val document = Jsoup.parse(note.toHtml(showDateCreated = false, folder))

        val image = document.selectFirst("img")!!
        assertThat(image.attr("alt")).isEqualTo(imageName)
        assertThat(image.hasAttr("srcset")).isFalse()
        val link = document.selectFirst("a")!!
        assertThat(link.attr("href")).isEqualTo(url)
        assertThat(link.hasAttr("style")).isFalse()
    }
}
