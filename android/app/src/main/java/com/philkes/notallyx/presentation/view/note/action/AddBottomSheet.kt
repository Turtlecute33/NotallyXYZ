package com.philkes.notallyx.presentation.view.note.action

import androidx.annotation.ColorInt
import com.philkes.notallyx.R
import com.philkes.notallyx.presentation.activity.note.NoteActionHandler

/** BottomSheet inside note for adding files, recording audio. */
class AddBottomSheet : ActionBottomSheet {

    constructor(
        handler: NoteActionHandler,
        @ColorInt color: Int?,
    ) : super(createActions(handler), color)

    /** Only for the fragment manager. A sheet it restores has no actions and closes itself. */
    constructor() : super()

    companion object {
        const val TAG = "AddBottomSheet"

        fun createActions(actionHandler: NoteActionHandler) =
            listOf(
                Action(R.string.add_images, R.drawable.add_images) { _ ->
                    actionHandler.addImages()
                    true
                },
                Action(R.string.attach_file, R.drawable.text_file) { _ ->
                    actionHandler.attachFiles()
                    true
                },
            ) +
                listOf(
                    Action(R.string.record_audio, R.drawable.record_audio) { _ ->
                        actionHandler.recordAudio()
                        true
                    }
                )
    }
}
