package com.philkes.notallyx.presentation.view.note.action

import androidx.annotation.ColorInt
import com.philkes.notallyx.presentation.viewmodel.ExportMimeType
import com.philkes.notallyx.presentation.viewmodel.preference.EditAction

class ExportBottomSheet : ActionBottomSheet {

    constructor(
        @ColorInt color: Int?,
        callback: (ExportMimeType) -> Unit,
    ) : super(createActions(callback), color)

    /** Only for the fragment manager. A sheet it restores has no actions and closes itself. */
    constructor() : super()

    companion object {
        const val TAG = "ExportBottomSheet"

        private fun createActions(callback: (ExportMimeType) -> Unit): List<Action> {
            return ExportMimeType.entries.map { mimeType ->
                Action(labelResId = EditAction.EXPORT.textResId, label = mimeType.name) { _ ->
                    callback.invoke(mimeType)
                    true
                }
            }
        }
    }
}
