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

  @Test("Retrying a committed restore does not append another copy")
  func committedRestoreRetryIsIdempotent() async throws {
    let fixture = makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let currentLibrary = LibraryDocument.starter()
    let currentPageID = try #require(currentLibrary.notebooks.first?.pages.first?.id)
    let currentDrawing = PKDrawing().dataRepresentation()
    try await fixture.repository.saveLibrary(currentLibrary)
    try await fixture.repository.saveDrawing(currentDrawing, pageID: currentPageID)

    let sourceLibrary = LibraryDocument.starter()
    let sourcePageID = try #require(sourceLibrary.notebooks.first?.pages.first?.id)
    let sourceDrawing = PKDrawing().dataRepresentation()
    let backupID = UUID(uuidString: "E5000000-0000-0000-0000-000000000001")!
    let archive = try BackupArchiveCodec.encode(
      library: sourceLibrary,
      drawings: [sourcePageID: sourceDrawing],
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      backupID: backupID
    )

    let first = try await fixture.repository.restoreBackupAsCopy(
      archive,
      currentLibrary: currentLibrary,
      currentDrawingOverrides: [currentPageID: currentDrawing],
      importedAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    let reloadedAfterCommit = try #require(try await fixture.repository.loadLibrary())
    let drawingsURL = fixture.rootURL.appendingPathComponent("Drawings", isDirectory: true)
    let filesAfterCommit = try Set(
      FileManager.default.contentsOfDirectory(atPath: drawingsURL.path)
    )

    let retry = try await fixture.repository.restoreBackupAsCopy(
      archive,
      currentLibrary: reloadedAfterCommit,
      currentDrawingOverrides: [:],
      importedAt: Date(timeIntervalSince1970: 1_700_000_200)
    )
    let filesAfterRetry = try Set(FileManager.default.contentsOfDirectory(atPath: drawingsURL.path))
    let transaction = try #require(
      try await fixture.repository.loadRestoreTransaction(backupID: backupID)
    )

    #expect(first.disposition == .imported)
    #expect(retry.disposition == .alreadyImported)
    #expect(retry.repairedDrawingCount == 0)
    #expect(retry.repairedPageIDs.isEmpty)
    #expect(retry.library.notebooks.count == first.library.notebooks.count)
    #expect(retry.selectedNotebookID == first.selectedNotebookID)
    #expect(retry.selectedPageID == first.selectedPageID)
    #expect(filesAfterRetry == filesAfterCommit)
    #expect(transaction.backupID == backupID)
    #expect(transaction.copiedNotebooks.map(\.id) == [first.selectedNotebookID])
  }

  @Test("Retry repairs a missing drawing after the directory commit")
  func committedRestoreRetryRepairsMissingDrawing() async throws {
    let fixture = makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let currentLibrary = LibraryDocument.starter()
    let currentPageID = try #require(currentLibrary.notebooks.first?.pages.first?.id)
    let currentDrawing = PKDrawing().dataRepresentation()
    try await fixture.repository.saveLibrary(currentLibrary)
    try await fixture.repository.saveDrawing(currentDrawing, pageID: currentPageID)

    let sourceLibrary = LibraryDocument.starter()
    let sourcePageID = try #require(sourceLibrary.notebooks.first?.pages.first?.id)
    let sourceDrawing = try serializedStrokeDrawing()
    let backupID = UUID(uuidString: "E5000000-0000-0000-0000-000000000006")!
    let archive = try BackupArchiveCodec.encode(
      library: sourceLibrary,
      drawings: [sourcePageID: sourceDrawing],
      createdAt: Date(timeIntervalSince1970: 1_700_005_000),
      backupID: backupID
    )

    let first = try await fixture.repository.restoreBackupAsCopy(
      archive,
      currentLibrary: currentLibrary,
      currentDrawingOverrides: [currentPageID: currentDrawing]
    )
    let committedLibrary = try #require(try await fixture.repository.loadLibrary())
    let importedDrawingURL =
      fixture.rootURL
      .appendingPathComponent("Drawings", isDirectory: true)
      .appendingPathComponent("\(first.selectedPageID.uuidString).drawing")
    try FileManager.default.removeItem(at: importedDrawingURL)
    #expect(try await fixture.repository.loadDrawing(pageID: first.selectedPageID) == nil)

    let retry = try await fixture.repository.restoreBackupAsCopy(
      archive,
      currentLibrary: committedLibrary,
      currentDrawingOverrides: [:]
    )

    #expect(retry.disposition == .alreadyImported)
    #expect(retry.repairedDrawingCount == 1)
    #expect(retry.repairedPageIDs == [first.selectedPageID])
    #expect(retry.library.notebooks.count == committedLibrary.notebooks.count)
    #expect(retry.selectedDrawingData == sourceDrawing)
    #expect(try await fixture.repository.loadDrawing(pageID: first.selectedPageID) == sourceDrawing)
  }

  @Test("Retry never overwrites an existing drawing edited after import")
  func committedRestoreRetryPreservesEditedDrawing() async throws {
    let fixture = makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let currentLibrary = LibraryDocument.starter()
    let currentPageID = try #require(currentLibrary.notebooks.first?.pages.first?.id)
    let currentDrawing = PKDrawing().dataRepresentation()
    try await fixture.repository.saveLibrary(currentLibrary)
    try await fixture.repository.saveDrawing(currentDrawing, pageID: currentPageID)

    let sourceLibrary = LibraryDocument.starter()
    let sourcePageID = try #require(sourceLibrary.notebooks.first?.pages.first?.id)
    let sourceDrawing = try serializedStrokeDrawing()
    let backupID = UUID(uuidString: "E5000000-0000-0000-0000-000000000007")!
    let archive = try BackupArchiveCodec.encode(
      library: sourceLibrary,
      drawings: [sourcePageID: sourceDrawing],
      createdAt: Date(timeIntervalSince1970: 1_700_006_000),
      backupID: backupID
    )

    let first = try await fixture.repository.restoreBackupAsCopy(
      archive,
      currentLibrary: currentLibrary,
      currentDrawingOverrides: [currentPageID: currentDrawing]
    )
    let committedLibrary = try #require(try await fixture.repository.loadLibrary())
    let editedDrawing = PKDrawing().dataRepresentation()
    #expect(editedDrawing != sourceDrawing)
    try await fixture.repository.saveDrawing(editedDrawing, pageID: first.selectedPageID)

    let retry = try await fixture.repository.restoreBackupAsCopy(
      archive,
      currentLibrary: committedLibrary,
      currentDrawingOverrides: [:]
    )

    #expect(retry.disposition == .alreadyImported)
    #expect(retry.repairedDrawingCount == 0)
    #expect(retry.repairedPageIDs.isEmpty)
    #expect(retry.selectedDrawingData == editedDrawing)
    #expect(try await fixture.repository.loadDrawing(pageID: first.selectedPageID) == editedDrawing)
  }

  @Test("The same backup ID with different content is rejected without imported writes")
  func reusedBackupIDWithDifferentContentIsRejected() async throws {
    let fixture = makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let currentLibrary = LibraryDocument.starter()
    let currentPageID = try #require(currentLibrary.notebooks.first?.pages.first?.id)
    let currentDrawing = PKDrawing().dataRepresentation()
    try await fixture.repository.saveLibrary(currentLibrary)
    try await fixture.repository.saveDrawing(currentDrawing, pageID: currentPageID)

    var sourceLibrary = LibraryDocument.starter()
    let sourcePageID = try #require(sourceLibrary.notebooks.first?.pages.first?.id)
    let sourceDrawing = PKDrawing().dataRepresentation()
    let backupID = UUID(uuidString: "E5000000-0000-0000-0000-000000000002")!
    let originalArchive = try BackupArchiveCodec.encode(
      library: sourceLibrary,
      drawings: [sourcePageID: sourceDrawing],
      createdAt: Date(timeIntervalSince1970: 1_700_001_000),
      backupID: backupID
    )
    _ = try await fixture.repository.restoreBackupAsCopy(
      originalArchive,
      currentLibrary: currentLibrary,
      currentDrawingOverrides: [currentPageID: currentDrawing]
    )

    sourceLibrary.notebooks[0].title = "相同标识的不同内容"
    let conflictingArchive = try BackupArchiveCodec.encode(
      library: sourceLibrary,
      drawings: [sourcePageID: sourceDrawing],
      createdAt: Date(timeIntervalSince1970: 1_700_001_000),
      backupID: backupID
    )
    let reloaded = try #require(try await fixture.repository.loadLibrary())
    let libraryURL = fixture.rootURL.appendingPathComponent("library.json")
    let drawingsURL = fixture.rootURL.appendingPathComponent("Drawings", isDirectory: true)
    let libraryBefore = try Data(contentsOf: libraryURL)
    let filesBefore = try Set(FileManager.default.contentsOfDirectory(atPath: drawingsURL.path))

    await #expect(throws: BackupSnapshotError.backupIdentityConflict) {
      try await fixture.repository.restoreBackupAsCopy(
        conflictingArchive,
        currentLibrary: reloaded,
        currentDrawingOverrides: [:]
      )
    }

    #expect(try Data(contentsOf: libraryURL) == libraryBefore)
    #expect(
      try Set(FileManager.default.contentsOfDirectory(atPath: drawingsURL.path)) == filesBefore
    )
  }

  @Test("A partial previous import fails closed instead of adding another batch")
  func partialPreviousImportFailsClosed() async throws {
    let fixture = makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let currentLibrary = LibraryDocument.starter()
    let currentPageID = try #require(currentLibrary.notebooks.first?.pages.first?.id)
    let currentDrawing = PKDrawing().dataRepresentation()
    try await fixture.repository.saveLibrary(currentLibrary)
    try await fixture.repository.saveDrawing(currentDrawing, pageID: currentPageID)

    var sourceLibrary = LibraryDocument.starter()
    let secondSourcePage = NotePage(title: "第二页")
    sourceLibrary.notebooks[0].pages.append(secondSourcePage)
    let sourcePageIDs = sourceLibrary.notebooks[0].pages.map(\.id)
    let sourceDrawings = Dictionary(
      uniqueKeysWithValues: sourcePageIDs.map { ($0, PKDrawing().dataRepresentation()) }
    )
    let backupID = UUID(uuidString: "E5000000-0000-0000-0000-000000000003")!
    let archive = try BackupArchiveCodec.encode(
      library: sourceLibrary,
      drawings: sourceDrawings,
      createdAt: Date(timeIntervalSince1970: 1_700_002_000),
      backupID: backupID
    )
    let first = try await fixture.repository.restoreBackupAsCopy(
      archive,
      currentLibrary: currentLibrary,
      currentDrawingOverrides: [currentPageID: currentDrawing]
    )
    let transaction = try #require(
      try await fixture.repository.loadRestoreTransaction(backupID: backupID)
    )
    let copiedPages = try #require(transaction.copiedNotebooks.first?.pages)
    #expect(copiedPages.count == 2)

    var partialLibrary = first.library
    let importedNotebookIndex = try #require(
      partialLibrary.notebooks.firstIndex(where: { $0.id == first.selectedNotebookID })
    )
    partialLibrary.notebooks[importedNotebookIndex].pages.removeLast()
    try await fixture.repository.saveLibrary(partialLibrary)
    let drawingsURL = fixture.rootURL.appendingPathComponent("Drawings", isDirectory: true)
    let filesBefore = try Set(FileManager.default.contentsOfDirectory(atPath: drawingsURL.path))

    await #expect(throws: BackupSnapshotError.partialPreviousImport) {
      try await fixture.repository.restoreBackupAsCopy(
        archive,
        currentLibrary: partialLibrary,
        currentDrawingOverrides: [:]
      )
    }

    let persisted = try #require(try await fixture.repository.loadLibrary())
    expectSameLibraryContent(persisted, partialLibrary)
    #expect(
      try Set(FileManager.default.contentsOfDirectory(atPath: drawingsURL.path)) == filesBefore
    )
  }

  @Test("Deleting a whole imported batch allows explicit WAL-backed restoration")
  func fullyDeletedImportCanBeRestoredFromTransaction() async throws {
    let fixture = makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let currentLibrary = LibraryDocument.starter()
    let currentPageID = try #require(currentLibrary.notebooks.first?.pages.first?.id)
    let currentDrawing = PKDrawing().dataRepresentation()
    try await fixture.repository.saveLibrary(currentLibrary)
    try await fixture.repository.saveDrawing(currentDrawing, pageID: currentPageID)

    let backupID = UUID(uuidString: "E5000000-0000-0000-0000-000000000004")!
    var sourceLibrary = LibraryDocument.starter()
    sourceLibrary.notebooks[0].pages.append(NotePage(title: "第二页"))
    let sourcePageIDs = sourceLibrary.notebooks[0].pages.map(\.id)
    let sourceDrawings = Dictionary(
      uniqueKeysWithValues: sourcePageIDs.map { ($0, PKDrawing().dataRepresentation()) }
    )
    let archive = try BackupArchiveCodec.encode(
      library: sourceLibrary,
      drawings: sourceDrawings,
      createdAt: Date(timeIntervalSince1970: 1_700_003_000),
      backupID: backupID
    )
    let first = try await fixture.repository.restoreBackupAsCopy(
      archive,
      currentLibrary: currentLibrary,
      currentDrawingOverrides: [currentPageID: currentDrawing]
    )
    let transaction = try #require(
      try await fixture.repository.loadRestoreTransaction(backupID: backupID)
    )
    let restoredPageIDs = try #require(transaction.copiedNotebooks.first?.pages.map(\.id))
    #expect(restoredPageIDs.count == 2)
    let reusedDrawingURL =
      fixture.rootURL
      .appendingPathComponent("Drawings", isDirectory: true)
      .appendingPathComponent("\(restoredPageIDs[0].uuidString).drawing")
    let missingDrawingURL =
      fixture.rootURL
      .appendingPathComponent("Drawings", isDirectory: true)
      .appendingPathComponent("\(restoredPageIDs[1].uuidString).drawing")
    let modificationDateBefore = try reusedDrawingURL.resourceValues(
      forKeys: [.contentModificationDateKey]
    ).contentModificationDate

    try await fixture.repository.saveLibrary(currentLibrary)
    try FileManager.default.removeItem(at: missingDrawingURL)
    let resumed = try await fixture.repository.restoreBackupAsCopy(
      archive,
      currentLibrary: currentLibrary,
      currentDrawingOverrides: [:],
      importedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let modificationDateAfter = try reusedDrawingURL.resourceValues(
      forKeys: [.contentModificationDateKey]
    ).contentModificationDate

    #expect(first.disposition == .imported)
    #expect(resumed.disposition == .imported)
    #expect(resumed.selectedNotebookID == first.selectedNotebookID)
    #expect(resumed.selectedPageID == first.selectedPageID)
    #expect(modificationDateAfter == modificationDateBefore)
    #expect(FileManager.default.fileExists(atPath: missingDrawingURL.path))
    #expect(resumed.library.notebooks.count == first.library.notebooks.count)
  }

  @Test("A conflicting orphan drawing is never overwritten while resuming")
  func conflictingOrphanDrawingFailsClosed() async throws {
    let fixture = makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let currentLibrary = LibraryDocument.starter()
    let currentPageID = try #require(currentLibrary.notebooks.first?.pages.first?.id)
    let currentDrawing = PKDrawing().dataRepresentation()
    try await fixture.repository.saveLibrary(currentLibrary)
    try await fixture.repository.saveDrawing(currentDrawing, pageID: currentPageID)

    let sourceLibrary = LibraryDocument.starter()
    let sourcePageID = try #require(sourceLibrary.notebooks.first?.pages.first?.id)
    let sourceDrawing = try serializedStrokeDrawing()
    let backupID = UUID(uuidString: "E5000000-0000-0000-0000-000000000005")!
    let archive = try BackupArchiveCodec.encode(
      library: sourceLibrary,
      drawings: [sourcePageID: sourceDrawing],
      createdAt: Date(timeIntervalSince1970: 1_700_004_000),
      backupID: backupID
    )
    _ = try await fixture.repository.restoreBackupAsCopy(
      archive,
      currentLibrary: currentLibrary,
      currentDrawingOverrides: [currentPageID: currentDrawing]
    )
    let transaction = try #require(
      try await fixture.repository.loadRestoreTransaction(backupID: backupID)
    )
    let restoredPageID = try #require(transaction.copiedNotebooks.first?.pages.first?.id)
    let conflictingDrawing = PKDrawing().dataRepresentation()
    #expect(conflictingDrawing != sourceDrawing)

    try await fixture.repository.saveLibrary(currentLibrary)
    try await fixture.repository.saveDrawing(conflictingDrawing, pageID: restoredPageID)
    let libraryURL = fixture.rootURL.appendingPathComponent("library.json")
    let libraryBefore = try Data(contentsOf: libraryURL)

    await #expect(throws: BackupSnapshotError.orphanDrawingConflict) {
      try await fixture.repository.restoreBackupAsCopy(
        archive,
        currentLibrary: currentLibrary,
        currentDrawingOverrides: [:]
      )
    }

    #expect(try Data(contentsOf: libraryURL) == libraryBefore)
    #expect(try await fixture.repository.loadDrawing(pageID: restoredPageID) == conflictingDrawing)
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

  @Test("An oversized local drawing is rejected before backup reads it into memory")
  func oversizedLocalDrawingIsBounded() async throws {
    let fixture = makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let library = LibraryDocument.starter()
    let pageID = try #require(library.notebooks.first?.pages.first?.id)
    let maximum = BackupArchiveLimits.maximumDrawingByteCount
    let oversizedDrawing = Data(repeating: 0x00, count: maximum + 1)
    try await fixture.repository.saveLibrary(library)
    try await fixture.repository.saveDrawing(oversizedDrawing, pageID: pageID)

    await #expect(
      throws: BackupArchiveError.drawingTooLarge(
        pageID: pageID,
        actual: UInt64(maximum + 1),
        maximum: maximum
      )
    ) {
      try await fixture.repository.makeBackup(
        library: library,
        drawingOverrides: [:],
        sourceAppVersion: "0.2.0",
        sourceBuild: "2"
      )
    }
  }

  @Test("An invalid in-memory drawing cannot overwrite the persisted drawing")
  func invalidOverrideDoesNotOverwritePersistedDrawing() async throws {
    let fixture = makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let library = LibraryDocument.starter()
    let pageID = try #require(library.notebooks.first?.pages.first?.id)
    let persistedDrawing = PKDrawing().dataRepresentation()
    let invalidOverride = Data("not-pencilkit".utf8)
    #expect(!persistedDrawing.isEmpty)

    try await fixture.repository.saveLibrary(library)
    try await fixture.repository.saveDrawing(persistedDrawing, pageID: pageID)

    await #expect(throws: BackupSnapshotError.invalidDrawing) {
      try await fixture.repository.makeBackup(
        library: library,
        drawingOverrides: [pageID: invalidOverride],
        sourceAppVersion: "0.2.0",
        sourceBuild: "2"
      )
    }

    #expect(try await fixture.repository.loadDrawing(pageID: pageID) == persistedDrawing)
    let persistedLibrary = try #require(try await fixture.repository.loadLibrary())
    expectSameLibraryContent(persistedLibrary, library)
  }

  @Test("Restore validates the current in-memory drawing before its persistence barrier")
  func restoreValidatesCurrentOverrideBeforePersisting() async throws {
    let fixture = makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let currentLibrary = LibraryDocument.starter()
    let currentPageID = try #require(currentLibrary.notebooks.first?.pages.first?.id)
    let persistedDrawing = PKDrawing().dataRepresentation()
    let invalidOverride = Data("not-pencilkit".utf8)
    try await fixture.repository.saveLibrary(currentLibrary)
    try await fixture.repository.saveDrawing(persistedDrawing, pageID: currentPageID)

    let sourceLibrary = LibraryDocument.starter()
    let sourcePageID = try #require(sourceLibrary.notebooks.first?.pages.first?.id)
    let archive = try BackupArchiveCodec.encode(
      library: sourceLibrary,
      drawings: [sourcePageID: PKDrawing().dataRepresentation()],
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    await #expect(throws: BackupSnapshotError.invalidDrawing) {
      try await fixture.repository.restoreBackupAsCopy(
        archive,
        currentLibrary: currentLibrary,
        currentDrawingOverrides: [currentPageID: invalidOverride]
      )
    }

    #expect(try await fixture.repository.loadDrawing(pageID: currentPageID) == persistedDrawing)
    let persistedLibrary = try #require(try await fixture.repository.loadLibrary())
    expectSameLibraryContent(persistedLibrary, currentLibrary)
  }

  @Test("A valid live override persists before an unrelated stored drawing fails backup")
  func validOverridePersistsBeforeWholeLibraryFailure() async throws {
    let fixture = makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    var library = LibraryDocument.starter()
    let currentPageID = try #require(library.notebooks.first?.pages.first?.id)
    let invalidPage = NotePage(title: "损坏页")
    library.notebooks[0].pages.append(invalidPage)

    let oldDrawing = PKDrawing().dataRepresentation()
    let latestDrawingURL = try #require(
      Bundle.module.url(
        forResource: "single-stroke-v1",
        withExtension: "pkdrawing",
        subdirectory: "Fixtures/BackupV1"
      )
    )
    let latestDrawing = try Data(contentsOf: latestDrawingURL)
    #expect(try PKDrawing(data: latestDrawing).strokes.count == 1)
    #expect(latestDrawing != oldDrawing)

    try await fixture.repository.saveLibrary(library)
    try await fixture.repository.saveDrawing(oldDrawing, pageID: currentPageID)
    try await fixture.repository.saveDrawing(
      Data("not-pencilkit".utf8),
      pageID: invalidPage.id
    )

    await #expect(throws: BackupSnapshotError.invalidDrawing) {
      try await fixture.repository.makeBackup(
        library: library,
        drawingOverrides: [currentPageID: latestDrawing],
        sourceAppVersion: "0.2.0",
        sourceBuild: "2"
      )
    }

    #expect(try await fixture.repository.loadDrawing(pageID: currentPageID) == latestDrawing)
  }

  private func makeRepository() -> (rootURL: URL, repository: DrawingRepository) {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return (rootURL, DrawingRepository(rootURL: rootURL))
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
