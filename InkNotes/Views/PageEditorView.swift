import SwiftUI

struct PageEditorView: View {
  @EnvironmentObject private var store: LibraryStore
  @StateObject private var canvasController = PencilCanvasController()
  @AppStorage("pencilOnly") private var pencilOnly = true
  @State private var showingClearConfirmation = false

  var body: some View {
    Group {
      if store.isDrawingLoading {
        ProgressView("正在打开页面…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let page = store.selectedPage {
        editor(for: page)
      } else {
        ContentUnavailableView(
          "请选择页面",
          systemImage: "doc.text",
          description: Text("从左侧选择一个笔记本和页面。")
        )
      }
    }
    .background(Color(uiColor: .secondarySystemBackground))
    .toolbar { editorToolbar }
    .confirmationDialog(
      "清空当前页的全部笔迹？",
      isPresented: $showingClearConfirmation,
      titleVisibility: .visible
    ) {
      Button("清空笔迹", role: .destructive) {
        store.clearCurrentDrawing()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("此操作不能撤销。")
    }
  }

  private func editor(for page: NotePage) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color(uiColor: .systemBackground))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)

      PencilCanvas(
        drawingData: Binding(
          get: { store.currentDrawingData },
          set: { store.updateCurrentDrawing($0) }
        ),
        pageID: page.id,
        background: page.background,
        inputPolicy: pencilOnly ? .pencilOnly : .anyInput,
        isEditable: !store.isReadOnly && !store.isBackupTransferInProgress,
        controller: canvasController
      )
      .id(page.id)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .padding(20)
    .navigationTitle(page.title)
    .navigationBarTitleDisplayMode(.inline)
  }

  @ToolbarContentBuilder
  private var editorToolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      Button {
        canvasController.undo()
      } label: {
        Label("撤销", systemImage: "arrow.uturn.backward")
      }
      .disabled(store.isReadOnly || store.isBackupTransferInProgress)

      Button {
        canvasController.redo()
      } label: {
        Label("重做", systemImage: "arrow.uturn.forward")
      }
      .disabled(store.isReadOnly || store.isBackupTransferInProgress)

      Menu {
        ForEach(PageBackground.allCases) { background in
          Button {
            store.setCurrentPageBackground(background)
          } label: {
            Label(background.title, systemImage: background.systemImage)
          }
        }
      } label: {
        Label("纸张", systemImage: "square.grid.3x3")
      }
      .disabled(store.isReadOnly || store.isBackupTransferInProgress)

      Button {
        pencilOnly.toggle()
      } label: {
        Label(
          pencilOnly ? "仅 Apple Pencil" : "手指也可书写",
          systemImage: pencilOnly ? "pencil.tip" : "hand.draw"
        )
      }
      .disabled(store.isReadOnly || store.isBackupTransferInProgress)

      Button(role: .destructive) {
        showingClearConfirmation = true
      } label: {
        Label("清空当前页", systemImage: "trash")
      }
      .disabled(
        store.selectedPage == nil || store.isReadOnly || store.isBackupTransferInProgress
      )
    }
  }
}
