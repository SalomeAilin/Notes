import CoreGraphics
import Testing

@testable import InkNotesCore

@Suite("Continuous writing page geometry")
struct ContinuousCanvasGeometryTests {
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
