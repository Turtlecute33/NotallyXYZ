package com.philkes.notallyx.sorting

import com.philkes.notallyx.data.imports.google.GoogleKeepImporterTest.Companion.createBaseNote
import com.philkes.notallyx.data.model.Folder
import com.philkes.notallyx.data.model.Header
import com.philkes.notallyx.data.model.Item
import com.philkes.notallyx.presentation.view.main.sorting.BaseNoteTitleSort
import com.philkes.notallyx.presentation.view.main.sorting.ItemSort
import com.philkes.notallyx.presentation.viewmodel.preference.SortDirection
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Test

class ItemSortTest {

    private val sort = BaseNoteTitleSort(null, SortDirection.ASC)

    private fun List<Item>.sorted() = sortedWith { item1, item2 -> sort.compare(item1, item2) }

    @Test
    fun `archived header stays above the archived notes`() {
        val archivedHeader = Header("Archived", ItemSort.ARCHIVED)
        val z = createBaseNote(id = 1, title = "z")
        val c = createBaseNote(id = 2, title = "c")
        val b = createBaseNote(id = 3, title = "b", folder = Folder.ARCHIVED)

        assertEquals(listOf(c, z, archivedHeader, b), listOf(z, c, archivedHeader, b).sorted())
    }

    @Test
    fun `every header stays above its notes in any input order`() {
        val pinnedHeader = Header("Pinned", ItemSort.PINNED)
        val othersHeader = Header("Others", ItemSort.OTHERS)
        val archivedHeader = Header("Archived", ItemSort.ARCHIVED)
        val pinned = createBaseNote(id = 1, title = "y", pinned = true)
        val a = createBaseNote(id = 2, title = "a")
        val z = createBaseNote(id = 3, title = "z")
        val archivedPinned =
            createBaseNote(id = 4, title = "x", pinned = true, folder = Folder.ARCHIVED)
        val archived = createBaseNote(id = 5, title = "b", folder = Folder.ARCHIVED)
        val expected =
            listOf(
                pinnedHeader,
                pinned,
                othersHeader,
                a,
                z,
                archivedHeader,
                archivedPinned,
                archived,
            )

        listOf(expected.reversed(), expected.shuffled(Random(1)), expected.shuffled(Random(2)))
            .forEach { input -> assertEquals(expected, input.sorted()) }
    }
}
