import Combine
import Foundation
import PencilKit

private enum LibraryStoreError: LocalizedError {
  case backupUnavailable

  var errorDescription: String? {
    switch self {
    case .backupUnavailable:
      "当前正在读取、保存或保护笔记，请稍后再试。"
    }
  }
}

struct BackupExportResult: Equatable, Sendable {
  let data: Data
  let createdAt: Date
  let notebookCount: Int
  let pageCount: Int
}

@MainActor
final class LibraryStore: ObservableObject {
  @Published private(set) var library = LibraryDocument.starter()
  @Published private(set) var selectedNotebookID: UUID?
  @Published private(set) var selectedPageID: UUID?
  @Published private(set) var currentDrawingData = Data()
  @Published private(set) var isLoading = true
  @Published private(set) var isDrawingLoading = false
  @Published private(set) var isReadOnly = false
  @Published private(set) var isBackupTransferInProgress = false
  @Published private(set) var persistenceError: String?

  private let repository: DrawingRepository
  private var drawingSaveTask: Task<Void, Never>?
  private var librarySaveTask: Task<Void, Never>?
  private var drawingTransitionTask: Task<Void, Never>?
  private var backupTransferWaiters: [CheckedContinuation<Void, Never>] = []
  private var unsavedDrawings: [UUID: Data] = [:]

  init(repository: DrawingRepository = DrawingRepository()) {
    self.repository = repository
    Task { [weak self] in
      await self?.load()
    }
  }

  var notebooks: [Notebook] { library.notebooks }

  var selectedNotebook: Notebook? {
    library.notebooks.first { $0.id == selectedNotebookID }
  }

  var selectedPage: NotePage? {
    selectedNotebook?.pages.first { $0.id == selectedPageID }
  }

  var canManageBackups: Bool {
    !isLoading && !isDrawingLoading && !isReadOnly && !isBackupTransferInProgress
  }

  func selectNotebook(_ id: UUID) {
    guard !isLoading, !isDrawingLoading, !isBackupTransferInProgress,
      id != selectedNotebookID
    else { return }
    guard let notebook = library.notebooks.first(where: { $0.id == id }),
      let page = notebook.pages.first
    else { return }

    let previousPageID = selectedPageID
    let previousDrawing = currentDrawingData
    selectedNotebookID = id
    selectedPageID = page.id
    transitionDrawing(
      from: previousPageID,
      previousDrawing: previousDrawing,
      to: page.id
    )
  }

  func selectPage(_ id: UUID) {
    guard !isLoading, !isDrawingLoading, !isBackupTransferInProgress,
      id != selectedPageID
    else { return }
    guard selectedNotebook?.pages.contains(where: { $0.id == id }) == true else { return }

    let previousPageID = selectedPageID
    let previousDrawing = currentDrawingData
    selectedPageID = id
    transitionDrawing(
      from: previousPageID,
      previousDrawing: previousDrawing,
      to: id
    )
  }

  func addNotebook(title: String? = nil) {
    guard canEdit else { return }
    guard library.notebooks.count < BackupArchiveLimits.maximumNotebookCount else {
      persistenceError = "笔记本数量已达到备份格式上限（\(BackupArchiveLimits.maximumNotebookCount) 个）。"
      return
    }
    let notebookTitle: String
    if let title {
      guard let cleanedTitle = cleaned(title) else { return }
      notebookTitle = cleanedTitle
    } else {
      notebookTitle = uniqueNotebookTitle()
    }
    let page = NotePage(title: "第 1 页")
    let notebook = Notebook(title: notebookTitle, pages: [page])
    let previousPageID = selectedPageID
    let previousDrawing = currentDrawingData
    var candidate = library
    candidate.notebooks.append(notebook)

    guard acceptManifestCandidate(candidate) else { return }
    selectedNotebookID = notebook.id
    selectedPageID = page.id
    scheduleLibrarySave()
    transitionDrawing(
      from: previousPageID,
      previousDrawing: previousDrawing,
      to: page.id
    )
  }

