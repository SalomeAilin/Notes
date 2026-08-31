import Foundation

enum ContinuousCanvasGeometry {
  static func minimumContentHeight(viewportHeight: CGFloat) -> CGFloat {
    max(1_600, viewportHeight * 1.6)
  }

  static func requiredContentHeight(
    drawingMaximumY maximumY: CGFloat,
    viewportHeight: CGFloat
  ) -> CGFloat {
    let minimumHeight = minimumContentHeight(viewportHeight: viewportHeight)
    guard maximumY.isFinite, maximumY > 0 else { return minimumHeight }

    let writingComfortBuffer = max(640, viewportHeight * 0.8)
    let requestedHeight = maximumY + writingComfortBuffer
    guard requestedHeight > minimumHeight else { return minimumHeight }
    let growthStep = max(1_024, viewportHeight)
    return max(minimumHeight, ceil(requestedHeight / growthStep) * growthStep)
  }
}
