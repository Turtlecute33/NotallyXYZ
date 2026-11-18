package com.philkes.notallyx.presentation.view.note.listitem.adapter

import com.philkes.notallyx.data.imports.txt.extractListItems
import com.philkes.notallyx.data.imports.txt.findListSyntaxRegex
import org.junit.Assert.assertEquals
import org.junit.Test

class PasteIntoListItemTest {

    /** Simulates a paste of [pasted] into [body], replacing the text from [start] to [end]. */
    private fun paste(body: String, pasted: String, start: Int, end: Int = start): List<String> {
        val text = body.substring(0, start) + pasted + body.substring(end)
        val items =
            pasted.extractListItems(
                pasted.findListSyntaxRegex(checkContains = true, plainNewLineAllowed = true)!!
            )
        val first = items.keepTextAroundPaste(text, start, pasted.length)
        return listOf(first) + items.drop(1).map { it.body }
    }

    @Test
    fun `paste in the middle keeps the text after the cursor`() {
        assertEquals(listOf("abcx", "ydef"), paste("abcdef", "x\ny", 3))
    }

    @Test
    fun `paste over a selection keeps the text after the selection`() {
        assertEquals(listOf("abx", "yef"), paste("abcdef", "x\ny", 2, 4))
    }

    @Test
    fun `paste at the start keeps the item text`() {
        assertEquals(listOf("x", "ydef"), paste("def", "x\ny", 0))
    }

    @Test
    fun `paste at the end keeps the item text`() {
        assertEquals(listOf("abcx", "y"), paste("abc", "x\ny", 3))
    }

    @Test
    fun `paste into an empty item`() {
        assertEquals(listOf("x", "y", "z"), paste("", "x\ny\nz", 0))
    }

    @Test
    fun `paste of a single item keeps both sides`() {
        assertEquals(listOf("abxcd"), paste("abcd", "\nx\n", 2))
    }
}
