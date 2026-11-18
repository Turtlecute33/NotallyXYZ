package com.philkes.notallyx.presentation.view.main.sorting

import androidx.recyclerview.widget.RecyclerView
import androidx.recyclerview.widget.SortedListAdapterCallback
import com.philkes.notallyx.data.model.BaseNote
import com.philkes.notallyx.data.model.Folder
import com.philkes.notallyx.data.model.Header
import com.philkes.notallyx.data.model.Item
import com.philkes.notallyx.presentation.viewmodel.preference.SortDirection

abstract class ItemSort(
    adapter: RecyclerView.Adapter<*>?,
    private val sortDirection: SortDirection,
) : SortedListAdapterCallback<Item>(adapter) {

    abstract fun compare(note1: BaseNote, note2: BaseNote, sortDirection: SortDirection): Int

    override fun compare(item1: Item?, item2: Item?): Int {
        return when {
            item1 == null && item2 == null -> 0
            item1 == null && item2 != null -> -1
            item1 != null && item2 == null -> 1
            else -> {
                val rankCompare = item1!!.rank().compareTo(item2!!.rank())
                if (rankCompare == 0 && item1 is BaseNote && item2 is BaseNote) {
                    compare(item1, item2, sortDirection)
                } else rankCompare
            }
        }
    }

    /** Each header comes just above its notes. Archived notes (in a label) come last. */
    private fun Item.rank(): Int =
        when (this) {
            is Header -> rank
            is BaseNote ->
                when {
                    folder == Folder.ARCHIVED -> if (pinned) ARCHIVED + 1 else ARCHIVED + 2
                    pinned -> PINNED + 1
                    else -> OTHERS + 1
                }
        }

    override fun areContentsTheSame(oldItem: Item?, newItem: Item?): Boolean {
        return oldItem == newItem
    }

    override fun areItemsTheSame(item1: Item?, item2: Item?): Boolean {
        return when {
            item1 is BaseNote && item2 is BaseNote -> item1.id == item2.id
            item1 is Header && item2 is Header -> item1 == item2
            else -> false
        }
    }

    companion object {
        /** Ranks of the headers. */
        const val PINNED = 0
        const val OTHERS = 2
        const val ARCHIVED = 4
    }
}
