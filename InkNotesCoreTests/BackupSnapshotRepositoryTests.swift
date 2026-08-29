import Foundation
import PencilKit
import Testing

@testable import InkNotesCore

@Suite("InkNotes backup snapshots")
struct BackupSnapshotRepositoryTests {
  @Test("Export includes the latest in-memory drawing and persists it strictly")
  func exportUsesDrawingOverride() async throws {
    let fixture = makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let library = LibraryDocument.starter()
    let pageID = try #require(library.notebooks.first?.pages.first?.id)
    let latestDrawing = PKDrawing().dataRepresentation()
    #expect(!latestDrawing.isEmpty)

    let archive = try await fixture.repository.makeBackup(
      library: library,
      drawingOverrides: [pageID: latestDrawing],
      sourceAppVersion: "0.2.0",
      sourceBuild: "2",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let decoded = try BackupArchiveCodec.decode(archive)
    let persistedLibrary = try #require(try await fixture.repository.loadLibrary())

    #expect(decoded.drawings[pageID] == latestDrawing)
    #expect(try await fixture.repository.loadDrawing(pageID: pageID) == latestDrawing)
    expectSameLibraryContent(persistedLibrary, library)
  }

  @Test("Restore appends remapped copies and preserves the current notebook")
  func restoreAsCopy() async throws {
    let fixture = makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let currentLibrary = LibraryDocument.starter()
    let currentNotebook = try #require(currentLibrary.notebooks.first)
    let currentPage = try #require(currentNotebook.pages.first)
    let currentDrawing = PKDrawing().dataRepresentation()
    try await fixture.repository.saveLibrary(currentLibrary)
    try await fixture.repository.saveDrawing(currentDrawing, pageID: currentPage.id)

    let sourceLibrary = LibraryDocument.starter()
    let sourcePageID = try #require(sourceLibrary.notebooks.first?.pages.first?.id)
    let sourceDrawing = PKDrawing().dataRepresentation()
    let archive = try BackupArchiveCodec.encode(
      library: sourceLibrary,
      drawings: [sourcePageID: sourceDrawing],
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let result = try await fixture.repository.restoreBackupAsCopy(
      archive,
      currentLibrary: currentLibrary,
      currentDrawingOverrides: [currentPage.id: currentDrawing],
      importedAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    let persistedLibrary = try #require(try await fixture.repository.loadLibrary())
    let persistedCurrentDrawing = try await fixture.repository.loadDrawing(pageID: currentPage.id)
    let persistedImportedDrawing = try await fixture.repository.loadDrawing(
      pageID: result.selectedPageID
    )

    #expect(result.library.notebooks.count == 2)
    #expect(result.library.notebooks[0] == currentNotebook)
    #expect(result.library.notebooks[1].title == "我的笔记本（导入）")
    #expect(result.selectedNotebookID != currentNotebook.id)
    #expect(result.selectedPageID != currentPage.id)
    #expect(result.importedNotebookCount == 1)
    #expect(result.importedPageCount == 1)
    #expect(persistedCurrentDrawing == currentDrawing)
    #expect(persistedImportedDrawing == sourceDrawing)
    expectSameLibraryContent(persistedLibrary, result.library)
  }

  @Test("Invalid PencilKit data is rejected before import writes")
  func invalidDrawingDoesNotWrite() async throws {
    let fixture = makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let currentLibrary = LibraryDocument.starter()
    let currentPageID = try #require(currentLibrary.notebooks.first?.pages.first?.id)
    let currentDrawing = PKDrawing().dataRepresentation()
    try await fixture.repository.saveLibrary(currentLibrary)
    try await fixture.repository.saveDrawing(currentDrawing, pageID: currentPageID)

    let sourceLibrary = LibraryDocument.starter()
    let sourcePageID = try #require(sourceLibrary.notebooks.first?.pages.first?.id)
    let archive = try BackupArchiveCodec.encode(
      library: sourceLibrary,
      drawings: [sourcePageID: Data("not-pencilkit".utf8)],
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let drawingsURL = fixture.rootURL.appendingPathComponent("Drawings", isDirectory: true)
    let before = try Set(FileManager.default.contentsOfDirectory(atPath: drawingsURL.path))

    await #expect(throws: BackupSnapshotError.invalidDrawing) {
      try await fixture.repository.restoreBackupAsCopy(
        archive,
        currentLibrary: currentLibrary,
        currentDrawingOverrides: [currentPageID: currentDrawing]
      )
    }

    let after = try Set(FileManager.default.contentsOfDirectory(atPath: drawingsURL.path))
    let persistedLibrary = try #require(try await fixture.repository.loadLibrary())
    #expect(after == before)
    expectSameLibraryContent(persistedLibrary, currentLibrary)
    #expect(try await fixture.repository.loadDrawing(pageID: currentPageID) == currentDrawing)
  }

  private func makeRepository() -> (rootURL: URL, repository: DrawingRepository) {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return (rootURL, DrawingRepository(rootURL: rootURL))
  }

  private func expectSameLibraryContent(
    _ actual: LibraryDocument,
    _ expected: LibraryDocument
  ) {
    #expect(actual.schemaVersion == expected.schemaVersion)
    #expect(actual.notebooks.map(\.id) == expected.notebooks.map(\.id))
    #expect(actual.notebooks.map(\.title) == expected.notebooks.map(\.title))
    #expect(
      actual.notebooks.flatMap(\.pages).map(\.id)
        == expected.notebooks.flatMap(\.pages).map(\.id)
    )
    #expect(
      actual.notebooks.flatMap(\.pages).map(\.title)
        == expected.notebooks.flatMap(\.pages).map(\.title)
    )
    for (actualNotebook, expectedNotebook) in zip(actual.notebooks, expected.notebooks) {
      #expect(
        abs(actualNotebook.createdAt.timeIntervalSince(expectedNotebook.createdAt)) < 0.001
      )
      #expect(
        abs(actualNotebook.updatedAt.timeIntervalSince(expectedNotebook.updatedAt)) < 0.001
      )
      for (actualPage, expectedPage) in zip(actualNotebook.pages, expectedNotebook.pages) {
        #expect(actualPage.background == expectedPage.background)
        #expect(abs(actualPage.createdAt.timeIntervalSince(expectedPage.createdAt)) < 0.001)
        #expect(abs(actualPage.updatedAt.timeIntervalSince(expectedPage.updatedAt)) < 0.001)
      }
    }
  }
}
