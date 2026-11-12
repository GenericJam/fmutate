package com.example.fmutate_app.fmutate

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EditGridTest {
    // the board's phone: 844 × 390 pt → 14 × 6
    private val g = Grid.forScreen(844f, 390f)

    @Test
    fun gridMatchesTheHandoff() {
        assertEquals(14, g.cols)
        assertEquals(6, g.rows)
    }

    @Test
    fun cellAtFindsCellsAndRejectsTheGutter() {
        assertEquals(0 to 0, EditGrid.cellAt(g, 30f, 14f))
        val r = g.rect(Cell(5, 3, 1, 1))
        assertEquals(5 to 3, EditGrid.cellAt(g, r.cx, r.cy))
        assertNull(EditGrid.cellAt(g, 10f, 100f))
    }

    @Test
    fun snapRoundsToTheNearestCellAndStaysOnTheGrid() {
        val r = g.rect(Cell(4, 2, 1, 1))
        assertEquals(Cell(4, 2, 2, 1), EditGrid.snap(g, r.x + r.w * 0.4f, r.y - 10f, 2, 1))
        assertEquals(Cell(12, 0, 2, 1), EditGrid.snap(g, 2000f, -50f, 2, 1))
    }

    @Test
    fun resizeKeepsTheOppositeCornerAndTheMinimum() {
        val from = Cell(4, 2, 2, 2)
        // bottom-right handle dragged out to (8, 4)
        assertEquals(Cell(4, 2, 5, 3), EditGrid.resize(g, from, 3, 8, 4, 1 to 1))
        // top-left handle dragged past the opposite corner: stops at the minimum
        assertEquals(Cell(4, 2, 2, 2), EditGrid.resize(g, from, 0, 9, 9, 2 to 2))
        assertEquals(Cell(5, 2, 1, 2), EditGrid.resize(g, from, 0, 9, 2, 1 to 2))
    }

    @Test
    fun freeChecksBoundsAndOverlap() {
        val others = listOf(Cell(0, 3, 14, 3))
        assertTrue(EditGrid.free(Cell(12, 1, 2, 2), others, 14, 6))
        assertFalse(EditGrid.free(Cell(12, 2, 2, 2), others, 14, 6))
        assertFalse(EditGrid.free(Cell(13, 0, 2, 1), others, 14, 6))
    }

    @Test
    fun minimumSizesFollowOrientation() {
        val slider = Control("s", "slider", Cell(0, 0, 2, 1), "", "default", emptyList(), sliderVertical = false)
        assertEquals(2 to 1, minSize(slider))
        assertEquals(2 to 4, minSize(slider.copy(type = "keyboard", vertical = true)))
    }
}
