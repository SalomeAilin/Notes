import SwiftUI

struct LibrarySplitView: View {
  @EnvironmentObject private var store: LibraryStore
  @Binding var pendingBackupImports: BackupImportQueue
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var namingAction: NamingAction?
  @State private var draftTitle = ""
  @State private var deletionTarget: DeletionTarget?
  @State private var showingBackupTransfer = false

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
      Text("笔迹文件会保留在应用沙盒中，当前版本暂不提供恢复入口。")
    }
    .alert("本地数据提示", isPresented: persistenceAlertIsPresented) {
      Button("知道了") {
        store.clearPersistenceError()
      }
    } message: {
      Text(store.persistenceError ?? "")
    }
    .onAppear {
      presentPendingBackupImportIfPossible()
    }
    .onChange(of: pendingBackupImports.current?.id) {
      presentPendingBackupImportIfPossible()
    }
    .onChange(of: canPresentQueuedBackupImport) {
      presentPendingBackupImportIfPossible()
    }
    .sheet(isPresented: $showingBackupTransfer) {
      BackupTransferView(importQueue: $pendingBackupImports)
        .environmentObject(store)
    }
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
        .disabled(store.isDrawingLoading || store.isBackupTransferInProgress)
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
        .disabled(store.isDrawingLoading || store.isBackupTransferInProgress)
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

  private func presentPendingBackupImportIfPossible() {
    guard !pendingBackupImports.isEmpty, canPresentQueuedBackupImport else { return }
    showingBackupTransfer = true
  }

  private var canPresentQueuedBackupImport: Bool {
    !store.isLoading && !store.isDrawingLoading && namingAction == nil
      && deletionTarget == nil && store.persistenceError == nil
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
    switch target {
    case .notebook(let id, _):
      store.deleteNotebook(id: id)
    case .page(let id, _):
      store.deletePage(id: id)
    }
    deletionTarget = nil
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
}
