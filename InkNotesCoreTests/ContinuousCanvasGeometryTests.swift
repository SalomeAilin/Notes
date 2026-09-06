import CoreGraphics
import Testing

@testable import InkNotesCore

@Suite("Continuous writing page geometry")
struct ContinuousCanvasGeometryTests {
  @Test("Returning after erasing the bottom keeps blank paper and permits further growth")
  func erasedPaperSurvivesPageSwitch() {
    let expandedHeight = ContinuousCanvasGeometry.requiredContentHeight(
      drawingMaximumY: 5_000, viewportHeight: 800
    )
    let reopenedHeight = ContinuousCanvasGeometry.requiredContentHeight(
      drawingMaximumY: 0, viewportHeight: 600, retainedHeight: expandedHeight
    )
    #expect(reopenedHeight == expandedHeight)
    // A previous reading position remains inside the restored paper at the same zoom.
    #expect(reopenedHeight - 600 >= 4_800)
    #expect(
      ContinuousCanvasGeometry.requiredContentHeight(
        drawingMaximumY: 7_000, viewportHeight: 600, retainedHeight: reopenedHeight
      ) > reopenedHeight
    )
    #expect(
      ContinuousCanvasGeometry.requiredContentHeight(
        drawingMaximumY: 0, viewportHeight: 600
      ) == 1_600
    )
  }

  @Test("Invalid remembered heights cannot corrupt a newly opened page")
  func invalidRetainedHeightsAreIgnored() {
    for height: CGFloat in [.nan, .infinity, -.infinity, -1, 0] {
      #expect(
        ContinuousCanvasGeometry.requiredContentHeight(
          drawingMaximumY: 5_000, viewportHeight: 800, retainedHeight: height
        ) == 6_144
      )
    }
  }

  @Test("A fresh page starts with comfortable writing room")
  func freshPageHasWritingRoom() {
    #expect(
      ContinuousCanvasGeometry.requiredContentHeight(
        drawingMaximumY: 0,
        viewportHeight: 800
      ) == 1_600
    )
    #expect(
      ContinuousCanvasGeometry.requiredContentHeight(
        drawingMaximumY: .nan,
        viewportHeight: 1_200
      ) == 1_920
    )
  }

  @Test("Writing near the end grows by stable viewport-sized steps")
  func writingGrowsThePage() {
    #expect(
      ContinuousCanvasGeometry.requiredContentHeight(
        drawingMaximumY: 800,
        viewportHeight: 800
      ) == 1_600
    )
    #expect(
      ContinuousCanvasGeometry.requiredContentHeight(
        drawingMaximumY: 1_450,
        viewportHeight: 800
      ) == 3_072
    )
    #expect(
      ContinuousCanvasGeometry.requiredContentHeight(
        drawingMaximumY: 5_000,
        viewportHeight: 800
      ) == 6_144
    )
  }
}
