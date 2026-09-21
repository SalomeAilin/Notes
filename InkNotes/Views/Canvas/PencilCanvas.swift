import Combine
import PencilKit
import SwiftUI

enum CanvasInputPolicy: String, CaseIterable {
  case pencilOnly
  case anyInput

  var drawingPolicy: PKCanvasViewDrawingPolicy {
    switch self {
    case .pencilOnly: .pencilOnly
    case .anyInput: .anyInput
    }
  }
}

private struct CanvasViewport {
  let contentOffset: CGPoint
  let zoomScale: CGFloat
  let worldBounds: CGRect
}

@MainActor
final class PencilCanvasController: ObservableObject {
  private weak var canvasHost: ExpandablePencilCanvasView?
  private let toolPicker: PKToolPicker
  private var viewports: [UUID: CanvasViewport] = [:]

  init() {
    let toolPicker = PKToolPicker()
    toolPicker.maximumSupportedContentVersion = .version2
    toolPicker.showsDrawingPolicyControls = false
    self.toolPicker = toolPicker
  }

  fileprivate func attach(_ canvasHost: ExpandablePencilCanvasView, pageID: UUID) {
    self.canvasHost = canvasHost
    toolPicker.addObserver(canvasHost.canvasView)
    canvasHost.restoreViewport(viewports[pageID])
  }

  fileprivate func detach(_ canvasHost: ExpandablePencilCanvasView, pageID: UUID) {
    let canvasView = canvasHost.canvasView
    toolPicker.setVisible(false, forFirstResponder: canvasView)
    canvasView.resignFirstResponder()
    toolPicker.removeObserver(canvasView)
    viewports[pageID] = canvasHost.currentViewport
    guard self.canvasHost === canvasHost else { return }
    self.canvasHost = nil
  }

  fileprivate func setToolPickerVisible(
    _ isVisible: Bool,
    for canvasHost: ExpandablePencilCanvasView
  ) {
    guard self.canvasHost === canvasHost else { return }
    let canvasView = canvasHost.canvasView
    toolPicker.setVisible(isVisible, forFirstResponder: canvasView)
    if isVisible {
      canvasView.becomeFirstResponder()
    } else {
      canvasView.resignFirstResponder()
    }
  }

  func undo() {
    canvasHost?.canvasView.undoManager?.undo()
  }

  func redo() {
    canvasHost?.canvasView.undoManager?.redo()
  }

  func returnToDrawing() {
    canvasHost?.returnToDrawing()
  }
}

struct PencilCanvas: UIViewRepresentable {
  @Binding var drawingData: Data
  let pageID: UUID
  let background: PageBackground
  let inputPolicy: CanvasInputPolicy
  let isEditable: Bool
  @ObservedObject var controller: PencilCanvasController

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeUIView(context: Context) -> ExpandablePencilCanvasView {
    let canvasHost = ExpandablePencilCanvasView()
    context.coordinator.canvasHost = canvasHost
    canvasHost.canvasView.delegate = context.coordinator
    canvasHost.apply(
      drawing: Self.decodeDrawing(drawingData),
      background: background,
      inputPolicy: inputPolicy,
      isEditable: isEditable
    )
    controller.attach(canvasHost, pageID: pageID)

    DispatchQueue.main.async {
      let shouldShowTools = context.coordinator.parent.isEditable
      context.coordinator.parent.controller.setToolPickerVisible(
        shouldShowTools,
        for: canvasHost
      )
    }
    return canvasHost
  }

  func updateUIView(_ canvasHost: ExpandablePencilCanvasView, context: Context) {
    context.coordinator.parent = self
    let wasEditable = canvasHost.canvasView.isUserInteractionEnabled
    canvasHost.updateConfiguration(
      background: background,
      inputPolicy: inputPolicy,
      isEditable: isEditable
    )
    if wasEditable != isEditable {
      controller.setToolPickerVisible(isEditable, for: canvasHost)
    }

    let currentData = canvasHost.canvasView.drawing.dataRepresentation()
    guard currentData != drawingData,
      !context.coordinator.isApplyingExternalDrawing
    else { return }

    context.coordinator.isApplyingExternalDrawing = true
    canvasHost.applyExternalDrawing(Self.decodeDrawing(drawingData))
    context.coordinator.isApplyingExternalDrawing = false
  }

  static func dismantleUIView(
    _ canvasHost: ExpandablePencilCanvasView,
    coordinator: Coordinator
  ) {
    coordinator.parent.controller.detach(canvasHost, pageID: coordinator.parent.pageID)
  }

  private static func decodeDrawing(_ data: Data) -> PKDrawing {
    guard !data.isEmpty, let drawing = try? PKDrawing(data: data) else {
      return PKDrawing()
    }
    return drawing
  }

  @MainActor
  final class Coordinator: NSObject, PKCanvasViewDelegate {
    var parent: PencilCanvas
    var isApplyingExternalDrawing = false
    weak var canvasHost: ExpandablePencilCanvasView?

