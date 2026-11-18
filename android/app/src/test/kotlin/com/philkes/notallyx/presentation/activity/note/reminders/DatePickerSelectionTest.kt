package com.philkes.notallyx.presentation.activity.note.reminders

import java.util.Calendar
import java.util.TimeZone
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test

class DatePickerSelectionTest {

    private val defaultTimeZone = TimeZone.getDefault()

    @After
    fun restoreTimeZone() {
        TimeZone.setDefault(defaultTimeZone)
    }

    @Test
    fun `selection is the local day in a negative UTC offset`() {
        // 21:00 in New York is already the next day in UTC
        assertLocalDayIsSelected("America/New_York", 2025, Calendar.JUNE, 10, 21)
    }

    @Test
    fun `selection is the local day in a positive UTC offset`() {
        // 02:00 in Kolkata is still the previous day in UTC
        assertLocalDayIsSelected("Asia/Kolkata", 2025, Calendar.JUNE, 10, 2)
    }

    private fun assertLocalDayIsSelected(zone: String, year: Int, month: Int, day: Int, hour: Int) {
        TimeZone.setDefault(TimeZone.getTimeZone(zone))
        val local = Calendar.getInstance().apply { set(year, month, day, hour, 0, 0) }

        val selection = toDatePickerSelection(local)

        // MaterialDatePicker shows the UTC day of the selection
        val utc = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
        utc.clear()
        utc.set(year, month, day)
        assertEquals(utc.timeInMillis, selection)
        // and the result (UTC midnight of the chosen day) gives the same local day back
        assertEquals(Triple(year, month, day), fromDatePickerSelection(selection))
    }
}
