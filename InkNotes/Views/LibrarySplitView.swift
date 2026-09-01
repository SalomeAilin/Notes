import SwiftUI

struct LibrarySplitView: View {
  @EnvironmentObject private var store: LibraryStore
  @Binding var pendingBackupImports: BackupImportQueue
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var namingAction: NamingAction?
  @State private var draftTitle = ""
  @State private var deletionTarget: DeletionTarget?
  @State private var deletionNotice: DeletionNotice?
  @State private var showingBackupTransfer = false
  @State private var backupImportPresentationCoordinator =
    BackupImportPresentationCoordinator()

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      notebookSidebar
    } content: {
      pageSidebar
    } detail: {
      PageEditorView()
    }
    .navigationSplitViewStyle(.balanced)
    .safeAreaInset(edge: .top) {
      if store.isReadOnly {
        Label(
          "只读保护已启用：本地数据读取失败，原文件不会被改写。",
          systemImage: "exclamationmark.shield.fill"
        )
        .font(.callout.weight(.semibold))
        .foregroundStyle(.orange)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
      }
    }
    .alert(
      namingAction?.title ?? "命名",
      isPresented: namingAlertIsPresented
    ) {
      TextField("名称", text: $draftTitle)
      Button("取消", role: .cancel) {
        namingAction = nil
      }
      Button(namingAction?.confirmationTitle ?? "保存") {
        performNamingAction()
      }
      .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .confirmationDialog(
      deletionTarget?.title ?? "确认删除",
      isPresented: deletionDialogIsPresented,
      titleVisibility: .visible
    ) {
      Button("删除", role: .destructive) {
        performDeletion()
      }
      Button("取消", role: .cancel) {
        deletionTarget = nil
      }
    } message: {
      Text("删除后可以立即撤销一次。关闭撤销提示后，如需找回，请从此前保存的备份导入。")
    }
    .alert(item: $deletionNotice) { notice in
      switch notice {
      case .undoAvailable(let target):
        Alert(
          title: Text("已删除\(target.kindName)“\(target.itemTitle)”"),
          message: Text("如果删错了，现在可以撤销。关闭这个提示后，如需找回，请从备份导入。"),
          primaryButton: .default(Text("撤销删除")) {
            undoDeletion(target)
          },
          secondaryButton: .cancel(Text("完成")) {
            store.discardLastDeletionUndo()
          }
        )
      case .restored(let target):
        Alert(
          title: Text("已撤销删除"),
          message: Text("\(target.kindName)“\(target.itemTitle)”已恢复到原来的位置。"),
          dismissButton: .default(Text("知道了"))
        )
      case .failed:
        Alert(
          title: Text("暂时无法撤销"),
          message: Text("为避免覆盖后来的修改，没有恢复这次删除。你仍可以从此前保存的备份导入。"),
          dismissButton: .default(Text("知道了"))
        )
      }
    }
    .alert("本地数据提示", isPresented: persistenceAlertIsPresented) {
      Button("知道了") {
        store.clearPersistenceError()
      }
    } message: {
      Text(store.persistenceError ?? "")
    }
    .onAppear {
      handleBackupImportPresentationEvent(.appeared)
    }
    .onChange(of: pendingBackupImports.current?.id) {
      handleBackupImportPresentationEvent(.queueChanged)
    }
    .onChange(of: backupImportPresentationState) {
      handleBackupImportPresentationEvent(.presentationStateChanged)
    }
    .sheet(
      isPresented: $showingBackupTransfer,
      onDismiss: {
        handleBackupImportPresentationEvent(.transferDismissed)
      },
      content: {
        BackupTransferView(importQueue: $pendingBackupImports)
          .environmentObject(store)
      }
    )
  }

  private var notebookSidebar: some View {
    Group {
      if store.isLoading {
        ProgressView("正在读取笔记…")
      } else {
        List {
          ForEach(store.notebooks) { notebook in
            Button {
              store.selectNotebook(notebook.id)
            } label: {
              HStack {
                Label(notebook.title, systemImage: "books.vertical")
                Spacer()
                Text("\(notebook.pages.count)")
                  .foregroundStyle(.secondary)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(selectionColor(notebook.id == store.selectedNotebookID))
            .contextMenu {
              Button("重命名", systemImage: "pencil") {
                beginNaming(.renameNotebook(notebook.id), currentTitle: notebook.title)
              }
              Button("删除", systemImage: "trash", role: .destructive) {
                deletionTarget = .notebook(notebook.id, notebook.title)
              }
            }
          }
        }
        .disabled(!store.canManageBackups)
      }
    }
    .navigationTitle("笔记本")
    .toolbar {
      ToolbarItem(placement: .secondaryAction) {
        Button {
          showingBackupTransfer = true
        } label: {
          Label("备份与恢复", systemImage: "externaldrive.badge.timemachine")
        }
        .disabled(!store.canManageBackups)
      }
      ToolbarItem(placement: .primaryAction) {
        Button {
          beginNaming(.addNotebook, currentTitle: "")
        } label: {
          Label("新建笔记本", systemImage: "plus")
        }
        .disabled(!store.canManageBackups)
      }
    }
  }

  private var pageSidebar: some View {
    Group {
      if let notebook = store.selectedNotebook {
        List {
          ForEach(notebook.pages) { page in
            Button {
              store.selectPage(page.id)
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Label(page.title, systemImage: "doc.text")
                Text(page.updatedAt, format: .dateTime.month().day().hour().minute())
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(selectionColor(page.id == store.selectedPageID))
            .contextMenu {
              Button("重命名", systemImage: "pencil") {
                beginNaming(.renamePage(page.id), currentTitle: page.title)
              }
              Button("删除", systemImage: "trash", role: .destructive) {
                deletionTarget = .page(page.id, page.title)
              }
            }
          }
        }
        .disabled(!store.canManageBackups)
      } else {
        ContentUnavailableView("没有页面", systemImage: "doc")
      }
    }
    .navigationTitle(store.selectedNotebook?.title ?? "页面")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          beginNaming(.addPage, currentTitle: "")
        } label: {
          Label("新建页面", systemImage: "doc.badge.plus")
        }
        .disabled(store.selectedNotebook == nil || !store.canManageBackups)
      }
    }
  }

  private func selectionColor(_ isSelected: Bool) -> Color {
    isSelected ? Color.accentColor.opacity(0.14) : .clear
  }

  private func handleBackupImportPresentationEvent(_ event: BackupImportPresentationEvent) {
    let command = backupImportPresentationCoordinator.handle(
      event,
      state: backupImportPresentationState
    )
    if command == .presentBackupTransfer {
      showingBackupTransfer = true
    }
  }

  private var backupImportPresentationState: BackupImportPresentationState {
    BackupImportPresentationState(
      hasQueuedImport: !pendingBackupImports.isEmpty,
      isLibraryLoading: store.isLoading,
      isDrawingLoading: store.isDrawingLoading,
      hasNamingAlert: namingAction != nil,
      hasDeletionDialog: deletionTarget != nil || deletionNotice != nil,
      hasPersistenceAlert: store.persistenceError != nil
    )
  }

  private var namingAlertIsPresented: Binding<Bool> {
    Binding(
      get: { namingAction != nil },
      set: { if !$0 { namingAction = nil } }
    )
  }

  private var deletionDialogIsPresented: Binding<Bool> {
    Binding(
      get: { deletionTarget != nil },
      set: { if !$0 { deletionTarget = nil } }
    )
  }

  private var persistenceAlertIsPresented: Binding<Bool> {
    Binding(
      get: { store.persistenceError != nil },
      set: { if !$0 { store.clearPersistenceError() } }
    )
  }

  private func beginNaming(_ action: NamingAction, currentTitle: String) {
    draftTitle = currentTitle
    namingAction = action
  }

  private func performNamingAction() {
    let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let action = namingAction, !title.isEmpty else { return }

    switch action {
    case .addNotebook:
      store.addNotebook(title: title)
    case .addPage:
      store.addPage(title: title)
    case .renameNotebook(let id):
      store.renameNotebook(id: id, title: title)
    case .renamePage(let id):
      store.renamePage(id: id, title: title)
    }
    namingAction = nil
  }

  private func performDeletion() {
    guard let target = deletionTarget else { return }
    let didDelete: Bool
    switch target {
    case .notebook(let id, _):
      didDelete = store.deleteNotebook(id: id)
    case .page(let id, _):
      didDelete = store.deletePage(id: id)
    }
    deletionTarget = nil
    if didDelete {
      deletionNotice = .undoAvailable(target)
    }
  }

  private func undoDeletion(_ target: DeletionTarget) {
    Task {
      if await store.undoLastDeletion() {
        deletionNotice = .restored(target)
      } else {
        deletionNotice = .failed
      }
    }
  }
}

