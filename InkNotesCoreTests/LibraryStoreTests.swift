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
}

private enum StoreTestError: Error {
  case timedOut
}
