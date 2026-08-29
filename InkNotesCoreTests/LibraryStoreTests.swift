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
    let savedLibrary = try #require(try await repository.loadLibrary())
    #expect(savedLibrary.notebooks[0].pages.count == 2)
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
    #expect(store.persistenceError?.contains("名称过长") == true)
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
}

private enum StoreTestError: Error {
  case timedOut
}
