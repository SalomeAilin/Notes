import Foundation

enum ContinuousCanvasGeometry {
  /// World coordinates never move when paper grows to the left or above the origin.
  /// Only the navigable bounds grow; drawing data is not translated or rewritten.
  static func expandedBounds(
    retaining retained: CGRect = .null,
    drawing: CGRect,
    visible: CGRect
  ) -> CGRect {
    let viewport = isUsable(visible) ? visible : CGRect(x: 0, y: 0, width: 800, height: 800)
    let marginX = max(640, viewport.width * 0.8)
    let marginY = max(640, viewport.height * 0.8)
    var needed = viewport
    if isUsable(drawing) { needed = needed.union(drawing) }
    let step: CGFloat = 1_024
    let expanded = CGRect(
      x: floor((needed.minX - marginX) / step) * step,
      y: floor((needed.minY - marginY) / step) * step,
      width: 0,
      height: 0
    )
    let maximumX = max(step, ceil((needed.maxX + marginX) / step) * step)
    let maximumY = max(step, ceil((needed.maxY + marginY) / step) * step)
    let candidate = CGRect(
      x: min(0, expanded.minX), y: min(0, expanded.minY),
      width: maximumX - min(0, expanded.minX),
      height: maximumY - min(0, expanded.minY)
    )
    guard isUsable(candidate) else {
      return isUsable(retained)
        ? retained : CGRect(x: -1_024, y: -1_024, width: 3_072, height: 3_072)
    }
    return isUsable(retained) ? retained.union(candidate) : candidate
  }

  static func visibleRect(offset: CGPoint, size: CGSize, zoom: CGFloat) -> CGRect {
    let scale = zoom.isFinite && zoom > 0 ? zoom : 1
    return CGRect(
      x: offset.x / scale, y: offset.y / scale,
      width: size.width / scale, height: size.height / scale
    )
  }

  private static func isUsable(_ rect: CGRect) -> Bool {
    !rect.isNull && !rect.isInfinite && !rect.isEmpty && rect.minX.isFinite && rect.minY.isFinite
      && rect.maxX.isFinite && rect.maxY.isFinite
      && rect.width.isFinite && rect.height.isFinite
  }

  static func minimumContentHeight(viewportHeight: CGFloat) -> CGFloat {
    max(1_600, viewportHeight * 1.6)
  }

  static func requiredContentHeight(
    drawingMaximumY maximumY: CGFloat,
    viewportHeight: CGFloat,
    retainedHeight: CGFloat = 0
  ) -> CGFloat {
    let validRetainedHeight = retainedHeight.isFinite && retainedHeight > 0 ? retainedHeight : 0
    let minimumHeight = max(
      minimumContentHeight(viewportHeight: viewportHeight), validRetainedHeight
    )
    guard maximumY.isFinite, maximumY > 0 else { return minimumHeight }

    let writingComfortBuffer = max(640, viewportHeight * 0.8)
    let requestedHeight = maximumY + writingComfortBuffer
    guard requestedHeight > minimumHeight else { return minimumHeight }
    let growthStep = max(1_024, viewportHeight)
    return max(minimumHeight, ceil(requestedHeight / growthStep) * growthStep)
  }
}
