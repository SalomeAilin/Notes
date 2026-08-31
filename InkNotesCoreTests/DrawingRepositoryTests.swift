import Foundation
import PencilKit
import Testing

@testable import InkNotesCore

@Suite("InkNotes local persistence")
struct DrawingRepositoryTests {
  @Test("Default storage resolution fails closed without Application Support")
  func defaultStorageResolutionFailsClosed() async {
    let fileManager = ApplicationSupportUnavailableFileManager()
    let isolatedTemporaryDirectory = fileManager.temporaryDirectory
    defer { try? FileManager.default.removeItem(at: isolatedTemporaryDirectory) }
    let temporaryFallback =
      isolatedTemporaryDirectory
      .appendingPathComponent(DrawingRepository.persistedDirectoryName, isDirectory: true)

    #expect(DrawingRepository.defaultRootURL(fileManager: fileManager) == nil)
    let repository = DrawingRepository(fileManager: fileManager)
    await #expect(throws: DrawingRepositoryError.persistenceDirectoryUnavailable) {
      _ = try await repository.loadLibrary()
    }
    await #expect(throws: DrawingRepositoryError.persistenceDirectoryUnavailable) {
      try await repository.saveLibrary(LibraryDocument.starter())
    }
    #expect(!FileManager.default.fileExists(atPath: temporaryFallback.path))
  }

  @Test("Default storage creates a fresh Application Support directory before saving")
  func defaultStorageBootstrapsApplicationSupport() async throws {
    let fileManager = IsolatedApplicationSupportFileManager()
    let containerURL = fileManager.containerURL
    defer { try? FileManager.default.removeItem(at: containerURL) }
    try FileManager.default.createDirectory(
      at: containerURL.appendingPathComponent("Library", isDirectory: true),
      withIntermediateDirectories: true
    )
    let applicationSupportURL = fileManager.applicationSupportURL

    let repository = DrawingRepository(fileManager: fileManager)
    try await repository.saveLibrary(LibraryDocument.starter())

    let rootURL = applicationSupportURL.appendingPathComponent(
      DrawingRepository.persistedDirectoryName,
      isDirectory: true
    )
    #expect(FileManager.default.fileExists(atPath: applicationSupportURL.path))
    #expect(
      FileManager.default.fileExists(
        atPath: rootURL.appendingPathComponent(DrawingRepository.libraryFilename).path
      )
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: applicationSupportURL.deletingLastPathComponent()
          .appendingPathComponent(POSIXDurableFileWriter.lockFilename).path
      )
    )
  }

  @Test("The store enters read-only protection when permanent storage is unavailable")
  @MainActor
  func storeProtectsUnavailablePermanentStorage() async throws {
    let fileManager = ApplicationSupportUnavailableFileManager()
    let isolatedTemporaryDirectory = fileManager.temporaryDirectory
    defer { try? FileManager.default.removeItem(at: isolatedTemporaryDirectory) }
    let temporaryFallback =
      isolatedTemporaryDirectory
      .appendingPathComponent(DrawingRepository.persistedDirectoryName, isDirectory: true)
    let repository = DrawingRepository(fileManager: fileManager)
    let store = LibraryStore(repository: repository)

    for _ in 0..<100 {
      if !store.isLoading { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(!store.isLoading)
    #expect(store.isReadOnly)
    #expect(store.persistenceError?.contains("永久存储目录") == true)
    #expect(!FileManager.default.fileExists(atPath: temporaryFallback.path))
  }

  @Test("Library metadata and drawing bytes survive a round trip")
  func roundTrip() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let repository = DrawingRepository(rootURL: rootURL)
    let library = LibraryDocument.starter()
    let pageID = try #require(library.notebooks.first?.pages.first?.id)
    let drawing = Data([0x49, 0x4E, 0x4B])

    try await repository.saveLibrary(library)
    try await repository.saveDrawing(drawing, pageID: pageID)

    let restored = try #require(try await repository.loadLibrary())
    #expect(restored.schemaVersion == library.schemaVersion)
    #expect(restored.notebooks.map(\.id) == library.notebooks.map(\.id))
    #expect(restored.notebooks.map(\.title) == library.notebooks.map(\.title))
    #expect(
      restored.notebooks.flatMap(\.pages).map(\.id) == library.notebooks.flatMap(\.pages).map(\.id))
    #expect(
      abs(restored.notebooks[0].updatedAt.timeIntervalSince(library.notebooks[0].updatedAt)) < 0.001
    )
    #expect(try await repository.loadDrawing(pageID: pageID) == drawing)
  }

  @Test("Segmented saves publish durable local content before the page authority")
  func segmentedSaveOrderingAndRoundTrip() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: rootURL) }
    let pageID = UUID(uuidString: "12000000-0000-0000-0000-000000000001")!
    let sourceData = try fixtureDrawingData()
    let recorder = SegmentedWriteRecorder()
    let writer = POSIXDurableFileWriter { stage, url in
      recorder.record(stage: stage, url: url)
    }
    let repository = DrawingRepository(rootURL: rootURL, durableFileWriter: writer)

    try await repository.saveSegmentedDrawing(sourceData, pageID: pageID)

    let authorityURL = drawingURL(rootURL: rootURL, pageID: pageID)
    let authorityData = try Data(contentsOf: authorityURL)
    #expect(SegmentedDrawingCodec.isSegmentedAuthority(authorityData))
    #expect(throws: (any Error).self) {
      _ = try PKDrawing(data: authorityData)
    }
    let authority = try SegmentedDrawingCodec.decodeAuthority(
      authorityData,
      expectedPageID: pageID
    )
    let publishedURLs = recorder.events()
      .filter { $0.stage == .published }
      .map(\.url)
    let uniqueBlobCount = Set(
      authority.entries.map(\.sha256) + authority.sourceChunks.map(\.sha256)
    ).count
    #expect(publishedURLs.last == authorityURL)
    #expect(publishedURLs.dropLast().count == uniqueBlobCount)
    #expect(
      publishedURLs.dropLast().allSatisfy {
        $0.path.contains("/\(DrawingRepository.segmentedDrawingsDirectoryName)/")
      }
    )

    let loadedData = try #require(try await repository.loadDrawing(pageID: pageID))
    let source = try PKDrawing(data: sourceData)
    let loaded = try PKDrawing(data: loadedData)
    #expect(loaded.strokes.count == source.strokes.count)
    #expect(loaded.strokes.map(\.renderBounds) == source.strokes.map(\.renderBounds))
  }

  @Test("A failure before authority publication preserves the previous complete drawing")
  func segmentedSaveFailurePreservesLegacyAuthority() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: rootURL) }
    let pageID = UUID(uuidString: "12000000-0000-0000-0000-000000000002")!
    let drawingsURL = rootURL.appendingPathComponent(
      DrawingRepository.drawingsDirectoryName,
      isDirectory: true
    )
    try fileManager.createDirectory(at: drawingsURL, withIntermediateDirectories: true)
    let authorityURL = drawingURL(rootURL: rootURL, pageID: pageID)
    let legacyData = try fixtureDrawingData()
    try legacyData.write(to: authorityURL)

    let writer = POSIXDurableFileWriter { stage, url in
      if stage == .fileSynchronized, url == authorityURL {
        throw SegmentedSaveInjectedError.beforeAuthorityPublication
      }
    }
    let repository = DrawingRepository(rootURL: rootURL, durableFileWriter: writer)

    await #expect(throws: SegmentedSaveInjectedError.beforeAuthorityPublication) {
      try await repository.saveSegmentedDrawing(legacyData, pageID: pageID)
    }
    #expect(try Data(contentsOf: authorityURL) == legacyData)
    #expect(try await repository.loadDrawing(pageID: pageID) == legacyData)
  }

  @Test("Repeated saves reuse verified blobs and legacy writes cannot downgrade authority")
  func segmentedBlobReuseAndDowngradeProtection() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: rootURL) }
    let pageID = UUID(uuidString: "12000000-0000-0000-0000-000000000003")!
    let sourceData = try fixtureDrawingData()
    let recorder = SegmentedWriteRecorder()
    let writer = POSIXDurableFileWriter { stage, url in
      recorder.record(stage: stage, url: url)
    }
    let repository = DrawingRepository(rootURL: rootURL, durableFileWriter: writer)
    try await repository.saveSegmentedDrawing(sourceData, pageID: pageID)
    recorder.clear()

    try await repository.saveSegmentedDrawing(sourceData, pageID: pageID)
    #expect(
      !recorder.events().contains {
        $0.stage == .temporaryFileCreated
          && $0.url.path.contains("/\(DrawingRepository.segmentedDrawingsDirectoryName)/")
      }
    )

    try await repository.saveDrawing(sourceData, pageID: pageID)
    let authorityData = try Data(contentsOf: drawingURL(rootURL: rootURL, pageID: pageID))
    #expect(SegmentedDrawingCodec.isSegmentedAuthority(authorityData))
  }

  @Test("Missing and modified segmented content fail closed")
  func segmentedBlobIntegrityFailures() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: rootURL) }
    let pageID = UUID(uuidString: "12000000-0000-0000-0000-000000000004")!
    let repository = DrawingRepository(rootURL: rootURL)
    try await repository.saveSegmentedDrawing(try fixtureDrawingData(), pageID: pageID)
    let authorityData = try Data(contentsOf: drawingURL(rootURL: rootURL, pageID: pageID))
    let authority = try SegmentedDrawingCodec.decodeAuthority(
      authorityData,
      expectedPageID: pageID
    )
    let chunk = try #require(authority.sourceChunks.first)
    let blobURL = segmentBlobURL(rootURL: rootURL, pageID: pageID, digest: chunk.sha256)
    let blobData = try Data(contentsOf: blobURL)
    try fileManager.removeItem(at: blobURL)

    await #expect(throws: SegmentedDrawingError.missingSegment(chunk.sha256)) {
      _ = try await repository.loadDrawing(pageID: pageID)
    }

    var modifiedData = blobData
    modifiedData[modifiedData.count - 1] ^= 0x01
    try modifiedData.write(to: blobURL)
    await #expect(throws: SegmentedDrawingError.segmentChecksumMismatch) {
      _ = try await repository.loadDrawing(pageID: pageID)
    }
  }

  @Test("Visible-region reads load only intersecting ink and preserve global order")
  func segmentedVisibleRegionReads() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: rootURL) }
    let pageID = UUID(uuidString: "12000000-0000-0000-0000-000000000005")!
    let source = try drawingAcrossRegions()
    let repository = DrawingRepository(rootURL: rootURL)
    try await repository.saveSegmentedDrawing(source.dataRepresentation(), pageID: pageID)

    let topData = try #require(
      try await repository.loadDrawingRegion(pageID: pageID, verticalRange: 0...4_095)
    )
    let middleData = try #require(
      try await repository.loadDrawingRegion(pageID: pageID, verticalRange: 4_096...8_191)
    )
    let allData = try #require(
      try await repository.loadDrawingRegion(pageID: pageID, verticalRange: 0...12_000)
    )
    let top = try PKDrawing(data: topData)
    let middle = try PKDrawing(data: middleData)
    let all = try PKDrawing(data: allData)

    #expect(top.strokes.map(\.renderBounds) == [source.strokes[1].renderBounds])
    #expect(middle.strokes.map(\.renderBounds) == [source.strokes[0].renderBounds])
    #expect(all.strokes.map(\.renderBounds) == source.strokes.map(\.renderBounds))
  }

  @Test("Duplicate notebook identifiers are rejected without rewriting the library")
  func duplicateNotebookIDsAreRejected() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: rootURL) }
    let duplicateNotebookID = UUID()
    let library = LibraryDocument(notebooks: [
      Notebook(
        id: duplicateNotebookID,
        title: "第一本",
        pages: [NotePage(title: "第一页")]
      ),
      Notebook(
        id: duplicateNotebookID,
        title: "第二本",
        pages: [NotePage(title: "第二页")]
      ),
    ])
    let persisted = try writePersistedLibrary(library, rootURL: rootURL)
    let repository = DrawingRepository(rootURL: rootURL)

    await #expect(
      throws: LibraryDocumentStructureError.duplicateNotebookID(duplicateNotebookID)
    ) {
      _ = try await repository.loadLibrary()
    }
    #expect(try Data(contentsOf: persisted.url) == persisted.data)
  }

  @Test("Duplicate page identifiers are rejected without rewriting the library")
  func duplicatePageIDsAreRejected() async throws {
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
    let persisted = try writePersistedLibrary(library, rootURL: rootURL)
    let repository = DrawingRepository(rootURL: rootURL)

    await #expect(throws: LibraryDocumentStructureError.duplicatePageID(duplicatePageID)) {
      _ = try await repository.loadLibrary()
    }
    #expect(try Data(contentsOf: persisted.url) == persisted.data)
  }

  @Test("An invalid library save cannot replace valid persisted bytes")
  func invalidSaveDoesNotReplaceValidLibrary() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: rootURL) }
    let repository = DrawingRepository(rootURL: rootURL)
    let validLibrary = LibraryDocument.starter()
    try await repository.saveLibrary(validLibrary)
    let libraryURL = rootURL.appendingPathComponent(DrawingRepository.libraryFilename)
    let persistedBytes = try Data(contentsOf: libraryURL)
    let persistedLibrary = try #require(try await repository.loadLibrary())

    let duplicatePageID = UUID()
    let invalidLibrary = LibraryDocument(notebooks: [
      Notebook(
        title: "第一本",
        pages: [NotePage(id: duplicatePageID, title: "第一页")]
      ),
      Notebook(
        title: "第二本",
        pages: [NotePage(id: duplicatePageID, title: "第二页")]
      ),
    ])

    await #expect(throws: LibraryDocumentStructureError.duplicatePageID(duplicatePageID)) {
      try await repository.saveLibrary(invalidLibrary)
    }
    #expect(try Data(contentsOf: libraryURL) == persistedBytes)
    #expect(try await repository.loadLibrary() == persistedLibrary)

    let unsupportedLibrary = LibraryDocument(
      schemaVersion: LibraryDocument.currentSchemaVersion + 1,
      notebooks: validLibrary.notebooks
    )
    await #expect(
      throws: DrawingRepositoryError.unsupportedSchema(found: unsupportedLibrary.schemaVersion)
    ) {
      try await repository.saveLibrary(unsupportedLibrary)
    }
    #expect(try Data(contentsOf: libraryURL) == persistedBytes)
    #expect(try await repository.loadLibrary() == persistedLibrary)
  }

  @Test("Restore transactions are immutable sidecars and corrupt data fails closed")
  func restoreTransactionRoundTrip() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let repository = DrawingRepository(rootURL: rootURL)
    let backupID = UUID(uuidString: "E7000000-0000-0000-0000-000000000001")!
    let transaction = BackupRestoreTransaction(
      backupID: backupID,
      archiveChecksum: String(repeating: "0", count: 64),
      importedAt: Date(timeIntervalSince1970: 1_700_020_000),
      copiedNotebooks: LibraryDocument.starter().notebooks
    )
    let transactionURL =
      rootURL
      .appendingPathComponent(
        DrawingRepository.restoreTransactionsDirectoryName,
        isDirectory: true
      )
      .appendingPathComponent(
        "\(backupID.uuidString.lowercased()).\(DrawingRepository.restoreTransactionFileExtension)"
      )

    try await repository.createRestoreTransaction(transaction)

    let loadedTransaction = try #require(
      try await repository.loadRestoreTransaction(backupID: backupID)
    )
    #expect(loadedTransaction.version == transaction.version)
    #expect(loadedTransaction.backupID == transaction.backupID)
    #expect(loadedTransaction.archiveChecksum == transaction.archiveChecksum)
    #expect(
      abs(loadedTransaction.importedAt.timeIntervalSince(transaction.importedAt)) < 0.001
    )
    #expect(loadedTransaction.copiedNotebooks.map(\.id) == transaction.copiedNotebooks.map(\.id))
    #expect(
      loadedTransaction.copiedNotebooks.flatMap(\.pages).map(\.id)
        == transaction.copiedNotebooks.flatMap(\.pages).map(\.id)
    )
    #expect(FileManager.default.fileExists(atPath: transactionURL.path))
    await #expect(throws: DrawingRepositoryError.restoreTransactionAlreadyExists) {
      try await repository.createRestoreTransaction(transaction)
    }

    try Data("not-json".utf8).write(to: transactionURL, options: .atomic)
    await #expect(throws: DrawingRepositoryError.invalidRestoreTransaction) {
      _ = try await repository.loadRestoreTransaction(backupID: backupID)
    }
  }

  @Test("Restore transaction history fails closed at its count limit")
  func restoreTransactionCountIsBounded() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: rootURL) }
    let transactionsURL = rootURL.appendingPathComponent(
      DrawingRepository.restoreTransactionsDirectoryName,
      isDirectory: true
    )
    try fileManager.createDirectory(at: transactionsURL, withIntermediateDirectories: true)
    for index in 0..<DrawingRepository.maximumRestoreTransactionCount {
      let markerURL = transactionsURL.appendingPathComponent("marker-\(index)")
      #expect(fileManager.createFile(atPath: markerURL.path, contents: Data()))
    }

    let repository = DrawingRepository(rootURL: rootURL)
    let transaction = BackupRestoreTransaction(
      backupID: UUID(uuidString: "E7000000-0000-0000-0000-000000000002")!,
      archiveChecksum: String(repeating: "0", count: 64),
      importedAt: Date(timeIntervalSince1970: 1_700_020_100),
      copiedNotebooks: LibraryDocument.starter().notebooks
    )

    await #expect(
      throws: DrawingRepositoryError.tooManyRestoreTransactions(
        maximum: DrawingRepository.maximumRestoreTransactionCount
      )
    ) {
      try await repository.createRestoreTransaction(transaction)
    }
  }

  @Test("A corrupt library is reported and remains untouched")
  func corruptLibraryIsNotOverwritten() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: rootURL) }

    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let libraryURL = rootURL.appendingPathComponent("library.json")
    let original = Data("not-json".utf8)
    try original.write(to: libraryURL)

    let repository = DrawingRepository(rootURL: rootURL)
    do {
      _ = try await repository.loadLibrary()
      Issue.record("Expected corrupt JSON to throw")
    } catch {
      #expect(try Data(contentsOf: libraryURL) == original)
    }
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

  private func fixtureDrawingData() throws -> Data {
    let fixtureURL = try #require(
      Bundle.module.url(
        forResource: "single-stroke-v1",
        withExtension: "pkdrawing",
        subdirectory: "Fixtures/BackupV1"
      )
    )
    return try Data(contentsOf: fixtureURL)
  }

  private func drawingAcrossRegions() throws -> PKDrawing {
    let fixture = try PKDrawing(data: fixtureDrawingData())
    var drawing = fixture.transformed(
      using: CGAffineTransform(translationX: 0, y: 5_000)
    )
    drawing.append(fixture)
    drawing.append(
      fixture.transformed(using: CGAffineTransform(translationX: 0, y: 9_000))
    )
    return drawing
  }

  private func drawingURL(rootURL: URL, pageID: UUID) -> URL {
    rootURL
      .appendingPathComponent(DrawingRepository.drawingsDirectoryName, isDirectory: true)
      .appendingPathComponent(
        "\(pageID.uuidString).\(DrawingRepository.drawingFileExtension)"
      )
  }

  private func segmentBlobURL(rootURL: URL, pageID: UUID, digest: String) -> URL {
    rootURL
      .appendingPathComponent(
        DrawingRepository.segmentedDrawingsDirectoryName,
        isDirectory: true
      )
      .appendingPathComponent(pageID.uuidString.lowercased(), isDirectory: true)
      .appendingPathComponent("\(digest).\(DrawingRepository.segmentBlobFileExtension)")
  }
}

