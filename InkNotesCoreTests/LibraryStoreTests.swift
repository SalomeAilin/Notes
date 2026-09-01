import Foundation
import PencilKit
import Testing

@testable import InkNotesCore

@Suite("InkNotes store sequencing")
struct LibraryStoreTests {
  @Test("Switching pages flushes the previous page before loading the next")
  @MainActor
  func pageTransitionPersistsPreviousDrawing() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let repository = DrawingRepository(rootURL: rootURL)
    let store = LibraryStore(repository: repository)
    try await waitUntil { !store.isLoading }

    let firstPageID = try #require(store.selectedPageID)
    let drawing = PKDrawing().dataRepresentation()
    #expect(!drawing.isEmpty)

    store.updateCurrentDrawing(drawing)
    store.addPage(title: "第二页")
    try await waitUntil { !store.isDrawingLoading }
    await store.flush()

    #expect(try await repository.loadDrawing(pageID: firstPageID) == drawing)
    let persistedDrawingURL =
      rootURL
      .appendingPathComponent(DrawingRepository.drawingsDirectoryName, isDirectory: true)
      .appendingPathComponent(
        "\(firstPageID.uuidString).\(DrawingRepository.drawingFileExtension)"
      )
    let persistedDrawing = try Data(contentsOf: persistedDrawingURL)
    #expect(persistedDrawing == drawing)
    #expect(!SegmentedDrawingCodec.isSegmentedAuthority(persistedDrawing))
    #expect(
      !FileManager.default.fileExists(
        atPath: rootURL.appendingPathComponent(
          DrawingRepository.segmentedDrawingsDirectoryName,
          isDirectory: true
        ).path
      )
    )
    let savedLibrary = try #require(try await repository.loadLibrary())
    #expect(savedLibrary.notebooks[0].pages.count == 2)
  }

  @Test("Switching pages replaces the visible source list with the selected page")
  @MainActor
  func pageTransitionLoadsMatchingSources() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let firstPage = NotePage(title: "第一页")
    let secondPage = NotePage(title: "第二页")
    let library = LibraryDocument(notebooks: [
      Notebook(title: "资料", pages: [firstPage, secondPage])
    ])
    let firstSource = PageSourceExcerpt(
      title: "第一条来源",
      excerpt: "第一条用户选择的内容",
      sourceURL: URL(string: "https://example.com/first")!,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_001)
    )
    let secondSource = PageSourceExcerpt(
      title: "第二条来源",
      excerpt: "第二条用户选择的内容",
      sourceURL: URL(string: "https://example.com/second")!,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_002)
    )
    let repository = DrawingRepository(rootURL: rootURL)
    try await repository.saveLibrary(library)
    try await repository.savePageSources([firstSource], pageID: firstPage.id)
    try await repository.savePageSources([secondSource], pageID: secondPage.id)

    let store = LibraryStore(repository: repository)
    try await waitUntil { !store.isLoading }
    #expect(store.selectedPageID == firstPage.id)
    #expect(store.currentPageSources == [firstSource])

    store.selectPage(secondPage.id)
    try await waitUntil { !store.isDrawingLoading }
    #expect(store.selectedPageID == secondPage.id)
    #expect(store.currentPageSources == [secondSource])
  }

  @Test("Invalid PencilKit bytes enter read-only mode and remain untouched")
  @MainActor
  func invalidDrawingIsProtected() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let repository = DrawingRepository(rootURL: rootURL)
    let library = LibraryDocument.starter()
    let pageID = try #require(library.notebooks.first?.pages.first?.id)
    let invalidDrawing = Data("not-a-pencilkit-drawing".utf8)
    try await repository.saveLibrary(library)
    try await repository.saveDrawing(invalidDrawing, pageID: pageID)

    let store = LibraryStore(repository: repository)
    try await waitUntil { !store.isLoading }

    #expect(store.isReadOnly)
    await store.flush()
    #expect(try await repository.loadDrawing(pageID: pageID) == invalidDrawing)
  }

  @Test("A decodable duplicate page identifier enters read-only mode without rewriting bytes")
  @MainActor
  func duplicatePageIDIsProtected() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: rootURL) }
    let duplicatePageID = UUID()
    let library = LibraryDocument(notebooks: [
      Notebook(
        title: "重复页面目录",
        pages: [
          NotePage(id: duplicatePageID, title: "第一页"),
          NotePage(id: duplicatePageID, title: "第二页"),
        ]
      )
    ])
    let drawing = try serializedStrokeDrawing()
    let repository = DrawingRepository(rootURL: rootURL)
    try await repository.saveDrawing(drawing, pageID: duplicatePageID)
    let persistedLibrary = try writePersistedLibrary(library, rootURL: rootURL)
    let drawingURL =
      rootURL
      .appendingPathComponent(DrawingRepository.drawingsDirectoryName, isDirectory: true)
      .appendingPathComponent(
        "\(duplicatePageID.uuidString).\(DrawingRepository.drawingFileExtension)"
      )
    let persistedDrawing = try Data(contentsOf: drawingURL)

    let store = LibraryStore(repository: repository)
    try await waitUntil { !store.isLoading }
    await store.flush()

    #expect(store.isReadOnly)
    #expect(store.persistenceError?.contains("重复的页面") == true)
    #expect(try Data(contentsOf: persistedLibrary.url) == persistedLibrary.data)
    #expect(try Data(contentsOf: drawingURL) == persistedDrawing)
  }

  @Test("An immediate backup contains the latest unsaved canvas state")
  @MainActor
  func immediateBackupContainsLatestDrawing() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let repository = DrawingRepository(rootURL: rootURL)
    let store = LibraryStore(repository: repository)
    try await waitUntil { !store.isLoading }

    let pageID = try #require(store.selectedPageID)
    let drawing = PKDrawing().dataRepresentation()
    store.updateCurrentDrawing(drawing)

    let export = try await store.makeBackup()
    let decoded = try BackupArchiveCodec.decode(export.data)

    #expect(decoded.drawings[pageID] == drawing)
    #expect(try await repository.loadDrawing(pageID: pageID) == drawing)
    #expect(!store.isBackupTransferInProgress)
  }

  @Test("Importing a sourced page makes its remapped sources current")
  @MainActor
  func importedPageSourcesBecomeCurrent() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let repository = DrawingRepository(rootURL: rootURL)
    let store = LibraryStore(repository: repository)
    try await waitUntil { !store.isLoading }

    let sourceLibrary = LibraryDocument.starter()
    let sourcePageID = try #require(sourceLibrary.notebooks.first?.pages.first?.id)
    let source = PageSourceExcerpt(
      title: "网页资料",
      excerpt: "用户主动保存的内容",
      sourceURL: URL(string: "https://example.com/imported")!,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_003)
    )
    let archive = try BackupArchiveCodec.encodeBestAvailable(
      library: sourceLibrary,
      drawings: [sourcePageID: PKDrawing().dataRepresentation()],
      pageSources: [sourcePageID: [source]],
      createdAt: Date(timeIntervalSince1970: 1_700_010_000)
    )

    let result = try await store.importBackupAsCopy(archive)

    #expect(result.disposition == .imported)
    #expect(store.selectedPageID == result.selectedPageID)
    #expect(store.currentPageSources == [source])
    #expect(
      try await repository.loadPageSources(pageID: result.selectedPageID)
        == [source]
    )
  }

  @Test("A user-confirmed source is saved to the current page and its next backup")
  @MainActor
  func confirmedSourceIsDurableAndBackedUp() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let repository = DrawingRepository(rootURL: rootURL)
    let store = LibraryStore(repository: repository)
    try await waitUntil { !store.isLoading }
    let pageID = try #require(store.selectedPageID)
    let source = PageSourceExcerpt(
      id: UUID(uuidString: "72000000-0000-0000-0000-000000000001")!,
      title: "用户确认的网页",
      excerpt: "只保存用户明确选择的这一段。",
      sourceURL: URL(string: "https://example.com/confirmed")!,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_004)
    )

    try await store.savePageSource(source, to: pageID)
    #expect(store.currentPageSources == [source])
    #expect(!store.isPageSourceSaveInProgress)
    #expect(try await repository.loadPageSources(pageID: pageID) == [source])

    let backup = try await store.makeBackup()
    let decoded = try BackupArchiveCodec.decode(backup.data)
    #expect(decoded.pageSources[pageID] == [source])
  }

  @Test("An unsafe source is rejected without changing the current page")
  @MainActor
  func unsafeSourceDoesNotChangeCurrentPage() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let repository = DrawingRepository(rootURL: rootURL)
    let store = LibraryStore(repository: repository)
    try await waitUntil { !store.isLoading }
    let pageID = try #require(store.selectedPageID)
    let source = PageSourceExcerpt(
      title: "不安全的来源",
      excerpt: "不能写入当前页。",
      sourceURL: URL(string: "http://example.com/not-secure")!
    )

    await #expect(throws: PageSourceError.invalidURL) {
      try await store.savePageSource(source, to: pageID)
    }
    #expect(store.currentPageSources.isEmpty)
    #expect(!store.isPageSourceSaveInProgress)
    #expect(try await repository.loadPageSources(pageID: pageID).isEmpty)
  }

  @Test("A user-confirmed source deletion is durable and leaves other sources untouched")
  @MainActor
  func confirmedSourceDeletionIsDurable() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let repository = DrawingRepository(rootURL: rootURL)
    let store = LibraryStore(repository: repository)
    try await waitUntil { !store.isLoading }
    let pageID = try #require(store.selectedPageID)
    let first = PageSourceExcerpt(
      id: UUID(uuidString: "73000000-0000-0000-0000-000000000001")!,
      title: "第一条来源",
      excerpt: "用户决定删除这一条。",
      sourceURL: URL(string: "https://example.com/first")!,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_005)
    )
    let second = PageSourceExcerpt(
      id: UUID(uuidString: "73000000-0000-0000-0000-000000000002")!,
      title: "第二条来源",
      excerpt: "这一条应该继续保留。",
      sourceURL: URL(string: "https://example.com/second")!,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_006)
    )

    try await store.savePageSource(first, to: pageID)
    try await store.savePageSource(second, to: pageID)
    try await store.deletePageSource(first.id, from: pageID)
    #expect(store.currentPageSources == [second])
    #expect(try await repository.loadPageSources(pageID: pageID) == [second])

    let sourcedBackup = try await store.makeBackup()
    #expect(try BackupArchiveCodec.decode(sourcedBackup.data).pageSources[pageID] == [second])

    try await store.deletePageSource(second.id, from: pageID)
    #expect(store.currentPageSources.isEmpty)
    #expect(!store.isPageSourceSaveInProgress)
    #expect(try await repository.loadPageSources(pageID: pageID).isEmpty)
    let cleanBackup = try await store.makeBackup()
    #expect(try BackupArchiveCodec.decode(cleanBackup.data).pageSources[pageID] == nil)
  }

  @Test("A repeated import keeps the current selection and adds nothing")
  @MainActor
  func repeatedImportKeepsCurrentSelection() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let repository = DrawingRepository(rootURL: rootURL)
    let store = LibraryStore(repository: repository)
    try await waitUntil { !store.isLoading }
    let originalNotebookID = try #require(store.selectedNotebookID)
    let originalPageID = try #require(store.selectedPageID)

    let sourceLibrary = LibraryDocument.starter()
    let sourcePageID = try #require(sourceLibrary.notebooks.first?.pages.first?.id)
    let archive = try BackupArchiveCodec.encode(
      library: sourceLibrary,
      drawings: [sourcePageID: PKDrawing().dataRepresentation()],
      createdAt: Date(timeIntervalSince1970: 1_700_010_000),
      backupID: UUID(uuidString: "E6000000-0000-0000-0000-000000000001")!
    )

    let first = try await store.importBackupAsCopy(archive)
    #expect(first.disposition == .imported)
    store.selectNotebook(originalNotebookID)
    try await waitUntil { !store.isDrawingLoading && store.selectedPageID == originalPageID }
    let notebookCountBeforeRetry = store.notebooks.count
    let drawingBeforeRetry = store.currentDrawingData

    let retry = try await store.importBackupAsCopy(archive)

    #expect(retry.disposition == .alreadyImported)
    #expect(store.notebooks.count == notebookCountBeforeRetry)
    #expect(store.selectedNotebookID == originalNotebookID)
    #expect(store.selectedPageID == originalPageID)
    #expect(store.currentDrawingData == drawingBeforeRetry)
  }

  @Test("A repeated import repairs the selected drawing when its file is missing")
  @MainActor
  func repeatedImportRepairsSelectedMissingDrawing() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let repository = DrawingRepository(rootURL: rootURL)
    let sourceLibrary = LibraryDocument.starter()
    let sourcePageID = try #require(sourceLibrary.notebooks.first?.pages.first?.id)
    let sourceDrawing = try serializedStrokeDrawing()
    let archive = try BackupArchiveCodec.encode(
      library: sourceLibrary,
      drawings: [sourcePageID: sourceDrawing],
      createdAt: Date(timeIntervalSince1970: 1_700_011_000),
      backupID: UUID(uuidString: "E6000000-0000-0000-0000-000000000002")!
    )

    let importedNotebookID: UUID
    let importedPageID: UUID
    do {
      let firstStore = LibraryStore(repository: repository)
      try await waitUntil { !firstStore.isLoading }
      let first = try await firstStore.importBackupAsCopy(archive)
      importedNotebookID = first.selectedNotebookID
      importedPageID = first.selectedPageID
      #expect(firstStore.currentDrawingData == sourceDrawing)
    }

    try await repository.removeDrawingIfPresent(pageID: importedPageID)
    let reloadedStore = LibraryStore(repository: repository)
    try await waitUntil { !reloadedStore.isLoading }
    reloadedStore.selectNotebook(importedNotebookID)
    try await waitUntil {
      !reloadedStore.isDrawingLoading && reloadedStore.selectedPageID == importedPageID
    }
    #expect(reloadedStore.currentDrawingData.isEmpty)

    let retry = try await reloadedStore.importBackupAsCopy(archive)

    #expect(retry.disposition == .alreadyImported)
    #expect(retry.repairedDrawingCount == 1)
    #expect(retry.repairedPageIDs == [importedPageID])
    #expect(reloadedStore.selectedPageID == importedPageID)
    #expect(reloadedStore.currentDrawingData == sourceDrawing)
    #expect(try await repository.loadDrawing(pageID: importedPageID) == sourceDrawing)
  }

  @Test("A repeated import preserves an unsaved user clear on the selected page")
  @MainActor
  func repeatedImportPreservesUnsavedClear() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let repository = DrawingRepository(rootURL: rootURL)
    let store = LibraryStore(repository: repository)
    try await waitUntil { !store.isLoading }

    let sourceLibrary = LibraryDocument.starter()
    let sourcePageID = try #require(sourceLibrary.notebooks.first?.pages.first?.id)
    let sourceDrawing = try serializedStrokeDrawing()
    let archive = try BackupArchiveCodec.encode(
      library: sourceLibrary,
      drawings: [sourcePageID: sourceDrawing],
      createdAt: Date(timeIntervalSince1970: 1_700_012_000),
      backupID: UUID(uuidString: "E6000000-0000-0000-0000-000000000003")!
    )

    let first = try await store.importBackupAsCopy(archive)
    #expect(store.currentDrawingData == sourceDrawing)
    store.clearCurrentDrawing()
    #expect(store.currentDrawingData.isEmpty)

    let retry = try await store.importBackupAsCopy(archive)

    #expect(retry.disposition == .alreadyImported)
    #expect(retry.repairedDrawingCount == 0)
    #expect(retry.repairedPageIDs.isEmpty)
    #expect(store.selectedPageID == first.selectedPageID)
    #expect(store.currentDrawingData.isEmpty)
    #expect(try await repository.loadDrawing(pageID: first.selectedPageID) == Data())
  }

  @Test("Titles that cannot be backed up are rejected at the editing boundary")
  @MainActor
  func oversizedTitleIsRejected() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let repository = DrawingRepository(rootURL: rootURL)
    let store = LibraryStore(repository: repository)
    try await waitUntil { !store.isLoading }

    let notebookID = try #require(store.selectedNotebookID)
    let originalTitle = try #require(store.selectedNotebook?.title)
    let oversizedTitle = String(
      repeating: "字",
      count: BackupArchiveLimits.maximumTitleUTF8ByteCount
    )
    store.renameNotebook(id: notebookID, title: oversizedTitle)

    #expect(store.selectedNotebook?.title == originalTitle)
    #expect(store.persistenceError?.contains("名称太长") == true)
  }

  @Test("Undoing a selected-page deletion durably restores its content and selection")
  @MainActor
  func selectedPageDeletionCanBeUndone() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let repository = DrawingRepository(rootURL: rootURL)
    let store = LibraryStore(repository: repository)
    try await waitUntil { !store.isLoading }
    let pageID = try #require(store.selectedPageID)
    let drawing = try serializedStrokeDrawing()
    let source = PageSourceExcerpt(
      title: "撤销来源",
      excerpt: "这段内容应随刚删除的页面一起恢复。",
      sourceURL: URL(string: "https://example.com/undo")!,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    store.updateCurrentDrawing(drawing)
    try await store.savePageSource(source, to: pageID)
    let libraryBeforeDeletion = store.library
    let notebookIDBeforeDeletion = store.selectedNotebookID

    #expect(store.deletePage(id: pageID))
    #expect(store.selectedPageID != pageID)
    #expect(await store.undoLastDeletion())

    #expect(store.library == libraryBeforeDeletion)
    #expect(store.selectedNotebookID == notebookIDBeforeDeletion)
    #expect(store.selectedPageID == pageID)
    #expect(store.currentDrawingData == drawing)
    #expect(store.currentPageSources == [source])
    await store.flush()
    let persistedLibrary = try #require(try await repository.loadLibrary())
    #expect(persistedLibrary.schemaVersion == libraryBeforeDeletion.schemaVersion)
    #expect(persistedLibrary.notebooks.map(\.id) == libraryBeforeDeletion.notebooks.map(\.id))
    #expect(persistedLibrary.notebooks.map(\.title) == libraryBeforeDeletion.notebooks.map(\.title))
    #expect(
      persistedLibrary.notebooks.flatMap(\.pages).map(\.id)
        == libraryBeforeDeletion.notebooks.flatMap(\.pages).map(\.id)
    )
    #expect(
      persistedLibrary.notebooks.flatMap(\.pages).map(\.background)
        == libraryBeforeDeletion.notebooks.flatMap(\.pages).map(\.background)
    )
    let persistedPage = try #require(persistedLibrary.notebooks.first?.pages.first)
    let originalPage = try #require(libraryBeforeDeletion.notebooks.first?.pages.first)
    #expect(abs(persistedPage.updatedAt.timeIntervalSince(originalPage.updatedAt)) < 0.001)
    #expect(try await repository.loadDrawing(pageID: pageID) == drawing)
    #expect(try await repository.loadPageSources(pageID: pageID) == [source])
  }

  @Test("Undoing a nonselected notebook deletion restores its original order")
  @MainActor
  func nonselectedNotebookDeletionCanBeUndone() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let firstPage = NotePage(title: "当前页")
    let secondPage = NotePage(title: "另一页")
    let firstNotebook = Notebook(title: "当前笔记本", pages: [firstPage])
    let secondNotebook = Notebook(title: "待删除笔记本", pages: [secondPage])
    let library = LibraryDocument(notebooks: [firstNotebook, secondNotebook])
    let repository = DrawingRepository(rootURL: rootURL)
    try await repository.saveLibrary(library)
    let store = LibraryStore(repository: repository)
    try await waitUntil { !store.isLoading }
    let libraryBeforeDeletion = store.library

    #expect(store.deleteNotebook(id: secondNotebook.id))
    #expect(store.notebooks.map(\.id) == [firstNotebook.id])
    #expect(await store.undoLastDeletion())

    #expect(store.library == libraryBeforeDeletion)
    #expect(store.notebooks.map(\.id) == [firstNotebook.id, secondNotebook.id])
    #expect(store.selectedNotebookID == firstNotebook.id)
    #expect(store.selectedPageID == firstPage.id)
    await store.flush()
    let persistedLibrary = try #require(try await repository.loadLibrary())
    #expect(persistedLibrary == libraryBeforeDeletion)
  }

  @Test("Undoing deletion fails closed after a later directory edit")
  @MainActor
  func staleDeletionUndoDoesNotOverwriteLaterEdit() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let firstPage = NotePage(title: "保留页")
    let secondPage = NotePage(title: "删除页")
    let notebook = Notebook(title: "测试笔记本", pages: [firstPage, secondPage])
    let repository = DrawingRepository(rootURL: rootURL)
    try await repository.saveLibrary(LibraryDocument(notebooks: [notebook]))
    let store = LibraryStore(repository: repository)
    try await waitUntil { !store.isLoading }

    #expect(store.deletePage(id: secondPage.id))
    store.renamePage(id: firstPage.id, title: "删除后的新名称")
    #expect(!(await store.undoLastDeletion()))

    #expect(store.selectedPage?.title == "删除后的新名称")
    #expect(store.selectedNotebook?.pages.contains(where: { $0.id == secondPage.id }) == false)
    await store.flush()
    let persisted = try #require(try await repository.loadLibrary())
    #expect(persisted.notebooks[0].pages.map(\.title) == ["删除后的新名称"])
  }

  @Test("A page that would exceed the v1 manifest budget leaves store state unchanged")
  @MainActor
  func manifestOverflowPageIsRejectedAtomically() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let repository = DrawingRepository(rootURL: rootURL)
    let library = try makeManifestBudgetTestFixture().exact
    try await repository.saveLibrary(library)
    let libraryURL = rootURL.appendingPathComponent(DrawingRepository.libraryFilename)
    let persistedBefore = try Data(contentsOf: libraryURL)

    let store = LibraryStore(repository: repository)
    try await waitUntil { !store.isLoading }
    let libraryBefore = store.library
    let selectedNotebookID = store.selectedNotebookID
    let selectedPageID = store.selectedPageID
    let drawingBefore = store.currentDrawingData

    store.addPage(title: "x")

    #expect(store.library == libraryBefore)
    #expect(store.selectedNotebookID == selectedNotebookID)
    #expect(store.selectedPageID == selectedPageID)
    #expect(store.currentDrawingData == drawingBefore)
    #expect(store.persistenceError?.contains("包含的笔记较多") == true)
    await store.flush()
    #expect(try Data(contentsOf: libraryURL) == persistedBefore)
  }

  @Test("Replacing an exact-limit notebook's last page cannot grow the manifest")
  @MainActor
  func exactLimitStarterReplacementIsRejectedAtomically() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let fixture = try makeManifestBudgetTestFixture(includingSingletonNotebook: true)
    let singletonPageID = try #require(fixture.singletonPageID)
    #expect(
      try BackupArchiveCodec.projectedManifestByteCount(for: fixture.exact)
        == BackupArchiveLimits.maximumManifestByteCount
    )
    let repository = DrawingRepository(rootURL: rootURL)
    try await repository.saveLibrary(fixture.exact)
    let libraryURL = rootURL.appendingPathComponent(DrawingRepository.libraryFilename)
    let persistedBefore = try Data(contentsOf: libraryURL)
    let store = LibraryStore(repository: repository)
    try await waitUntil { !store.isLoading }
    let libraryBefore = store.library
    let selectedPageID = store.selectedPageID

    store.deletePage(id: singletonPageID)

    #expect(store.library == libraryBefore)
    #expect(store.selectedPageID == selectedPageID)
    #expect(store.persistenceError?.contains("包含的笔记较多") == true)
    await store.flush()
    #expect(try Data(contentsOf: libraryURL) == persistedBefore)
  }

  @Test("A legacy oversized manifest permits only non-growing repairs")
  @MainActor
  func legacyManifestRepairsAreMonotonic() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let fixture = try makeManifestBudgetTestFixture()
    var legacyLibrary = fixture.exact
    let bulkNotebookIndex = try #require(
      legacyLibrary.notebooks.firstIndex(where: { $0.id == fixture.bulkNotebookID })
    )
    let repairPageIndex = try #require(
      legacyLibrary.notebooks[bulkNotebookIndex].pages.firstIndex(
        where: { $0.title.utf8.count == BackupArchiveLimits.maximumTitleUTF8ByteCount }
      )
    )
    let repairPage = legacyLibrary.notebooks[bulkNotebookIndex].pages[repairPageIndex]
    let repairTitle = repairPage.title
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    legacyLibrary.notebooks[bulkNotebookIndex].pages.append(
      NotePage(
        id: UUID(uuidString: "74000000-0000-0000-0000-000000000001")!,
        title: String(
          repeating: "a",
          count: BackupArchiveLimits.maximumTitleUTF8ByteCount
        ),
        createdAt: timestamp,
        updatedAt: timestamp
      )
    )
    let initialByteCount = try BackupArchiveCodec.projectedManifestByteCount(for: legacyLibrary)
    #expect(initialByteCount > BackupArchiveLimits.maximumManifestByteCount)

    var repairedCandidate = legacyLibrary
    repairedCandidate.notebooks[bulkNotebookIndex].pages[repairPageIndex].title = "x"
    let expectedRepairedByteCount = try BackupArchiveCodec.projectedManifestByteCount(
      for: repairedCandidate
    )
    #expect(expectedRepairedByteCount < initialByteCount)
    #expect(expectedRepairedByteCount > BackupArchiveLimits.maximumManifestByteCount)

    let repository = DrawingRepository(rootURL: rootURL)
    try await repository.saveLibrary(legacyLibrary)
    let store = LibraryStore(repository: repository)
    try await waitUntil { !store.isLoading }

    store.renamePage(id: repairPage.id, title: "x")
    let repairedByteCount = try BackupArchiveCodec.projectedManifestByteCount(for: store.library)

    #expect(store.library.notebooks[bulkNotebookIndex].pages[repairPageIndex].title == "x")
    #expect(repairedByteCount < initialByteCount)
    #expect(repairedByteCount > BackupArchiveLimits.maximumManifestByteCount)

    store.renamePage(id: repairPage.id, title: repairTitle)

    #expect(store.library.notebooks[bulkNotebookIndex].pages[repairPageIndex].title == "x")
    #expect(store.persistenceError?.contains("包含的笔记较多") == true)
    await store.flush()
    let persisted = try #require(try await repository.loadLibrary())
    #expect(persisted.notebooks.map(\.id) == store.library.notebooks.map(\.id))
    #expect(persisted.notebooks.map(\.title) == store.library.notebooks.map(\.title))
    #expect(
      persisted.notebooks.flatMap(\.pages).map(\.id)
        == store.library.notebooks.flatMap(\.pages).map(\.id)
    )
    #expect(
      persisted.notebooks.flatMap(\.pages).map(\.title)
        == store.library.notebooks.flatMap(\.pages).map(\.title)
    )
  }

  @MainActor
  private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool
  ) async throws {
    for _ in 0..<100 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw StoreTestError.timedOut
  }

  private func serializedStrokeDrawing() throws -> Data {
    let url = try #require(
      Bundle.module.url(
        forResource: "single-stroke-v1",
        withExtension: "pkdrawing",
        subdirectory: "Fixtures/BackupV1"
      )
    )
    return try Data(contentsOf: url)
  }

  private func writePersistedLibrary(
    _ library: LibraryDocument,
    rootURL: URL
  ) throws -> (url: URL, data: Data) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(library)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let url = rootURL.appendingPathComponent(DrawingRepository.libraryFilename)
    try data.write(to: url)
    return (url, data)
  }
}

private enum StoreTestError: Error {
  case timedOut
}