private enum NamingAction {
  case addNotebook
  case addPage
  case renameNotebook(UUID)
  case renamePage(UUID)

  var title: String {
    switch self {
    case .addNotebook: "新建笔记本"
    case .addPage: "新建页面"
    case .renameNotebook: "重命名笔记本"
    case .renamePage: "重命名页面"
    }
  }

  var confirmationTitle: String {
    switch self {
    case .addNotebook, .addPage: "创建"
    case .renameNotebook, .renamePage: "保存"
    }
  }
}

private enum DeletionTarget {
  case notebook(UUID, String)
  case page(UUID, String)

  var title: String {
    switch self {
    case .notebook(_, let title): "删除笔记本“\(title)”？"
    case .page(_, let title): "删除页面“\(title)”？"
    }
  }

  var kindName: String {
    switch self {
    case .notebook: "笔记本"
    case .page: "页面"
    }
  }

  var itemTitle: String {
    switch self {
    case .notebook(_, let title), .page(_, let title): title
    }
  }
}

private enum DeletionNotice: Identifiable {
  case undoAvailable(DeletionTarget)
  case restored(DeletionTarget)
  case failed

  var id: String {
    switch self {
    case .undoAvailable(let target): "undo-\(target.itemTitle)"
    case .restored(let target): "restored-\(target.itemTitle)"
    case .failed: "failed"
    }
  }
}