    init(parent: PencilCanvas) {
      self.parent = parent
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
      guard !isApplyingExternalDrawing else { return }
      canvasHost?.expandToFitDrawing()
      let data = canvasView.drawing.dataRepresentation()
      if parent.drawingData != data {
        parent.drawingData = data
      }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      canvasHost?.viewportDidChange()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
      canvasHost?.viewportDidChange()
    }
  }
}

@MainActor
final class ExpandablePencilCanvasView: UIView {
  fileprivate let canvasView = PKCanvasView(frame: .zero)

  private let paperView = CanvasPaperView(frame: .zero)
  private var worldBounds: CGRect = .null
  private var drawingBounds: CGRect = .null
  private var pendingViewport: CanvasViewport?
  private var hasCompletedInitialLayout = false
  private var isUpdatingViewport = false

  override init(frame: CGRect) {
    super.init(frame: frame)

    backgroundColor = .secondarySystemBackground
    clipsToBounds = true

    paperView.isUserInteractionEnabled = false
    addSubview(paperView)

    canvasView.backgroundColor = .clear
    canvasView.isOpaque = false
    canvasView.maximumSupportedContentVersion = .version2
    canvasView.isScrollEnabled = true
    canvasView.alwaysBounceHorizontal = true
    canvasView.alwaysBounceVertical = true
    canvasView.isDirectionalLockEnabled = false
    canvasView.keyboardDismissMode = .interactive
    canvasView.contentInsetAdjustmentBehavior = .never
    canvasView.minimumZoomScale = 0.25
    canvasView.maximumZoomScale = 3
    canvasView.showsHorizontalScrollIndicator = false
    canvasView.showsVerticalScrollIndicator = false
    addSubview(canvasView)

    canvasView.accessibilityLabel = "无限画布"
    canvasView.accessibilityHint = "可向四周移动并双指缩放；找不到内容时，使用回到笔迹。"
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.width > 0, bounds.height > 0 else { return }
    // Keep both views viewport-sized. Growing paper must not allocate a giant bitmap.
    let offset = canvasView.contentOffset
    isUpdatingViewport = true
    paperView.frame = bounds
    canvasView.frame = bounds
    canvasView.contentOffset = offset
    isUpdatingViewport = false

    if !hasCompletedInitialLayout {
      hasCompletedInitialLayout = true
      if pendingViewport != nil {
        applyPendingViewportIfPossible()
      } else {
        returnToDrawing()
      }
    }
    viewportDidChange()
  }

  fileprivate var currentViewport: CanvasViewport {
    CanvasViewport(
      contentOffset: canvasView.contentOffset,
      zoomScale: canvasView.zoomScale,
      worldBounds: worldBounds
    )
  }

  fileprivate func restoreViewport(_ viewport: CanvasViewport?) {
    pendingViewport = viewport
    applyPendingViewportIfPossible()
  }

  fileprivate func apply(
    drawing: PKDrawing,
    background: PageBackground,
    inputPolicy: CanvasInputPolicy,
    isEditable: Bool
  ) {
    drawingBounds = drawing.bounds
    canvasView.drawing = drawing
    updateConfiguration(
      background: background,
      inputPolicy: inputPolicy,
      isEditable: isEditable
    )
    setNeedsLayout()
  }

  fileprivate func updateConfiguration(
    background: PageBackground,
    inputPolicy: CanvasInputPolicy,
    isEditable: Bool
  ) {
    paperView.pageBackground = background
    canvasView.drawingPolicy = inputPolicy.drawingPolicy
    canvasView.isUserInteractionEnabled = isEditable
    canvasView.panGestureRecognizer.minimumNumberOfTouches =
      inputPolicy == .anyInput ? 2 : 1
  }

  fileprivate func applyExternalDrawing(_ drawing: PKDrawing) {
    drawingBounds = drawing.bounds
    canvasView.drawing = drawing
    expandToFitDrawing()
  }

  fileprivate func expandToFitDrawing() {
    drawingBounds = canvasView.drawing.bounds
    viewportDidChange()
  }

  fileprivate func viewportDidChange() {
    guard hasCompletedInitialLayout, !isUpdatingViewport else { return }
    isUpdatingViewport = true
    defer { isUpdatingViewport = false }
    let offset = canvasView.contentOffset
    let scale = canvasView.zoomScale
    worldBounds = ContinuousCanvasGeometry.expandedBounds(
      retaining: worldBounds,
      drawing: drawingBounds,
      visible: ContinuousCanvasGeometry.visibleRect(offset: offset, size: bounds.size, zoom: scale)
    )
    // Insets expose negative world coordinates without translating the drawing.
    // PencilKit remains the only scroll/zoom owner, preserving its native undo history.
    let inset = UIEdgeInsets(
      top: -worldBounds.minY * scale, left: -worldBounds.minX * scale,
      bottom: 0, right: 0
    )
    let size = CGSize(width: worldBounds.maxX * scale, height: worldBounds.maxY * scale)
    if canvasView.contentInset != inset { canvasView.contentInset = inset }
    if canvasView.contentSize != size { canvasView.contentSize = size }
    if canvasView.contentOffset != offset { canvasView.contentOffset = offset }
    paperView.updateViewport(offset: offset, scale: scale)
  }

