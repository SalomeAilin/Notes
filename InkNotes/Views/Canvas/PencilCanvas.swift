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
    canvasHost.updateConfiguration(
      background: background,
      inputPolicy: inputPolicy,
      isEditable: isEditable
    )
    if canvasHost.canvasView.isUserInteractionEnabled != isEditable {
      canvasHost.canvasView.isUserInteractionEnabled = isEditable
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
  }
}

@MainActor
final class ExpandablePencilCanvasView: UIView, UIScrollViewDelegate {
  fileprivate let canvasView = PKCanvasView(frame: .zero)

  private let scrollView = UIScrollView(frame: .zero)
  private let contentView = UIView(frame: .zero)
  private let paperView = CanvasPaperView(frame: .zero)
  private var contentHeight: CGFloat = 0
  private var pendingViewport: CanvasViewport?
  private var hasCompletedInitialLayout = false

  override init(frame: CGRect) {
    super.init(frame: frame)

    backgroundColor = .secondarySystemBackground
    clipsToBounds = true

    scrollView.delegate = self
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.alwaysBounceVertical = true
    scrollView.alwaysBounceHorizontal = false
    scrollView.isDirectionalLockEnabled = true
    scrollView.keyboardDismissMode = .interactive
    scrollView.minimumZoomScale = 0.65
    scrollView.maximumZoomScale = 3
    scrollView.decelerationRate = .fast
    scrollView.showsHorizontalScrollIndicator = false
    addSubview(scrollView)

    contentView.layer.shadowColor = UIColor.black.cgColor
    contentView.layer.shadowOpacity = 0.08
    contentView.layer.shadowRadius = 12
    contentView.layer.shadowOffset = CGSize(width: 0, height: 4)
    scrollView.addSubview(contentView)

    paperView.isUserInteractionEnabled = false
    contentView.addSubview(paperView)

    canvasView.backgroundColor = .clear
    canvasView.isOpaque = false
    canvasView.maximumSupportedContentVersion = .version2
    canvasView.isScrollEnabled = false
    canvasView.alwaysBounceHorizontal = false
    canvasView.alwaysBounceVertical = false
    canvasView.contentInsetAdjustmentBehavior = .never
    canvasView.minimumZoomScale = 1
    canvasView.maximumZoomScale = 1
    canvasView.pinchGestureRecognizer?.isEnabled = false
    contentView.addSubview(canvasView)

    accessibilityLabel = "连续书写页面"
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    scrollView.frame = bounds
    guard bounds.width > 0, bounds.height > 0 else { return }

    let minimumHeight = ContinuousCanvasGeometry.minimumContentHeight(
      viewportHeight: bounds.height
    )
    let drawingHeight = ContinuousCanvasGeometry.requiredContentHeight(
      drawingMaximumY: canvasView.drawing.bounds.maxY,
      viewportHeight: bounds.height
    )
    contentHeight = max(contentHeight, minimumHeight, drawingHeight)
    layoutContent()

    if !hasCompletedInitialLayout {
      hasCompletedInitialLayout = true
      applyPendingViewportIfPossible()
    }
  }

  fileprivate var currentViewport: CanvasViewport {
    CanvasViewport(
      contentOffset: scrollView.contentOffset,
      zoomScale: scrollView.zoomScale
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
    scrollView.panGestureRecognizer.minimumNumberOfTouches =
      inputPolicy == .anyInput ? 2 : 1
  }

  fileprivate func applyExternalDrawing(_ drawing: PKDrawing) {
    canvasView.drawing = drawing
    expandToFitDrawing()
  }

  fileprivate func expandToFitDrawing() {
    guard bounds.height > 0 else {
      setNeedsLayout()
      return
    }
    let requiredHeight = ContinuousCanvasGeometry.requiredContentHeight(
      drawingMaximumY: canvasView.drawing.bounds.maxY,
      viewportHeight: bounds.height
    )
    guard requiredHeight > contentHeight else { return }
    contentHeight = requiredHeight
    layoutContent()
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    contentView
  }

  func scrollViewDidZoom(_ scrollView: UIScrollView) {
    centerPaperHorizontally()
  }

  private func layoutContent() {
    let contentSize = CGSize(width: bounds.width, height: contentHeight)
    contentView.frame = CGRect(origin: .zero, size: contentSize)
    paperView.frame = contentView.bounds
    canvasView.frame = contentView.bounds
    canvasView.contentSize = contentSize
    scrollView.contentSize = contentSize
    centerPaperHorizontally()
    paperView.setNeedsDisplay()
  }

  private func centerPaperHorizontally() {
    let scaledWidth = contentView.bounds.width * scrollView.zoomScale
    let horizontalInset = max(0, (scrollView.bounds.width - scaledWidth) / 2)
    scrollView.contentInset = UIEdgeInsets(
      top: 0,
      left: horizontalInset,
      bottom: 28,
      right: horizontalInset
    )
  }

  private func applyPendingViewportIfPossible() {
    guard hasCompletedInitialLayout, let viewport = pendingViewport else { return }
    pendingViewport = nil
    let zoomScale = min(
      max(viewport.zoomScale, scrollView.minimumZoomScale),
      scrollView.maximumZoomScale
    )
    scrollView.setZoomScale(zoomScale, animated: false)
    let minimumX = -scrollView.adjustedContentInset.left
    let minimumY = -scrollView.adjustedContentInset.top
    let maximumX = max(
      minimumX,
      contentView.bounds.width * zoomScale - scrollView.bounds.width
        + scrollView.adjustedContentInset.right
    )
    let maximumY = max(
      minimumY,
      contentView.bounds.height * zoomScale - scrollView.bounds.height
        + scrollView.adjustedContentInset.bottom
    )
    let restoredOffset = CGPoint(
      x: min(max(viewport.contentOffset.x, minimumX), maximumX),
      y: min(max(viewport.contentOffset.y, minimumY), maximumY)
    )
    scrollView.setContentOffset(restoredOffset, animated: false)
  }

}

@MainActor
private final class CanvasPaperView: UIView {
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
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func draw(_ rect: CGRect) {
    super.draw(rect)
    guard let context = UIGraphicsGetCurrentContext() else { return }

    switch pageBackground {
    case .blank:
      return
    case .ruled:
      drawRuledPaper(in: context, dirtyRect: rect)
    case .grid:
      drawGridPaper(in: context, dirtyRect: rect)
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
