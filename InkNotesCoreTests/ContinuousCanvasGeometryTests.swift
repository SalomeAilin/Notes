import CoreGraphics
import Testing

@testable import InkNotesCore

@Suite("Continuous writing page geometry")
struct ContinuousCanvasGeometryTests {
  @Test("Paper grows in all four directions without changing world coordinates")
  func fourDirectionGrowth() {
    let initial = ContinuousCanvasGeometry.expandedBounds(
      drawing: .null, visible: CGRect(x: 0, y: 0, width: 800, height: 600)
    )
    for origin in [
      CGPoint(x: -8_000, y: 0), CGPoint(x: 8_000, y: 0),
      CGPoint(x: 0, y: -8_000), CGPoint(x: 0, y: 8_000),
    ] {
      let visible = CGRect(origin: origin, size: CGSize(width: 800, height: 600))
      let expanded = ContinuousCanvasGeometry.expandedBounds(
        retaining: initial, drawing: .null, visible: visible
      )
      #expect(expanded.contains(initial))
      #expect(expanded.contains(visible.insetBy(dx: -600, dy: -600)))
    }
  }

  @Test("Resizing and erasing cannot shrink previously explored paper")
  func retainAllDirectionsAfterEraseAndResize() {
    let drawing = CGRect(x: -5_000, y: -9_000, width: 12_000, height: 18_000)
    let expanded = ContinuousCanvasGeometry.expandedBounds(
      drawing: drawing, visible: CGRect(x: 0, y: 0, width: 1_024, height: 768)
    )
    let restored = ContinuousCanvasGeometry.expandedBounds(
      retaining: expanded, drawing: .null,
      visible: CGRect(x: -4_000, y: -8_000, width: 400, height: 700)
    )
    #expect(restored == expanded)
    #expect(restored.contains(drawing))
  }

  @Test("Offsets and zoom map to stable world coordinates including negative positions")
  func negativeViewportAtEveryZoom() {
    for zoom: CGFloat in [0.25, 0.65, 1, 3] {
      let visible = ContinuousCanvasGeometry.visibleRect(
        offset: CGPoint(x: -4_000 * zoom, y: 5_000 * zoom),
        size: CGSize(width: 800, height: 600), zoom: zoom
      )
      #expect(visible.origin == CGPoint(x: -4_000, y: 5_000))
      #expect(visible.width == 800 / zoom)
      let bounds = ContinuousCanvasGeometry.expandedBounds(drawing: .null, visible: visible)
      #expect(bounds.contains(visible))
    }
  }

  @Test("Empty or nonfinite geometry cannot produce infinite layout sizes")
  func invalidWorldGeometry() {
    let baseline = ContinuousCanvasGeometry.expandedBounds(drawing: .null, visible: .zero)
    for invalid in [CGRect.null, .infinite, CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)] {
      #expect(
        ContinuousCanvasGeometry.expandedBounds(
          retaining: invalid, drawing: invalid, visible: invalid) == baseline)
    }
  }

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
