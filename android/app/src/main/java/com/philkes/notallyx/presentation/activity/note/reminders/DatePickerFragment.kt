package com.philkes.notallyx.presentation.activity.note.reminders

import android.os.Bundle
import androidx.fragment.app.DialogFragment
import com.google.android.material.datepicker.MaterialDatePicker
import com.google.android.material.datepicker.MaterialDatePicker.INPUT_MODE_CALENDAR
import com.philkes.notallyx.utils.now
import java.util.Calendar
import java.util.Date
import java.util.TimeZone

class DatePickerFragment(
    private val date: Date?,
    private val onDateSetListener: (year: Int, month: Int, day: Int) -> Unit,
) : DialogFragment() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val now = now()
        val c = date?.let { Calendar.getInstance().apply { time = it } } ?: now

        val datePicker =
            MaterialDatePicker.Builder.datePicker()
                .setSelection(toDatePickerSelection(c))
                .setInputMode(INPUT_MODE_CALENDAR)
                .build()

        datePicker.addOnPositiveButtonClickListener { selection ->
            val (year, month, day) = fromDatePickerSelection(selection)
            onDateSetListener(year, month, day)
        }

        datePicker.addOnCancelListener { dismiss() }

        datePicker.addOnNegativeButtonClickListener { dismiss() }

        datePicker.show(parentFragmentManager, "DatePicker")
        dismiss()
    }
}

/**
 * MaterialDatePicker shows the UTC day of its selection, so give it UTC midnight of the local day.
 */
internal fun toDatePickerSelection(date: Calendar): Long {
    val utc = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
    utc.clear()
    utc.set(date.get(Calendar.YEAR), date.get(Calendar.MONTH), date.get(Calendar.DAY_OF_MONTH))
    return utc.timeInMillis
}

/** The picker returns UTC midnight of the chosen day: read the day in UTC. */
internal fun fromDatePickerSelection(selection: Long): Triple<Int, Int, Int> {
    val calendar = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
    calendar.timeInMillis = selection
    return Triple(
        calendar.get(Calendar.YEAR),
        calendar.get(Calendar.MONTH),
        calendar.get(Calendar.DAY_OF_MONTH),
    )
}
