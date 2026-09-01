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

    #expect(decoded.formatVersion == BackupArchiveCodec.legacyFormatVersion)
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

    let repeatedPreview = try await fixture.repository.inspectBackup(
      archive,
      currentLibrary: result.library
    )
    #expect(repeatedPreview.restoreReadiness == .alreadyRestored)
  }

  @Test("A v2 backup restores as a copy without replacing current notes")
  func restoreVersionTwoAsCopy() async throws {
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
    let archive = try BackupArchiveCodec.encodeV2(
      library: sourceLibrary,
      drawings: [sourcePageID: sourceDrawing],
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let result = try await fixture.repository.restoreBackupAsCopy(
      archive,
      currentLibrary: currentLibrary,
      currentDrawingOverrides: [currentPageID: currentDrawing],
      importedAt: Date(timeIntervalSince1970: 1_700_000_100)
    )

    #expect(result.disposition == .imported)
    #expect(result.library.notebooks.count == 2)
    #expect(try await fixture.repository.loadDrawing(pageID: currentPageID) == currentDrawing)
    #expect(
      try await fixture.repository.loadDrawing(pageID: result.selectedPageID)
        == sourceDrawing
    )
  }

  @Test("Export and restore preserve user-saved page sources with remapped pages")
  func pageSourcesFollowRestoredCopyAndCanBeRepaired() async throws {
    let sourceFixture = makeRepository()
    let destinationFixture = makeRepository()
    defer {
      try? FileManager.default.removeItem(at: sourceFixture.rootURL)
      try? FileManager.default.removeItem(at: destinationFixture.rootURL)
    }

    let sourceLibrary = LibraryDocument.starter()
    let sourcePageID = try #require(sourceLibrary.notebooks.first?.pages.first?.id)
    let sourceDrawing = PKDrawing().dataRepresentation()
    let source = PageSourceExcerpt(
      id: UUID(uuidString: "71000000-0000-0000-0000-000000000001")!,
      title: "网页资料",
      excerpt: "只保存用户主动选择的这一段。",
      sourceURL: URL(string: "https://example.com/notes")!,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_010)
    )
    try await sourceFixture.repository.saveLibrary(sourceLibrary)
    try await sourceFixture.repository.saveDrawing(sourceDrawing, pageID: sourcePageID)
    try await sourceFixture.repository.savePageSources([source], pageID: sourcePageID)
    let archive = try await sourceFixture.repository.makeBackup(
      library: sourceLibrary,
      drawingOverrides: [:],
      sourceAppVersion: "0.2.0",
      sourceBuild: "3",
      createdAt: Date(timeIntervalSince1970: 1_700_000_020)
    )
    #expect(
      try BackupArchiveCodec.decode(archive).formatVersion
        == BackupArchiveCodec.pageSourceFormatVersion
    )
    let preview = try await sourceFixture.repository.inspectBackup(
      archive,
      currentLibrary: LibraryDocument.starter()
    )
    #expect(preview.notebookCount == 1)
    #expect(preview.pageCount == 1)
    #expect(preview.sourceCount == 1)
    #expect(preview.restoreReadiness == .readyToAddCopy)

    let currentLibrary = LibraryDocument.starter()
    let currentPageID = try #require(currentLibrary.notebooks.first?.pages.first?.id)
    let currentDrawing = PKDrawing().dataRepresentation()
    try await destinationFixture.repository.saveLibrary(currentLibrary)
    try await destinationFixture.repository.saveDrawing(currentDrawing, pageID: currentPageID)
    let first = try await destinationFixture.repository.restoreBackupAsCopy(
      archive,
      currentLibrary: currentLibrary,
      currentDrawingOverrides: [:],
      importedAt: Date(timeIntervalSince1970: 1_700_000_030)
    )
    #expect(first.selectedPageID != sourcePageID)
    #expect(first.selectedPageSources == [source])
    #expect(
      try await destinationFixture.repository.loadPageSources(pageID: first.selectedPageID)
        == [source]
    )
    #expect(try await destinationFixture.repository.loadPageSources(pageID: currentPageID).isEmpty)

    let sourceFile = destinationFixture.rootURL
      .appendingPathComponent(DrawingRepository.pageSourcesDirectoryName, isDirectory: true)
      .appendingPathComponent(first.selectedPageID.uuidString.lowercased())
      .appendingPathExtension(DrawingRepository.pageSourceFileExtension)
    try FileManager.default.removeItem(at: sourceFile)
    let retry = try await destinationFixture.repository.restoreBackupAsCopy(
      archive,
      currentLibrary: first.library,
      currentDrawingOverrides: [:]
    )
    #expect(retry.disposition == .alreadyImported)
    #expect(retry.repairedSourceCount == 1)
    #expect(retry.repairedSourcePageIDs == [first.selectedPageID])
    #expect(
      try await destinationFixture.repository.loadPageSources(pageID: first.selectedPageID)
        == [source]
    )

    let editedSource = PageSourceExcerpt(
      id: source.id,
      title: source.title,
      excerpt: "用户导入后修改的来源内容。",
      sourceURL: source.sourceURL,
      capturedAt: source.capturedAt
    )
    try await destinationFixture.repository.savePageSources(
      [editedSource],
      pageID: first.selectedPageID
    )
    await #expect(throws: BackupSnapshotError.orphanSourceConflict) {
      try await destinationFixture.repository.restoreBackupAsCopy(
        archive,
        currentLibrary: first.library,
        currentDrawingOverrides: [:]
      )
    }
    #expect(
      try await destinationFixture.repository.loadPageSources(pageID: first.selectedPageID)
        == [editedSource]
    )
  }

  @Test("A new restore accepts the exact combined notebook and page limits")
  func newRestoreCapacityAcceptsExactLimits() throws {
    try DrawingRepository.validateNewRestoreCapacity(
      currentLibrary: makeNotebookLibrary(
        notebookCount: BackupArchiveLimits.maximumNotebookCount - 1
      ),
      backupLibrary: makeNotebookLibrary(notebookCount: 1)
    )
    try DrawingRepository.validateNewRestoreCapacity(
      currentLibrary: makePageLibrary(
        pageCount: BackupArchiveLimits.maximumPageCount - 1
      ),
      backupLibrary: makePageLibrary(pageCount: 1)
    )
  }

  @Test("Inspection admits an exact-limit restore without writing local state")
  func restorePreflightAcceptsExactLimitWithoutWrites() async throws {
    let fixture = makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let sourceLibrary = makePageLibrary(pageCount: 1)
    let sourcePageID = try #require(sourceLibrary.notebooks.first?.pages.first?.id)
    let archive = try BackupArchiveCodec.encode(
      library: sourceLibrary,
      drawings: [sourcePageID: Data()],
      createdAt: Date(timeIntervalSince1970: 1_700_060_000),
      backupID: UUID(uuidString: "E5000000-0000-0000-0000-000000000020")!
    )
    let currentLibrary = makePageLibrary(
      pageCount: BackupArchiveLimits.maximumPageCount - 1
    )

    #expect(!FileManager.default.fileExists(atPath: fixture.rootURL.path))
    let preview = try await fixture.repository.inspectBackup(
      archive,
      currentLibrary: currentLibrary
    )

    #expect(preview.restoreReadiness == .readyToAddCopy)
    #expect(!FileManager.default.fileExists(atPath: fixture.rootURL.path))
  }

  @Test("Notebook overflow is rejected before any restore WAL is created")
  func notebookOverflowDoesNotConsumeRestoreTransactions() async throws {
    let fixture = makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let currentLibrary = makeNotebookLibrary(
      notebookCount: BackupArchiveLimits.maximumNotebookCount
    )
    try await fixture.repository.saveLibrary(currentLibrary)
    let libraryURL = fixture.rootURL.appendingPathComponent("library.json")
    let drawingsURL = fixture.rootURL.appendingPathComponent("Drawings", isDirectory: true)
    let transactionsURL = fixture.rootURL.appendingPathComponent(
      DrawingRepository.restoreTransactionsDirectoryName,
      isDirectory: true
    )
    let libraryBefore = try Data(contentsOf: libraryURL)
    let drawingsBefore = try Set(FileManager.default.contentsOfDirectory(atPath: drawingsURL.path))
    #expect(!FileManager.default.fileExists(atPath: transactionsURL.path))

    let sourceLibrary = makeNotebookLibrary(notebookCount: 1)
    let sourcePageID = try #require(sourceLibrary.notebooks.first?.pages.first?.id)
    for _ in 0..<3 {
      let backupID = UUID()
      let archive = try BackupArchiveCodec.encode(
        library: sourceLibrary,
        drawings: [sourcePageID: Data()],
        createdAt: Date(timeIntervalSince1970: 1_700_010_000),
        backupID: backupID
      )

      let preview = try await fixture.repository.inspectBackup(
        archive,
        currentLibrary: currentLibrary
      )
      #expect(preview.restoreReadiness == .blocked(.notebookLimit))

      await #expect(
        throws: BackupArchiveError.tooManyNotebooks(
          actual: BackupArchiveLimits.maximumNotebookCount + 1,
          maximum: BackupArchiveLimits.maximumNotebookCount
        )
      ) {
        try await fixture.repository.restoreBackupAsCopy(
          archive,
          currentLibrary: currentLibrary,
          currentDrawingOverrides: [:]
        )
      }
      #expect(try await fixture.repository.loadRestoreTransaction(backupID: backupID) == nil)
    }

    #expect(!FileManager.default.fileExists(atPath: transactionsURL.path))
    #expect(try Data(contentsOf: libraryURL) == libraryBefore)
    #expect(
      try Set(FileManager.default.contentsOfDirectory(atPath: drawingsURL.path))
        == drawingsBefore
    )
  }

  @Test("Page overflow creates no restore WAL or imported files")
  func pageOverflowDoesNotCreateRestoreWrites() async throws {
    let fixture = makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let currentLibrary = makePageLibrary(
      pageCount: BackupArchiveLimits.maximumPageCount - 1
    )
    try await fixture.repository.saveLibrary(currentLibrary)
    let libraryURL = fixture.rootURL.appendingPathComponent("library.json")
    let drawingsURL = fixture.rootURL.appendingPathComponent("Drawings", isDirectory: true)
    let transactionsURL = fixture.rootURL.appendingPathComponent(
      DrawingRepository.restoreTransactionsDirectoryName,
      isDirectory: true
    )
    let libraryBefore = try Data(contentsOf: libraryURL)
    let drawingsBefore = try Set(FileManager.default.contentsOfDirectory(atPath: drawingsURL.path))

    let sourceLibrary = makePageLibrary(pageCount: 2)
    let sourcePageIDs = sourceLibrary.notebooks.flatMap(\.pages).map(\.id)
    let archive = try BackupArchiveCodec.encode(
      library: sourceLibrary,
      drawings: Dictionary(uniqueKeysWithValues: sourcePageIDs.map { ($0, Data()) }),
      createdAt: Date(timeIntervalSince1970: 1_700_020_000),
      backupID: UUID(uuidString: "E5000000-0000-0000-0000-000000000010")!
    )

    let preview = try await fixture.repository.inspectBackup(
      archive,
      currentLibrary: currentLibrary
    )
    #expect(preview.restoreReadiness == .blocked(.pageLimit))

    await #expect(
      throws: BackupArchiveError.tooManyPages(
        actual: BackupArchiveLimits.maximumPageCount + 1,
        maximum: BackupArchiveLimits.maximumPageCount
      )
    ) {
      try await fixture.repository.restoreBackupAsCopy(
        archive,
        currentLibrary: currentLibrary,
        currentDrawingOverrides: [:]
      )
    }

    #expect(
      try await fixture.repository.loadRestoreTransaction(
        backupID: UUID(uuidString: "E5000000-0000-0000-0000-000000000010")!
      ) == nil
    )
    #expect(!FileManager.default.fileExists(atPath: transactionsURL.path))
    #expect(try Data(contentsOf: libraryURL) == libraryBefore)
    #expect(
      try Set(FileManager.default.contentsOfDirectory(atPath: drawingsURL.path))
        == drawingsBefore
    )
  }

  @Test("An existing restore plan cannot bypass notebook capacity after the library changes")
  func existingRestorePlanRechecksNotebookCapacity() async throws {
    let fixture = makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let sourceLibrary = makeNotebookLibrary(notebookCount: 1)
    let sourcePageID = try #require(sourceLibrary.notebooks.first?.pages.first?.id)
    let backupID = UUID(uuidString: "E5000000-0000-0000-0000-000000000021")!
    let archive = try BackupArchiveCodec.encode(
      library: sourceLibrary,
      drawings: [sourcePageID: Data()],
      createdAt: Date(timeIntervalSince1970: 1_700_060_100),
      backupID: backupID
    )
    _ = try await fixture.repository.restoreBackupAsCopy(
      archive,
      currentLibrary: LibraryDocument.starter(),
      currentDrawingOverrides: [:]
    )
    let transactionBefore = try #require(
      try await fixture.repository.loadRestoreTransaction(backupID: backupID)
    )

    let currentLibrary = makeNotebookLibrary(
      notebookCount: BackupArchiveLimits.maximumNotebookCount
    )
    try await fixture.repository.saveLibrary(currentLibrary)
    let libraryURL = fixture.rootURL.appendingPathComponent(DrawingRepository.libraryFilename)
    let libraryBefore = try Data(contentsOf: libraryURL)

    let preview = try await fixture.repository.inspectBackup(
      archive,
      currentLibrary: currentLibrary
    )
    #expect(preview.restoreReadiness == .blocked(.notebookLimit))
    await #expect(
      throws: BackupArchiveError.tooManyNotebooks(
        actual: BackupArchiveLimits.maximumNotebookCount + 1,
        maximum: BackupArchiveLimits.maximumNotebookCount
      )
    ) {
      try await fixture.repository.restoreBackupAsCopy(
        archive,
        currentLibrary: currentLibrary,
        currentDrawingOverrides: [:]
      )
    }

    #expect(try Data(contentsOf: libraryURL) == libraryBefore)
    #expect(
      try await fixture.repository.loadRestoreTransaction(backupID: backupID)
        == transactionBefore
    )
  }

  @Test("Manifest overflow creates no restore WAL or imported files")
  func manifestOverflowDoesNotCreateRestoreWrites() async throws {
    let fixture = makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let currentLibrary = try makeManifestBudgetTestFixture().exact
    try await fixture.repository.saveLibrary(currentLibrary)
    let libraryURL = fixture.rootURL.appendingPathComponent(DrawingRepository.libraryFilename)
    let drawingsURL = fixture.rootURL.appendingPathComponent(
      DrawingRepository.drawingsDirectoryName,
      isDirectory: true
    )
    let transactionsURL = fixture.rootURL.appendingPathComponent(
      DrawingRepository.restoreTransactionsDirectoryName,
      isDirectory: true
    )
    let libraryBefore = try Data(contentsOf: libraryURL)
    let drawingsBefore = try Set(FileManager.default.contentsOfDirectory(atPath: drawingsURL.path))

    let sourcePage = NotePage(
      id: UUID(uuidString: "52000000-0000-0000-0000-000000000001")!,
      title: "Source page"
    )
    let sourceLibrary = LibraryDocument(notebooks: [
      Notebook(
        id: UUID(uuidString: "42000000-0000-0000-0000-000000000001")!,
        title: "Source notebook",
        pages: [sourcePage]
      )
    ])
    let backupID = UUID(uuidString: "E5000000-0000-0000-0000-000000000012")!
    let archive = try BackupArchiveCodec.encode(
      library: sourceLibrary,
      drawings: [sourcePage.id: Data()],
      createdAt: Date(timeIntervalSince1970: 1_700_040_000),
      backupID: backupID
    )

    let preview = try await fixture.repository.inspectBackup(
      archive,
      currentLibrary: currentLibrary
    )
    #expect(preview.restoreReadiness == .blocked(.librarySizeLimit))

    do {
      _ = try await fixture.repository.restoreBackupAsCopy(
        archive,
        currentLibrary: currentLibrary,
        currentDrawingOverrides: [:]
      )
      Issue.record("Expected the merged manifest projection to exceed the v1 limit")
    } catch BackupArchiveError.manifestTooLarge(let actual, let maximum) {
      #expect(actual > maximum)
      #expect(maximum == BackupArchiveLimits.maximumManifestByteCount)
    }

    #expect(try await fixture.repository.loadRestoreTransaction(backupID: backupID) == nil)
    #expect(!FileManager.default.fileExists(atPath: transactionsURL.path))
    #expect(try Data(contentsOf: libraryURL) == libraryBefore)
    #expect(
      try Set(FileManager.default.contentsOfDirectory(atPath: drawingsURL.path))
        == drawingsBefore
    )
  }

  @Test("An existing WAL cannot replay an oversized merged manifest")
  func existingRestoreTransactionCannotBypassManifestBudget() async throws {
    let fixture = makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let sourcePage = NotePage(
      id: UUID(uuidString: "53000000-0000-0000-0000-000000000001")!,
      title: "Source page"
    )
    let sourceLibrary = LibraryDocument(notebooks: [
      Notebook(
        id: UUID(uuidString: "43000000-0000-0000-0000-000000000001")!,
        title: "Source notebook",
        pages: [sourcePage]
      )
    ])
    let backupID = UUID(uuidString: "E5000000-0000-0000-0000-000000000013")!
    let archive = try BackupArchiveCodec.encode(
      library: sourceLibrary,
      drawings: [sourcePage.id: Data()],
      createdAt: Date(timeIntervalSince1970: 1_700_050_000),
      backupID: backupID
    )
    let starter = LibraryDocument.starter()
    _ = try await fixture.repository.restoreBackupAsCopy(
      archive,
      currentLibrary: starter,
      currentDrawingOverrides: [:]
    )
    let transactionBefore = try #require(
      try await fixture.repository.loadRestoreTransaction(backupID: backupID)
    )

    let boundaryFixture = try makeManifestBudgetTestFixture()
    let currentLibrary = boundaryFixture.exact
    try await fixture.repository.saveLibrary(currentLibrary)
    let libraryURL = fixture.rootURL.appendingPathComponent(DrawingRepository.libraryFilename)
    let drawingsURL = fixture.rootURL.appendingPathComponent(
      DrawingRepository.drawingsDirectoryName,
      isDirectory: true
    )
    let libraryBefore = try Data(contentsOf: libraryURL)
    let drawingsBefore = try Set(FileManager.default.contentsOfDirectory(atPath: drawingsURL.path))

    do {
      _ = try await fixture.repository.restoreBackupAsCopy(
        archive,
        currentLibrary: currentLibrary,
        currentDrawingOverrides: [:]
      )
      Issue.record("Expected an existing restore transaction to remain manifest-budget gated")
    } catch BackupArchiveError.manifestTooLarge(let actual, let maximum) {
      #expect(actual > maximum)
      #expect(maximum == BackupArchiveLimits.maximumManifestByteCount)
    }

    #expect(
      try await fixture.repository.loadRestoreTransaction(backupID: backupID)
        == transactionBefore
    )
    #expect(try Data(contentsOf: libraryURL) == libraryBefore)
    #expect(
      try Set(FileManager.default.contentsOfDirectory(atPath: drawingsURL.path))
        == drawingsBefore
    )

    var repairedLibrary = currentLibrary
    let bulkNotebookIndex = try #require(
      repairedLibrary.notebooks.firstIndex(where: { $0.id == boundaryFixture.bulkNotebookID })
    )
    let longPageIndex = try #require(
      repairedLibrary.notebooks[bulkNotebookIndex].pages.firstIndex(
        where: { $0.title.utf8.count == BackupArchiveLimits.maximumTitleUTF8ByteCount }
      )
    )
    repairedLibrary.notebooks[bulkNotebookIndex].pages[longPageIndex].title = "x"
    try await fixture.repository.saveLibrary(repairedLibrary)

    let resumed = try await fixture.repository.restoreBackupAsCopy(
      archive,
      currentLibrary: repairedLibrary,
      currentDrawingOverrides: [:]
    )

    #expect(resumed.disposition == .imported)
    #expect(
      try await fixture.repository.loadRestoreTransaction(backupID: backupID)
        == transactionBefore
    )
  }

  @Test("A completed legacy oversized restore can still repair a missing drawing")
  func completedLegacyRestoreCanRepairWithoutManifestGrowth() async throws {
    let fixture = makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let sourcePage = NotePage(
      id: UUID(uuidString: "54000000-0000-0000-0000-000000000001")!,
      title: "Source page"
    )
    let sourceLibrary = LibraryDocument(notebooks: [
      Notebook(
        id: UUID(uuidString: "44000000-0000-0000-0000-000000000001")!,
        title: "Source notebook",
        pages: [sourcePage]
      )
    ])
    let sourceDrawing = try serializedStrokeDrawing()
    let backupID = UUID(uuidString: "E5000000-0000-0000-0000-000000000014")!
    let archive = try BackupArchiveCodec.encode(
      library: sourceLibrary,
      drawings: [sourcePage.id: sourceDrawing],
      createdAt: Date(timeIntervalSince1970: 1_700_060_000),
      backupID: backupID
    )
    let starter = LibraryDocument.starter()
    _ = try await fixture.repository.restoreBackupAsCopy(
      archive,
      currentLibrary: starter,
      currentDrawingOverrides: [:]
    )
    let transaction = try #require(
      try await fixture.repository.loadRestoreTransaction(backupID: backupID)
    )
    let copiedPageID = try #require(transaction.copiedNotebooks.first?.pages.first?.id)

    var legacyLibrary = try makeManifestBudgetTestFixture().oneByteOver
    legacyLibrary.notebooks.append(contentsOf: transaction.copiedNotebooks)
    #expect(
      try BackupArchiveCodec.projectedManifestByteCount(for: legacyLibrary)
        > BackupArchiveLimits.maximumManifestByteCount
    )
    try await fixture.repository.saveLibrary(legacyLibrary)
    try await fixture.repository.removeDrawingIfPresent(pageID: copiedPageID)

    let retry = try await fixture.repository.restoreBackupAsCopy(
      archive,
      currentLibrary: legacyLibrary,
      currentDrawingOverrides: [:]
    )

    #expect(retry.disposition == .alreadyImported)
    #expect(retry.repairedDrawingCount == 1)
    #expect(retry.repairedPageIDs == [copiedPageID])
    #expect(try await fixture.repository.loadDrawing(pageID: copiedPageID) == sourceDrawing)
    let persistedLibrary = try #require(try await fixture.repository.loadLibrary())
    expectSameLibraryContent(persistedLibrary, legacyLibrary)
  }

  @Test("A completed restore at the page limit still retries from its existing WAL")
  func pageLimitRestoreRetryUsesExistingTransaction() async throws {
    let fixture = makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let currentLibrary = makePageLibrary(
      pageCount: BackupArchiveLimits.maximumPageCount - 1
    )
    try await fixture.repository.saveLibrary(currentLibrary)
    let sourceLibrary = makePageLibrary(pageCount: 1)
    let sourcePageID = try #require(sourceLibrary.notebooks.first?.pages.first?.id)
    let backupID = UUID(uuidString: "E5000000-0000-0000-0000-000000000011")!
    let archive = try BackupArchiveCodec.encode(
      library: sourceLibrary,
      drawings: [sourcePageID: Data()],
      createdAt: Date(timeIntervalSince1970: 1_700_030_000),
      backupID: backupID
    )

    let first = try await fixture.repository.restoreBackupAsCopy(
      archive,
      currentLibrary: currentLibrary,
      currentDrawingOverrides: [:]
    )
    let committedLibrary = try #require(try await fixture.repository.loadLibrary())
    let retry = try await fixture.repository.restoreBackupAsCopy(
      archive,
      currentLibrary: committedLibrary,
      currentDrawingOverrides: [:]
    )

    #expect(first.disposition == .imported)
    #expect(retry.disposition == .alreadyImported)
    #expect(
      retry.library.notebooks.flatMap(\.pages).count
        == BackupArchiveLimits.maximumPageCount
    )
    #expect(retry.selectedNotebookID == first.selectedNotebookID)
    #expect(retry.selectedPageID == first.selectedPageID)
    #expect(try await fixture.repository.loadRestoreTransaction(backupID: backupID) != nil)
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

    let preview = try await fixture.repository.inspectBackup(
      archive,
      currentLibrary: partialLibrary
    )
    #expect(preview.restoreReadiness == .blocked(.incompletePreviousRestore))

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

  private func makeNotebookLibrary(notebookCount: Int) -> LibraryDocument {
    LibraryDocument(
      notebooks: (0..<notebookCount).map { index in
        Notebook(title: "Notebook \(index)", pages: [NotePage(title: "Page \(index)")])
      }
    )
  }

  private func makePageLibrary(pageCount: Int) -> LibraryDocument {
    LibraryDocument(
      notebooks: [
        Notebook(
          title: "Notebook",
          pages: (0..<pageCount).map { NotePage(title: "Page \($0)") }
        )
      ]
    )
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
