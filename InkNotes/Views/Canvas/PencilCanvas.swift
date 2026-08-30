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

@MainActor
final class PencilCanvasController: ObservableObject {
  private weak var canvasView: PKCanvasView?
  private let toolPicker: PKToolPicker

  init() {
    let toolPicker = PKToolPicker()
    toolPicker.maximumSupportedContentVersion = .version2
    toolPicker.showsDrawingPolicyControls = false
    self.toolPicker = toolPicker
  }

  func attach(_ canvasView: PKCanvasView) {
    self.canvasView = canvasView
    toolPicker.addObserver(canvasView)
  }

  func detach(_ canvasView: PKCanvasView) {
    toolPicker.setVisible(false, forFirstResponder: canvasView)
    canvasView.resignFirstResponder()
    toolPicker.removeObserver(canvasView)
    guard self.canvasView === canvasView else { return }
    self.canvasView = nil
  }

  func setToolPickerVisible(_ isVisible: Bool, for canvasView: PKCanvasView) {
    guard self.canvasView === canvasView else { return }
    toolPicker.setVisible(isVisible, forFirstResponder: canvasView)
    if isVisible {
      canvasView.becomeFirstResponder()
    } else {
      canvasView.resignFirstResponder()
    }
  }

  func undo() {
    canvasView?.undoManager?.undo()
  }

  func redo() {
    canvasView?.undoManager?.redo()
  }
}

struct PencilCanvas: UIViewRepresentable {
  @Binding var drawingData: Data
  let inputPolicy: CanvasInputPolicy
  let isEditable: Bool
  @ObservedObject var controller: PencilCanvasController

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeUIView(context: Context) -> PKCanvasView {
    let canvasView = PKCanvasView(frame: .zero)
    canvasView.delegate = context.coordinator
    canvasView.backgroundColor = .clear
    canvasView.isOpaque = false
    canvasView.isUserInteractionEnabled = isEditable
    canvasView.drawingPolicy = inputPolicy.drawingPolicy
    canvasView.maximumSupportedContentVersion = .version2
    canvasView.drawing = Self.decodeDrawing(drawingData)
    canvasView.alwaysBounceHorizontal = false
    canvasView.alwaysBounceVertical = false
    canvasView.contentInsetAdjustmentBehavior = .never

    controller.attach(canvasView)

    DispatchQueue.main.async {
      let shouldShowTools = context.coordinator.parent.isEditable
      context.coordinator.parent.controller.setToolPickerVisible(
        shouldShowTools,
        for: canvasView
      )
    }
    return canvasView
  }

  func updateUIView(_ canvasView: PKCanvasView, context: Context) {
    context.coordinator.parent = self
    canvasView.drawingPolicy = inputPolicy.drawingPolicy
    if canvasView.isUserInteractionEnabled != isEditable {
      canvasView.isUserInteractionEnabled = isEditable
      controller.setToolPickerVisible(isEditable, for: canvasView)
    }

    let currentData = canvasView.drawing.dataRepresentation()
    guard currentData != drawingData,
      !context.coordinator.isApplyingExternalDrawing
    else { return }

    context.coordinator.isApplyingExternalDrawing = true
    canvasView.drawing = Self.decodeDrawing(drawingData)
    context.coordinator.isApplyingExternalDrawing = false
  }

  static func dismantleUIView(_ canvasView: PKCanvasView, coordinator: Coordinator) {
    coordinator.parent.controller.detach(canvasView)
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

    init(parent: PencilCanvas) {
      self.parent = parent
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
      guard !isApplyingExternalDrawing else { return }
      let data = canvasView.drawing.dataRepresentation()
      if parent.drawingData != data {
        parent.drawingData = data
      }
    }
  }
}