  private func applyPendingViewportIfPossible() {
    guard hasCompletedInitialLayout, let viewport = pendingViewport else { return }
    pendingViewport = nil
    worldBounds = viewport.worldBounds
    isUpdatingViewport = true
    canvasView.setZoomScale(
      min(max(viewport.zoomScale, canvasView.minimumZoomScale), canvasView.maximumZoomScale),
      animated: false
    )
    canvasView.contentOffset = viewport.contentOffset
    isUpdatingViewport = false
    viewportDidChange()
  }

  fileprivate func returnToDrawing() {
    guard hasCompletedInitialLayout else { return }
    // The union's upper-left corner may be empty when strokes are far apart.
    // Anchor to an actual stroke instead of sending the user to empty paper.
    let drawingBounds = canvasView.drawing.strokes.first?.renderBounds ?? .null
    let origin =
      drawingBounds.isNull || drawingBounds.isEmpty
      ? CGPoint.zero : CGPoint(x: drawingBounds.minX - 48, y: drawingBounds.minY - 48)
    isUpdatingViewport = true
    canvasView.setZoomScale(1, animated: false)
    canvasView.contentOffset = origin
    isUpdatingViewport = false
    viewportDidChange()
  }

}

@MainActor
private final class CanvasPaperView: UIView {
  private var viewportOffset = CGPoint.zero
  private var viewportScale: CGFloat = 1

  func updateViewport(offset: CGPoint, scale: CGFloat) {
    guard viewportOffset != offset || viewportScale != scale else { return }
    viewportOffset = offset
    viewportScale = scale
    setNeedsDisplay()
  }
  var pageBackground: PageBackground = .ruled {
    didSet {
      guard pageBackground != oldValue else { return }
      setNeedsDisplay()
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .systemBackground
    isOpaque = true
    contentMode = .redraw
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func draw(_ rect: CGRect) {
    super.draw(rect)
    guard let context = UIGraphicsGetCurrentContext() else { return }
    context.saveGState()
    defer { context.restoreGState() }
    context.translateBy(x: -viewportOffset.x, y: -viewportOffset.y)
    context.scaleBy(x: viewportScale, y: viewportScale)
    let worldRect = ContinuousCanvasGeometry.visibleRect(
      offset: CGPoint(x: viewportOffset.x + rect.minX, y: viewportOffset.y + rect.minY),
      size: rect.size, zoom: viewportScale
    )

    switch pageBackground {
    case .blank:
      return
    case .ruled:
      drawRuledPaper(in: context, dirtyRect: worldRect)
    case .grid:
      drawGridPaper(in: context, dirtyRect: worldRect)
    }
  }

  private func drawRuledPaper(in context: CGContext, dirtyRect: CGRect) {
    let spacing: CGFloat = 32
    context.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.16).cgColor)
    context.setLineWidth(0.7)
    var y = floor(dirtyRect.minY / spacing) * spacing
    while y <= dirtyRect.maxY {
      context.move(to: CGPoint(x: dirtyRect.minX, y: y))
      context.addLine(to: CGPoint(x: dirtyRect.maxX, y: y))
      y += spacing
    }
    context.strokePath()

    guard dirtyRect.minX <= 48, dirtyRect.maxX >= 48 else { return }
    context.setStrokeColor(UIColor.systemRed.withAlphaComponent(0.18).cgColor)
    context.setLineWidth(0.8)
    context.move(to: CGPoint(x: 48, y: dirtyRect.minY))
    context.addLine(to: CGPoint(x: 48, y: dirtyRect.maxY))
    context.strokePath()
  }

  private func drawGridPaper(in context: CGContext, dirtyRect: CGRect) {
    let spacing: CGFloat = 28
    context.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.13).cgColor)
    context.setLineWidth(0.6)

    var x = floor(dirtyRect.minX / spacing) * spacing
    while x <= dirtyRect.maxX {
      context.move(to: CGPoint(x: x, y: dirtyRect.minY))
      context.addLine(to: CGPoint(x: x, y: dirtyRect.maxY))
      x += spacing
    }
    var y = floor(dirtyRect.minY / spacing) * spacing
    while y <= dirtyRect.maxY {
      context.move(to: CGPoint(x: dirtyRect.minX, y: y))
      context.addLine(to: CGPoint(x: dirtyRect.maxX, y: y))
      y += spacing
    }
    context.strokePath()
  }
}