  func addPage(title: String? = nil) {
    guard canEdit, let notebookIndex = selectedNotebookIndex else { return }
    let pageCount = library.notebooks.reduce(0) { $0 + $1.pages.count }
    guard pageCount < BackupArchiveLimits.maximumPageCount else {
      persistenceError = "页面数量已达到备份格式上限（\(BackupArchiveLimits.maximumPageCount) 页）。"
      return
    }
    let nextNumber = library.notebooks[notebookIndex].pages.count + 1
    let pageTitle: String
    if let title {
      guard let cleanedTitle = cleaned(title) else { return }
      pageTitle = cleanedTitle
    } else {
      pageTitle = "第 \(nextNumber) 页"
    }
    let page = NotePage(title: pageTitle)
    let previousPageID = selectedPageID
    let previousDrawing = currentDrawingData
    var candidate = library
    candidate.notebooks[notebookIndex].pages.append(page)
    candidate.notebooks[notebookIndex].updatedAt = Date()

    guard acceptManifestCandidate(candidate) else { return }
    selectedPageID = page.id
    scheduleLibrarySave()
    transitionDrawing(
      from: previousPageID,
      previousDrawing: previousDrawing,
      to: page.id
    )
  }

  func renameNotebook(id: UUID, title: String) {
    guard canEdit, let title = cleaned(title),
      let index = library.notebooks.firstIndex(where: { $0.id == id })
    else { return }
    var candidate = library
    candidate.notebooks[index].title = title
    candidate.notebooks[index].updatedAt = Date()
    guard acceptManifestCandidate(candidate, allowNonGrowingOverLimit: true) else { return }
    scheduleLibrarySave()
  }

  func renamePage(id: UUID, title: String) {
    guard canEdit, let title = cleaned(title),
      let location = pageLocation(id: id)
    else { return }
    var candidate = library
    candidate.notebooks[location.notebook].pages[location.page].title = title
    Self.touch(
      library: &candidate,
      notebookAt: location.notebook,
      pageAt: location.page
    )
    guard acceptManifestCandidate(candidate, allowNonGrowingOverLimit: true) else { return }
    scheduleLibrarySave()
  }

  func deleteNotebook(id: UUID) {
    guard canEdit,
      let index = library.notebooks.firstIndex(where: { $0.id == id })
    else { return }

    let deletingSelection = selectedNotebookID == id
    let previousPageID = deletingSelection ? selectedPageID : nil
    let previousDrawing = deletingSelection ? currentDrawingData : Data()
    var candidate = library
    candidate.notebooks.remove(at: index)

    if candidate.notebooks.isEmpty {
      candidate = .starter()
    }
    guard acceptManifestCandidate(candidate, allowNonGrowingOverLimit: true) else { return }

    if deletingSelection,
      let notebook = library.notebooks.first,
      let page = notebook.pages.first
    {
      selectedNotebookID = notebook.id
      selectedPageID = page.id
      transitionDrawing(
        from: previousPageID,
        previousDrawing: previousDrawing,
        to: page.id
      )
    }
    scheduleLibrarySave()
  }

  func deletePage(id: UUID) {
    guard canEdit, let location = pageLocation(id: id) else { return }

    let deletingSelection = selectedPageID == id
    let previousDrawing = deletingSelection ? currentDrawingData : Data()
    var candidate = library
    candidate.notebooks[location.notebook].pages.remove(at: location.page)

    if candidate.notebooks[location.notebook].pages.isEmpty {
      candidate.notebooks[location.notebook].pages = [NotePage(title: "第 1 页")]
    }
    candidate.notebooks[location.notebook].updatedAt = Date()
    guard acceptManifestCandidate(candidate, allowNonGrowingOverLimit: true) else { return }

    if deletingSelection,
      let page = library.notebooks[location.notebook].pages.first
    {
      selectedPageID = page.id
      transitionDrawing(
        from: id,
        previousDrawing: previousDrawing,
        to: page.id
      )
    }
    scheduleLibrarySave()
  }

