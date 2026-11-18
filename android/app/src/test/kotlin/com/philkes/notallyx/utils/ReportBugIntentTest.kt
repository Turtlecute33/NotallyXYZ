package com.philkes.notallyx.utils

import android.app.Application
import android.content.Intent
import androidx.core.content.IntentCompat
import androidx.test.core.app.ApplicationProvider
import com.philkes.notallyx.BuildConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Bug reports of this fork go to the fork's issue tracker, not to upstream NotallyX. */
@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [35])
class ReportBugIntentTest {

    private val context = ApplicationProvider.getApplicationContext<Application>()

    @Test
    fun reportGoesToTheForkWithVersionAndLogsInTheBody() {
        val chooser =
            context.createReportBugIntent(
                "java.lang.IllegalStateException: test",
                title = "Auto Backup failed",
                body = "Error occurred during auto backup",
            )
        val uri =
            IntentCompat.getParcelableExtra(chooser, Intent.EXTRA_INTENT, Intent::class.java)!!
                .data!!

        assertEquals("https", uri.scheme)
        assertEquals("github.com", uri.host)
        assertEquals("/Turtlecute33/NotallyXYZ/issues/new", uri.path)
        assertEquals(setOf("title", "body"), uri.queryParameterNames)
        assertEquals("Auto Backup failed", uri.getQueryParameter("title"))
        val body = uri.getQueryParameter("body")!!
        assertTrue(body, body.contains("Error occurred during auto backup"))
        assertTrue(body, body.contains(BuildConfig.VERSION_NAME))
        assertTrue(body, body.contains("java.lang.IllegalStateException: test"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun tooLongLogsAreRefused() {
        context.createReportBugIntent("x".repeat(2000))
    }
}