private struct SegmentedWriteEvent: Sendable {
  let stage: DurableFileWriteStage
  let url: URL
}

private final class SegmentedWriteRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedEvents: [SegmentedWriteEvent] = []

  func record(stage: DurableFileWriteStage, url: URL) {
    lock.lock()
    storedEvents.append(SegmentedWriteEvent(stage: stage, url: url))
    lock.unlock()
  }

  func events() -> [SegmentedWriteEvent] {
    lock.lock()
    defer { lock.unlock() }
    return storedEvents
  }

  func clear() {
    lock.lock()
    storedEvents.removeAll()
    lock.unlock()
  }
}

private enum SegmentedSaveInjectedError: Error, Equatable {
  case beforeAuthorityPublication
}

private final class ApplicationSupportUnavailableFileManager: FileManager, @unchecked Sendable {
  private let isolatedTemporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)

  override var temporaryDirectory: URL {
    isolatedTemporaryDirectory
  }

  override func urls(
    for directory: FileManager.SearchPathDirectory,
    in domainMask: FileManager.SearchPathDomainMask
  ) -> [URL] {
    []
  }

  override func url(
    for directory: FileManager.SearchPathDirectory,
    in domain: FileManager.SearchPathDomainMask,
    appropriateFor url: URL?,
    create shouldCreate: Bool
  ) throws -> URL {
    throw CocoaError(.fileNoSuchFile)
  }
}

private final class IsolatedApplicationSupportFileManager: FileManager, @unchecked Sendable {
  let containerURL = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)

  var applicationSupportURL: URL {
    containerURL
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
  }

  override func url(
    for directory: FileManager.SearchPathDirectory,
    in domain: FileManager.SearchPathDomainMask,
    appropriateFor url: URL?,
    create shouldCreate: Bool
  ) throws -> URL {
    guard directory == .applicationSupportDirectory, domain == .userDomainMask else {
      throw CocoaError(.fileNoSuchFile)
    }
    if shouldCreate {
      try FileManager.default.createDirectory(
        at: applicationSupportURL,
        withIntermediateDirectories: true
      )
    }
    return applicationSupportURL
  }
}