  func updateCurrentDrawing(_ data: Data) {
    guard canEdit, !isDrawingLoading, data != currentDrawingData,
      let pageID = selectedPageID,
      let location = pageLocation(id: pageID)
    else { return }

    currentDrawingData = data
    unsavedDrawings[pageID] = data
    touch(notebookAt: location.notebook, pageAt: location.page)
    scheduleDrawingSave(data, pageID: pageID)
    scheduleLibrarySave()
  }

  func clearCurrentDrawing() {
    updateCurrentDrawing(Data())
  }

  func setCurrentPageBackground(_ background: PageBackground) {
    guard canEdit, let pageID = selectedPageID,
      let location = pageLocation(id: pageID)
    else { return }
    var candidate = library
    candidate.notebooks[location.notebook].pages[location.page].background = background
    Self.touch(
      library: &candidate,
      notebookAt: location.notebook,
      pageAt: location.page
    )
    guard acceptManifestCandidate(candidate, allowNonGrowingOverLimit: true) else { return }
    scheduleLibrarySave()
  }

  func clearPersistenceError() {
    persistenceError = nil
  }

  func makeBackup() async throws -> BackupExportResult {
    try beginBackupTransfer()
    defer { finishBackupTransfer() }
    await finishScheduledPersistence()

    let snapshot = library
    let drawingOverrides = drawingOverridesForBackupSnapshot()
    let createdAt = Date()
    let data = try await repository.makeBackup(
      library: snapshot,
      drawingOverrides: drawingOverrides,
      sourceAppVersion: bundleValue("CFBundleShortVersionString"),
      sourceBuild: bundleValue("CFBundleVersion"),
      createdAt: createdAt
    )
    clearSavedDrawings(matching: drawingOverrides)

    return BackupExportResult(
      data: data,
      createdAt: createdAt,
      notebookCount: snapshot.notebooks.count,
      pageCount: snapshot.notebooks.reduce(0) { $0 + $1.pages.count }
    )
  }

  func inspectBackup(_ data: Data) async throws -> BackupArchivePreview {
    try beginBackupTransfer()
    defer { finishBackupTransfer() }
    return try await repository.inspectBackup(data)
  }

  func importBackupAsCopy(_ data: Data) async throws -> BackupRestoreResult {
    try beginBackupTransfer()
    defer { finishBackupTransfer() }
    await finishScheduledPersistence()

    let drawingOverrides = unsavedDrawingOverrides()
    let result = try await repository.restoreBackupAsCopy(
      data,
      currentLibrary: library,
      currentDrawingOverrides: drawingOverrides
    )

    library = result.library
    if result.disposition == .imported {
      selectedNotebookID = result.selectedNotebookID
      selectedPageID = result.selectedPageID
      currentDrawingData = result.selectedDrawingData
    } else if let pageID = selectedPageID, result.repairedPageIDs.contains(pageID) {
      currentDrawingData = try await validatedDrawingData(pageID: pageID)
    }
    unsavedDrawings.removeAll()
    persistenceError = nil
    return result
  }

  func flush() async {
    await waitForBackupTransferToFinish()
    await finishScheduledPersistence()
    guard !isLoading else { return }

    var drawingsToSave = unsavedDrawings
    if !isReadOnly, !isDrawingLoading, let pageID = selectedPageID {
      drawingsToSave[pageID] = currentDrawingData
    }

    for (pageID, data) in drawingsToSave {
      do {
        try await repository.saveDrawingForEditing(data, pageID: pageID)
        if unsavedDrawings[pageID] == data {
          unsavedDrawings.removeValue(forKey: pageID)
        }
      } catch {
        report(error, prefix: "笔迹保存失败")
      }
    }

    guard !isReadOnly else { return }
    do {
      try await repository.saveLibrary(library)
    } catch {
      report(error, prefix: "目录保存失败")
    }
  }

  private var canEdit: Bool {
    canManageBackups
  }

