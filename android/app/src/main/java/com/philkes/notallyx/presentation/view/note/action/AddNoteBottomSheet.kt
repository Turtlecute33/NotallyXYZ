package com.philkes.notallyx.presentation.view.note.action

import androidx.annotation.ColorInt
import com.philkes.notallyx.R
import com.philkes.notallyx.presentation.activity.note.NoteActionHandler

/** BottomSheet inside text note for adding files, recording audio. */
class AddNoteBottomSheet : ActionBottomSheet {

    constructor(
        actionHandler: NoteActionHandler,
        @ColorInt color: Int?,
    ) : super(createActions(actionHandler), color)

    /** Only for the fragment manager. A sheet it restores has no actions and closes itself. */
    constructor() : super()

    companion object {
        const val TAG = "AddNoteBottomSheet"

        fun createActions(actionHandler: NoteActionHandler) =
            AddBottomSheet.createActions(actionHandler) +
                listOf(
                    Action(R.string.link_note, R.drawable.notebook) { _ ->
                        actionHandler.addNoteLink()
                        true
                    }
                )
    }
}
