package com.philkes.notallyx.presentation.activity.main.fragment

import org.junit.Assert.assertEquals
import org.junit.Test

class LongClickRangeTest {

    @Test
    fun `range goes from the anchor to the pressed note`() {
        assertEquals(2..5, longClickRange(anchor = 2, position = 5, itemCount = 10))
        assertEquals(2..5, longClickRange(anchor = 5, position = 2, itemCount = 10))
    }

    @Test
    fun `no anchor after recreation selects only the pressed note`() {
        assertEquals(3..3, longClickRange(anchor = -1, position = 3, itemCount = 10))
    }

    @Test
    fun `anchor outside the list selects only the pressed note`() {
        assertEquals(1..1, longClickRange(anchor = 7, position = 1, itemCount = 4))
    }
}