  private var selectedNotebookIndex: Int? {
    library.notebooks.firstIndex { $0.id == selectedNotebookID }
  }

  private func load() async {
    isLoading = true
    do {
      if let existing = try await repository.loadLibrary() {
        library = existing
      } else {
        library = .starter()
        try await repository.saveLibrary(library)
      }

      selectedNotebookID = library.notebooks.first?.id
      selectedPageID = library.notebooks.first?.pages.first?.id
      if let pageID = selectedPageID {
        currentDrawingData = try await validatedDrawingData(pageID: pageID)
      }
      isLoading = false
    } catch {
      isReadOnly = true
      isLoading = false
      selectedNotebookID = library.notebooks.first?.id
      selectedPageID = library.notebooks.first?.pages.first?.id
      report(error, prefix: "无法读取本地笔记")
    }
  }

  private func transitionDrawing(
    from previousPageID: UUID?,
    previousDrawing: Data,
    to nextPageID: UUID
  ) {
    drawingSaveTask?.cancel()
    let shouldSavePrevious = !isReadOnly
    isDrawingLoading = true
    currentDrawingData = Data()

    drawingTransitionTask = Task { [weak self, repository] in
      guard let self else { return }
      defer { drawingTransitionTask = nil }

      if shouldSavePrevious, let previousPageID {
        do {
          try await repository.saveDrawingForEditing(previousDrawing, pageID: previousPageID)
          if unsavedDrawings[previousPageID] == previousDrawing {
            unsavedDrawings.removeValue(forKey: previousPageID)
          }
        } catch {
          unsavedDrawings[previousPageID] = previousDrawing
          report(error, prefix: "上一页保存失败")
        }
      }

      do {
        let loaded = try await validatedDrawingData(pageID: nextPageID)
        guard selectedPageID == nextPageID else { return }
        currentDrawingData = loaded
        isDrawingLoading = false
      } catch {
        isReadOnly = true
        isDrawingLoading = false
        report(error, prefix: "页面载入失败")
      }
    }
  }

  private func scheduleDrawingSave(_ data: Data, pageID: UUID) {
    drawingSaveTask?.cancel()
    drawingSaveTask = Task { [weak self, repository] in
      do {
        try await Task.sleep(for: .milliseconds(400))
        try Task.checkCancellation()
        try await repository.saveDrawingForEditing(data, pageID: pageID)
        if self?.unsavedDrawings[pageID] == data {
          self?.unsavedDrawings.removeValue(forKey: pageID)
        }
      } catch is CancellationError {
        return
      } catch {
        self?.report(error, prefix: "笔迹保存失败")
      }
    }
  }

  private func scheduleLibrarySave() {
    let snapshot = library
    librarySaveTask?.cancel()
    librarySaveTask = Task { [weak self, repository] in
      do {
        try await Task.sleep(for: .milliseconds(400))
        try Task.checkCancellation()
        try await repository.saveLibrary(snapshot)
      } catch is CancellationError {
        return
      } catch {
        self?.report(error, prefix: "目录保存失败")
      }
    }
  }

  private func beginBackupTransfer() throws {
    guard canManageBackups else {
      throw LibraryStoreError.backupUnavailable
    }
    isBackupTransferInProgress = true
  }

  private func finishBackupTransfer() {
    isBackupTransferInProgress = false
    let waiters = backupTransferWaiters
    backupTransferWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  private func waitForBackupTransferToFinish() async {
    guard isBackupTransferInProgress else { return }
    await withCheckedContinuation { continuation in
      backupTransferWaiters.append(continuation)
    }
  }

  private func finishScheduledPersistence() async {
    let pendingDrawingSave = drawingSaveTask
    let pendingLibrarySave = librarySaveTask
    drawingSaveTask = nil
    librarySaveTask = nil
    pendingDrawingSave?.cancel()
    pendingLibrarySave?.cancel()
    await pendingDrawingSave?.value
    await pendingLibrarySave?.value
    await drawingTransitionTask?.value
  }

  private func drawingOverridesForBackupSnapshot() -> [UUID: Data] {
    let currentPageIDs = Set(library.notebooks.flatMap(\.pages).map(\.id))
    var drawings = unsavedDrawingOverrides(currentPageIDs: currentPageIDs)
    if !isReadOnly, !isDrawingLoading, let pageID = selectedPageID,
      currentPageIDs.contains(pageID)
    {
      drawings[pageID] = currentDrawingData
    }
    return drawings
  }

  private func unsavedDrawingOverrides() -> [UUID: Data] {
    let currentPageIDs = Set(library.notebooks.flatMap(\.pages).map(\.id))
    return unsavedDrawingOverrides(currentPageIDs: currentPageIDs)
  }

  private func unsavedDrawingOverrides(currentPageIDs: Set<UUID>) -> [UUID: Data] {
    unsavedDrawings.filter { currentPageIDs.contains($0.key) }
  }

  private func clearSavedDrawings(matching savedDrawings: [UUID: Data]) {
    for (pageID, data) in savedDrawings where unsavedDrawings[pageID] == data {
      unsavedDrawings.removeValue(forKey: pageID)
    }
  }

  private func bundleValue(_ key: String) -> String {
    Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
  }

  private func validatedDrawingData(pageID: UUID) async throws -> Data {
    let data = try await repository.loadDrawing(pageID: pageID) ?? Data()
    if !data.isEmpty {
      _ = try PKDrawing(data: data)
    }
    return data
  }

  private func touch(notebookAt notebookIndex: Int, pageAt pageIndex: Int) {
    Self.touch(library: &library, notebookAt: notebookIndex, pageAt: pageIndex)
  }

  private static func touch(
    library: inout LibraryDocument,
    notebookAt notebookIndex: Int,
    pageAt pageIndex: Int
  ) {
    let now = Date()
    library.notebooks[notebookIndex].pages[pageIndex].updatedAt = now
    library.notebooks[notebookIndex].updatedAt = now
  }

  private func acceptManifestCandidate(
    _ candidate: LibraryDocument,
    allowNonGrowingOverLimit: Bool = false
  ) -> Bool {
    do {
      let candidateByteCount = try BackupArchiveCodec.projectedManifestByteCount(for: candidate)
      if candidateByteCount <= BackupArchiveLimits.maximumManifestByteCount {
        library = candidate
        return true
      }

      if allowNonGrowingOverLimit {
        let currentByteCount = try BackupArchiveCodec.projectedManifestByteCount(for: library)
        if candidateByteCount <= currentByteCount {
          library = candidate
          return true
        }
      }

      throw BackupArchiveError.manifestTooLarge(
        actual: candidateByteCount,
        maximum: BackupArchiveLimits.maximumManifestByteCount
      )
    } catch {
      report(error, prefix: "无法完成操作")
      return false
    }
  }

  private func pageLocation(id: UUID) -> (notebook: Int, page: Int)? {
    for notebookIndex in library.notebooks.indices {
      if let pageIndex = library.notebooks[notebookIndex].pages.firstIndex(where: { $0.id == id }) {
        return (notebookIndex, pageIndex)
      }
    }
    return nil
  }

  private func cleaned(_ text: String?) -> String? {
    guard let text else { return nil }
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return nil }
    guard cleaned.utf8.count <= BackupArchiveLimits.maximumTitleUTF8ByteCount else {
      persistenceError = "名称过长：最多允许 \(BackupArchiveLimits.maximumTitleUTF8ByteCount) 个 UTF-8 字节。"
      return nil
    }
    return cleaned
  }

  private func uniqueNotebookTitle() -> String {
    let base = "新笔记本"
    let names = Set(library.notebooks.map(\.title))
    guard names.contains(base) else { return base }
    var number = 2
    while names.contains("\(base) \(number)") {
      number += 1
    }
    return "\(base) \(number)"
  }

  private func report(_ error: Error, prefix: String) {
    persistenceError = "\(prefix)：\(error.localizedDescription)"
  }
}
