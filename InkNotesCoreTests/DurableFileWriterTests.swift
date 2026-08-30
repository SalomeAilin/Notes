import Dispatch
import Foundation
import Testing

@testable import InkNotesCore

@Suite("Durable local file writer")
struct DurableFileWriterTests {
  @Test("A replacement is file-synced before publish and directory-synced after")
  func replacementOrdering() throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: rootURL) }
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: false)
    let destinationURL = rootURL.appendingPathComponent("library.json")
    try Data("old".utf8).write(to: destinationURL)

    let recorder = DurableWriteProbe()
    let writer = POSIXDurableFileWriter { stage, url in
      try recorder.checkpoint(stage: stage, url: url)
    }
    do {
      try writer.write(Data("new".utf8), to: destinationURL, mode: .replace)
    } catch {
      Issue.record("Durable replacement failed after events \(recorder.snapshot()): \(error)")
      return
    }

    #expect(try Data(contentsOf: destinationURL) == Data("new".utf8))
    #expect(
      recorder.snapshot().map(\.stage) == [
        .temporaryFileCreated,
        .dataWritten,
        .fileSynchronized,
        .published,
        .parentDirectorySynchronized,
      ]
    )
    #expect(
      try fileManager.contentsOfDirectory(atPath: rootURL.path).filter {
        $0 != POSIXDurableFileWriter.lockFilename
      } == ["library.json"]
    )
  }

  @Test("Repository creation durably publishes its root, drawings directory, and library")
  func repositoryDirectoryCreationOrdering() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let recorder = DurableWriteProbe()
    let writer = POSIXDurableFileWriter { stage, url in
      try recorder.checkpoint(stage: stage, url: url)
    }
    let repository = DrawingRepository(
      rootURL: rootURL,
      durableFileWriter: writer
    )
    do {
      try await repository.saveLibrary(LibraryDocument.starter())
    } catch {
      Issue.record("Repository save failed after events \(recorder.snapshot()): \(error)")
      return
    }

    #expect(
      FileManager.default.fileExists(
        atPath: rootURL.appendingPathComponent("library.json").path
      )
    )
    #expect(
      recorder.snapshot().filter { $0.stage == .parentDirectorySynchronized }.map(\.url)
        == [
          rootURL,
          rootURL.appendingPathComponent(
            DrawingRepository.drawingsDirectoryName,
            isDirectory: true
          ),
          rootURL.appendingPathComponent(DrawingRepository.libraryFilename),
        ]
    )
  }

  @Test("A warmed repository does not repeat directory preparation on autosave")
  func warmedRepositoryAvoidsRepeatedPreparation() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let recorder = DurableWriteProbe()
    let writer = POSIXDurableFileWriter { stage, url in
      try recorder.checkpoint(stage: stage, url: url)
    }
    let repository = DrawingRepository(
      rootURL: rootURL,
      durableFileWriter: writer
    )
    let library = LibraryDocument.starter()
    try await repository.saveLibrary(library)
    recorder.clear()

    try await repository.saveLibrary(library)

    #expect(
      recorder.snapshot().map(\.stage) == [
        .temporaryFileCreated,
        .dataWritten,
        .fileSynchronized,
        .published,
        .parentDirectorySynchronized,
      ]
    )
    #expect(
      Set(recorder.snapshot().map(\.url))
        == [rootURL.appendingPathComponent(DrawingRepository.libraryFilename)]
    )
  }

  @Test("Cancelled saves queued behind a slow fsync cannot overwrite newer state")
  func cancelledQueuedSavesStopBeforeSideEffects() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: rootURL) }

    let gate = BlockingDurableWriteGate()
    let writer = POSIXDurableFileWriter { stage, _ in
      try gate.checkpoint(stage: stage)
    }
    let repository = DrawingRepository(rootURL: rootURL, durableFileWriter: writer)
    var firstLibrary = LibraryDocument.starter()
    firstLibrary.notebooks[0].title = "应保留"
    var cancelledLibrary = firstLibrary
    cancelledLibrary.notebooks[0].title = "已取消"
    let pageID = try #require(firstLibrary.notebooks.first?.pages.first?.id)

    let firstSave = Task {
      try await repository.saveLibrary(firstLibrary)
    }
    try #require(gate.waitUntilBlocked())

    let cancelledLibrarySave = Task {
      try await repository.saveLibrary(cancelledLibrary)
    }
    let cancelledDrawingSave = Task {
      try await repository.saveDrawing(Data("stale".utf8), pageID: pageID)
    }
    cancelledLibrarySave.cancel()
    cancelledDrawingSave.cancel()
    gate.release()

    try await firstSave.value
    await #expect(throws: CancellationError.self) {
      try await cancelledLibrarySave.value
    }
    await #expect(throws: CancellationError.self) {
      try await cancelledDrawingSave.value
    }

    let persisted = try #require(try await repository.loadLibrary())
    #expect(persisted.notebooks.first?.title == "应保留")
    #expect(try await repository.loadDrawing(pageID: pageID) == nil)
  }

  @Test("Retry resynchronizes a directory that became visible before an uncertain result")
  func existingDirectoryIsResynchronizedOnRetry() throws {
    let fileManager = FileManager.default
    let parentURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let directoryURL = parentURL.appendingPathComponent("InkNotes", isDirectory: true)
    defer { try? fileManager.removeItem(at: parentURL) }
    try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: false)

    let probe = DurableWriteProbe()
    probe.arm(stage: .parentDirectorySynchronized) { $0 == directoryURL }
    let writer = POSIXDurableFileWriter { stage, url in
      try probe.checkpoint(stage: stage, url: url)
    }

    #expect(throws: InjectedDurabilityError.injected) {
      try writer.createDirectoryIfNeeded(at: directoryURL, fileManager: fileManager)
    }
    #expect(fileManager.fileExists(atPath: directoryURL.path))

    try writer.createDirectoryIfNeeded(at: directoryURL, fileManager: fileManager)
    #expect(
      probe.snapshot().filter {
        $0.stage == .parentDirectorySynchronized && $0.url == directoryURL
      }.count == 2
    )
  }

  @Test("Exclusive creation never replaces existing bytes")
  func exclusiveCreationDoesNotOverwrite() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    let destinationURL = rootURL.appendingPathComponent("receipt.json")
    let original = Data("original".utf8)
    try original.write(to: destinationURL)
    let writer = POSIXDurableFileWriter()

    #expect(throws: DurableFileWriterError.destinationAlreadyExists) {
      try writer.write(Data("replacement".utf8), to: destinationURL, mode: .createExclusive)
    }
    #expect(try Data(contentsOf: destinationURL) == original)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: rootURL.path).filter {
        $0 != POSIXDurableFileWriter.lockFilename
      } == ["receipt.json"]
    )
  }

  @Test("Stale temporary files do not block a new durable write")
  func staleTemporaryFilesDoNotBlockWrite() throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: rootURL) }
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: false)

    let legacyFixedTemporaryURL = rootURL.appendingPathComponent(
      ".(UUID().uuidString.lowercased()).tmp"
    )
    let canonicalStaleTemporaryURL = rootURL.appendingPathComponent(
      ".00000000-0000-0000-0000-000000000000.tmp"
    )
    let unrelatedTemporaryURL = rootURL.appendingPathComponent("export.tmp")
    let staleBytes = Data("stale".utf8)
    try staleBytes.write(to: legacyFixedTemporaryURL)
    try staleBytes.write(to: canonicalStaleTemporaryURL)
    try fileManager.setAttributes(
      [.posixPermissions: POSIXDurableFileWriter.filePermissions],
      ofItemAtPath: legacyFixedTemporaryURL.path
    )
    try fileManager.setAttributes(
      [.posixPermissions: POSIXDurableFileWriter.filePermissions],
      ofItemAtPath: canonicalStaleTemporaryURL.path
    )
    try staleBytes.write(to: unrelatedTemporaryURL)

    let destinationURL = rootURL.appendingPathComponent("library.json")
    let expected = Data("current".utf8)
    try POSIXDurableFileWriter().write(expected, to: destinationURL, mode: .replace)

    #expect(try Data(contentsOf: destinationURL) == expected)
    #expect(!fileManager.fileExists(atPath: legacyFixedTemporaryURL.path))
    #expect(!fileManager.fileExists(atPath: canonicalStaleTemporaryURL.path))
    #expect(try Data(contentsOf: unrelatedTemporaryURL) == staleBytes)
  }

  @Test("Concurrent writes to distinct destinations use independent temporary files")
  func concurrentWritesUseIndependentTemporaryFiles() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: rootURL) }
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: false)

    let writer = POSIXDurableFileWriter()
    let writes = (0..<32).map { index in
      (
        rootURL.appendingPathComponent("page-\(index).drawing"),
        Data("drawing-\(index)".utf8)
      )
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for (destinationURL, payload) in writes {
        group.addTask {
          try writer.write(payload, to: destinationURL, mode: .replace)
        }
      }
      try await group.waitForAll()
    }

    for (destinationURL, payload) in writes {
      #expect(try Data(contentsOf: destinationURL) == payload)
    }
    #expect(
      try fileManager.contentsOfDirectory(atPath: rootURL.path).allSatisfy {
        !$0.hasSuffix(".tmp")
      }
    )
  }

  @Test("Concurrent exclusive admissions enforce the sibling limit atomically")
  func concurrentExclusiveAdmissionsEnforceLimit() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: rootURL) }
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: false)

    let writers = [POSIXDurableFileWriter(), POSIXDurableFileWriter()]
    let outcomes = await withTaskGroup(
      of: ConcurrentAdmissionOutcome.self,
      returning: [ConcurrentAdmissionOutcome].self
    ) { group in
      for index in 0..<2 {
        group.addTask {
          do {
            try writers[index].write(
              Data("receipt-\(index)".utf8),
              to: rootURL.appendingPathComponent("receipt-\(index).json"),
              mode: .createExclusive,
              maximumExistingSiblingCount: 1
            )
            return .admitted
          } catch DurableFileWriterError.siblingFileLimitReached {
            return .limitReached
          } catch {
            return .unexpected(String(describing: error))
          }
        }
      }

      var collected: [ConcurrentAdmissionOutcome] = []
      for await outcome in group {
        collected.append(outcome)
      }
      return collected
    }

    #expect(outcomes.filter { $0 == .admitted }.count == 1)
    #expect(outcomes.filter { $0 == .limitReached }.count == 1)
    #expect(outcomes.count == 2)
    #expect(
      try fileManager.contentsOfDirectory(atPath: rootURL.path).filter {
        $0 != POSIXDurableFileWriter.lockFilename
      }.count == 1
    )
  }

  @Test("Failures before publish preserve the previous file")
  func prePublishFailuresPreservePreviousFile() throws {
    for failureStage in [
      DurableFileWriteStage.temporaryFileCreated,
      .dataWritten,
      .fileSynchronized,
    ] {
      let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      defer { try? FileManager.default.removeItem(at: rootURL) }
      try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
      let destinationURL = rootURL.appendingPathComponent("library.json")
      let original = Data("original".utf8)
      try original.write(to: destinationURL)

      let probe = DurableWriteProbe()
      probe.arm(stage: failureStage) { $0 == destinationURL }
      let writer = POSIXDurableFileWriter { stage, url in
        try probe.checkpoint(stage: stage, url: url)
      }

      #expect(throws: InjectedDurabilityError.injected) {
        try writer.write(Data("replacement".utf8), to: destinationURL, mode: .replace)
      }
      #expect(try Data(contentsOf: destinationURL) == original)
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: rootURL.path).filter {
          $0 != POSIXDurableFileWriter.lockFilename
        } == ["library.json"]
      )
    }
  }

  @Test("A published replacement can be resynchronized after an uncertain result")
  func publishedReplacementCanBeResynchronized() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    let destinationURL = rootURL.appendingPathComponent("library.json")
    let replacement = Data("replacement".utf8)
    try Data("original".utf8).write(to: destinationURL)

    let probe = DurableWriteProbe()
    probe.arm(stage: .published) { $0 == destinationURL }
    let writer = POSIXDurableFileWriter { stage, url in
      try probe.checkpoint(stage: stage, url: url)
    }

    #expect(throws: InjectedDurabilityError.injected) {
      try writer.write(replacement, to: destinationURL, mode: .replace)
    }
    #expect(try Data(contentsOf: destinationURL) == replacement)
    try writer.synchronizeFileAndParentDirectory(at: destinationURL)
    #expect(
      probe.snapshot().suffix(2).map(\.stage) == [
        .fileSynchronized,
        .parentDirectorySynchronized,
      ]
    )
  }

  @Test("Restore durably commits WAL, imported drawing, then the merged library")
  func restoreDurabilityOrdering() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let probe = DurableWriteProbe()
    let writer = POSIXDurableFileWriter { stage, url in
      try probe.checkpoint(stage: stage, url: url)
    }
    let fixture = try await makeRestoreFixture(rootURL: rootURL, writer: writer)
    probe.clear()

    let result = try await fixture.repository.restoreBackupAsCopy(
      fixture.archive,
      currentLibrary: fixture.currentLibrary,
      currentDrawingOverrides: [:],
      importedAt: Date(timeIntervalSince1970: 1_700_040_000)
    )
    #expect(result.disposition == .imported)

    let durableFiles = probe.snapshot().filter {
      $0.stage == .parentDirectorySynchronized
        && ($0.url.pathExtension == DrawingRepository.restoreTransactionFileExtension
          || $0.url.pathExtension == DrawingRepository.drawingFileExtension
          || $0.url.lastPathComponent == DrawingRepository.libraryFilename)
    }
    let walIndex = try #require(
      durableFiles.firstIndex {
        $0.url.deletingLastPathComponent().lastPathComponent
          == DrawingRepository.restoreTransactionsDirectoryName
      }
    )
    let importedDrawingIndex = try #require(
      durableFiles[(walIndex + 1)...].firstIndex {
        $0.url.pathExtension == DrawingRepository.drawingFileExtension
      }
    )
    let mergedLibraryIndex = try #require(
      durableFiles[(importedDrawingIndex + 1)...].firstIndex {
        $0.url.lastPathComponent == DrawingRepository.libraryFilename
      }
    )
    #expect(walIndex < importedDrawingIndex)
    #expect(importedDrawingIndex < mergedLibraryIndex)
  }

  @Test("A published but unsynchronized WAL is reused after restart")
  func publishedWALIsResynchronizedAfterRestart() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let probe = DurableWriteProbe()
    let writer = POSIXDurableFileWriter { stage, url in
      try probe.checkpoint(stage: stage, url: url)
    }
    let fixture = try await makeRestoreFixture(rootURL: rootURL, writer: writer)
    probe.arm(stage: .published) {
      $0.deletingLastPathComponent().lastPathComponent
        == DrawingRepository.restoreTransactionsDirectoryName
    }

    await #expect(throws: InjectedDurabilityError.injected) {
      _ = try await fixture.repository.restoreBackupAsCopy(
        fixture.archive,
        currentLibrary: fixture.currentLibrary,
        currentDrawingOverrides: [:],
        importedAt: Date(timeIntervalSince1970: 1_700_040_100)
      )
    }

    let restartedRepository = DrawingRepository(
      rootURL: rootURL,
      durableFileWriter: POSIXDurableFileWriter { stage, url in
        try probe.checkpoint(stage: stage, url: url)
      }
    )
    probe.clear()
    let result = try await restartedRepository.restoreBackupAsCopy(
      fixture.archive,
      currentLibrary: fixture.currentLibrary,
      currentDrawingOverrides: [:],
      importedAt: Date(timeIntervalSince1970: 1_700_040_200)
    )
    let recoveryEvents = probe.snapshot()
    let transaction = try #require(
      try await restartedRepository.loadRestoreTransaction(backupID: fixture.backupID)
    )

    #expect(result.disposition == .imported)
    #expect(result.selectedNotebookID == transaction.copiedNotebooks.first?.id)
    #expect(result.library.notebooks.count == fixture.currentLibrary.notebooks.count + 1)
    let transactionDirectory = rootURL.appendingPathComponent(
      DrawingRepository.restoreTransactionsDirectoryName,
      isDirectory: true
    )
    let transactionURL = transactionDirectory.appendingPathComponent(
      "\(fixture.backupID.uuidString.lowercased()).\(DrawingRepository.restoreTransactionFileExtension)"
    )
    #expect(
      recoveryEvents.filter { $0.url == transactionURL }.map(\.stage) == [
        .fileSynchronized,
        .parentDirectorySynchronized,
      ]
    )
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: transactionDirectory.path).filter {
        $0 != POSIXDurableFileWriter.lockFilename
      }.count == 1)
  }

  @Test("Two repository instances cannot replace the same immutable WAL")
  func repositoryInstancesCannotReplaceWAL() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let firstRepository = DrawingRepository(rootURL: rootURL)
    let secondRepository = DrawingRepository(rootURL: rootURL)
    let backupID = UUID(uuidString: "F8000000-0000-0000-0000-000000000010")!
    let first = BackupRestoreTransaction(
      backupID: backupID,
      archiveChecksum: String(repeating: "0", count: 64),
      importedAt: Date(timeIntervalSince1970: 1_700_050_000),
      copiedNotebooks: LibraryDocument.starter().notebooks
    )
    let conflicting = BackupRestoreTransaction(
      backupID: backupID,
      archiveChecksum: String(repeating: "1", count: 64),
      importedAt: Date(timeIntervalSince1970: 1_700_050_100),
      copiedNotebooks: LibraryDocument.starter().notebooks
    )

    try await firstRepository.createRestoreTransaction(first)
    let transactionURL =
      rootURL
      .appendingPathComponent(DrawingRepository.restoreTransactionsDirectoryName)
      .appendingPathComponent(
        "\(backupID.uuidString.lowercased()).\(DrawingRepository.restoreTransactionFileExtension)"
      )
    let originalBytes = try Data(contentsOf: transactionURL)

    await #expect(throws: DrawingRepositoryError.restoreTransactionAlreadyExists) {
      try await secondRepository.createRestoreTransaction(conflicting)
    }
    #expect(try Data(contentsOf: transactionURL) == originalBytes)
    let loaded: BackupRestoreTransaction
    do {
      loaded = try #require(
        try await secondRepository.loadRestoreTransaction(backupID: backupID)
      )
    } catch {
      Issue.record("The immutable WAL bytes survived, but repository read-back failed: \(error)")
      return
    }
    #expect(loaded.version == first.version)
    #expect(loaded.backupID == first.backupID)
    #expect(loaded.archiveChecksum == first.archiveChecksum)
    #expect(abs(loaded.importedAt.timeIntervalSince(first.importedAt)) < 0.001)
    #expect(loaded.copiedNotebooks.map(\.id) == first.copiedNotebooks.map(\.id))
    #expect(
      loaded.copiedNotebooks.flatMap(\.pages).map(\.id)
        == first.copiedNotebooks.flatMap(\.pages).map(\.id)
    )
  }

  @Test("An equal orphan drawing is resynchronized before restore resumes")
  func equalOrphanDrawingIsResynchronized() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let probe = DurableWriteProbe()
    let writer = POSIXDurableFileWriter { stage, url in
      try probe.checkpoint(stage: stage, url: url)
    }
    let fixture = try await makeRestoreFixture(rootURL: rootURL, writer: writer)
    probe.clear()
    probe.arm(stage: .temporaryFileCreated, matchingCheckpointCountBeforeFailure: 1) {
      $0.lastPathComponent == DrawingRepository.libraryFilename
    }

    await #expect(throws: InjectedDurabilityError.injected) {
      _ = try await fixture.repository.restoreBackupAsCopy(
        fixture.archive,
        currentLibrary: fixture.currentLibrary,
        currentDrawingOverrides: [:],
        importedAt: Date(timeIntervalSince1970: 1_700_040_400)
      )
    }
    let transaction = try #require(
      try await fixture.repository.loadRestoreTransaction(backupID: fixture.backupID)
    )
    let importedPageID = try #require(transaction.copiedNotebooks.first?.pages.first?.id)
    let importedDrawingURL =
      rootURL
      .appendingPathComponent(DrawingRepository.drawingsDirectoryName, isDirectory: true)
      .appendingPathComponent(
        "\(importedPageID.uuidString).\(DrawingRepository.drawingFileExtension)"
      )

    probe.clear()
    let restartedRepository = DrawingRepository(
      rootURL: rootURL,
      durableFileWriter: POSIXDurableFileWriter { stage, url in
        try probe.checkpoint(stage: stage, url: url)
      }
    )
    let result = try await restartedRepository.restoreBackupAsCopy(
      fixture.archive,
      currentLibrary: fixture.currentLibrary,
      currentDrawingOverrides: [:],
      importedAt: Date(timeIntervalSince1970: 1_700_040_500)
    )

    #expect(result.disposition == .imported)
    #expect(
      probe.snapshot().filter { $0.url == importedDrawingURL }.map(\.stage) == [
        .fileSynchronized,
        .parentDirectorySynchronized,
      ]
    )
  }

  @Test("A completed restore resynchronizes its existing drawing before success")
  func completedRestoreDrawingIsResynchronized() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let probe = DurableWriteProbe()
    let writer = POSIXDurableFileWriter { stage, url in
      try probe.checkpoint(stage: stage, url: url)
    }
    let fixture = try await makeRestoreFixture(rootURL: rootURL, writer: writer)
    let first = try await fixture.repository.restoreBackupAsCopy(
      fixture.archive,
      currentLibrary: fixture.currentLibrary,
      currentDrawingOverrides: [:],
      importedAt: Date(timeIntervalSince1970: 1_700_040_600)
    )
    let editedDrawing = try serializedStrokeDrawing()
    try await fixture.repository.saveDrawing(
      editedDrawing,
      pageID: first.selectedPageID
    )
    let importedDrawingURL =
      rootURL
      .appendingPathComponent(DrawingRepository.drawingsDirectoryName, isDirectory: true)
      .appendingPathComponent(
        "\(first.selectedPageID.uuidString).\(DrawingRepository.drawingFileExtension)"
      )

    probe.clear()
    let restartedRepository = DrawingRepository(
      rootURL: rootURL,
      durableFileWriter: POSIXDurableFileWriter { stage, url in
        try probe.checkpoint(stage: stage, url: url)
      }
    )
    let retry = try await restartedRepository.restoreBackupAsCopy(
      fixture.archive,
      currentLibrary: first.library,
      currentDrawingOverrides: [:],
      importedAt: Date(timeIntervalSince1970: 1_700_040_700)
    )

    #expect(retry.disposition == .alreadyImported)
    #expect(retry.selectedDrawingData == editedDrawing)
    #expect(
      try await restartedRepository.loadDrawing(pageID: first.selectedPageID) == editedDrawing
    )
    #expect(
      probe.snapshot().filter { $0.url == importedDrawingURL }.map(\.stage) == [
        .fileSynchronized,
        .parentDirectorySynchronized,
      ]
    )
  }

  @Test("A visible merged library is resynchronized before restore reports success")
  func visibleMergedLibraryIsResynchronized() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let probe = DurableWriteProbe()
    let writer = POSIXDurableFileWriter { stage, url in
      try probe.checkpoint(stage: stage, url: url)
    }
    let fixture = try await makeRestoreFixture(rootURL: rootURL, writer: writer)
    probe.clear()
    probe.arm(stage: .published, matchingCheckpointCountBeforeFailure: 1) {
      $0.lastPathComponent == DrawingRepository.libraryFilename
    }

    let result = try await fixture.repository.restoreBackupAsCopy(
      fixture.archive,
      currentLibrary: fixture.currentLibrary,
      currentDrawingOverrides: [:],
      importedAt: Date(timeIntervalSince1970: 1_700_040_300)
    )

    #expect(result.disposition == .imported)
    let libraryEvents = probe.snapshot().filter {
      $0.url.lastPathComponent == DrawingRepository.libraryFilename
    }
    let lastPublishedIndex = try #require(
      libraryEvents.lastIndex { $0.stage == .published }
    )
    #expect(
      libraryEvents[(lastPublishedIndex + 1)...].map(\.stage) == [
        .fileSynchronized,
        .parentDirectorySynchronized,
      ]
    )
  }

  private func makeRestoreFixture(
    rootURL: URL,
    writer: any DurableFileWriting
  ) async throws -> RestoreFixture {
    let repository = DrawingRepository(rootURL: rootURL, durableFileWriter: writer)
    let currentLibrary = LibraryDocument.starter()
    let currentPageID = try #require(currentLibrary.notebooks.first?.pages.first?.id)
    try await repository.saveLibrary(currentLibrary)
    try await repository.saveDrawing(Data(), pageID: currentPageID)

    let backupID = UUID(uuidString: "F8000000-0000-0000-0000-000000000001")!
    let notebookID = UUID(uuidString: "F8000000-0000-0000-0000-000000000002")!
    let pageID = UUID(uuidString: "F8000000-0000-0000-0000-000000000003")!
    let createdAt = Date(timeIntervalSince1970: 1_700_030_000)
    let backupLibrary = LibraryDocument(
      notebooks: [
        Notebook(
          id: notebookID,
          title: "耐久恢复样本",
          pages: [
            NotePage(
              id: pageID,
              title: "空白页",
              createdAt: createdAt,
              updatedAt: createdAt
            )
          ],
          createdAt: createdAt,
          updatedAt: createdAt
        )
      ]
    )
    let archive = try BackupArchiveCodec.encode(
      library: backupLibrary,
      drawings: [pageID: Data()],
      createdAt: createdAt,
      backupID: backupID,
      sourceAppVersion: "0.2.0",
      sourceBuild: "2"
    )
    return RestoreFixture(
      repository: repository,
      currentLibrary: currentLibrary,
      archive: archive,
      backupID: backupID
    )
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

private struct RestoreFixture: Sendable {
  let repository: DrawingRepository
  let currentLibrary: LibraryDocument
  let archive: Data
  let backupID: UUID
}

private struct DurableWriteEvent: CustomStringConvertible, Sendable {
  let stage: DurableFileWriteStage
  let url: URL

  var description: String {
    "\(stage):\(url.lastPathComponent)"
  }
}

private enum InjectedDurabilityError: Error, Equatable {
  case injected
}

private enum ConcurrentAdmissionOutcome: Equatable, Sendable {
  case admitted
  case limitReached
  case unexpected(String)
}

private enum BlockingDurableWriteGateError: Error {
  case timedOut
}

private final class BlockingDurableWriteGate: @unchecked Sendable {
  private let lock = NSLock()
  private let blocked = DispatchSemaphore(value: 0)
  private let released = DispatchSemaphore(value: 0)
  private var shouldBlock = true

  func checkpoint(stage: DurableFileWriteStage) throws {
    guard stage == .temporaryFileCreated else { return }
    lock.lock()
    let blockThisCheckpoint = shouldBlock
    shouldBlock = false
    lock.unlock()
    guard blockThisCheckpoint else { return }

    blocked.signal()
    guard released.wait(timeout: .now() + 5) == .success else {
      throw BlockingDurableWriteGateError.timedOut
    }
  }

  func waitUntilBlocked() -> Bool {
    blocked.wait(timeout: .now() + 5) == .success
  }

  func release() {
    released.signal()
  }
}

private final class DurableWriteProbe: @unchecked Sendable {
  private struct Failure {
    let stage: DurableFileWriteStage
    var matchingCheckpointCountBeforeFailure: Int
    let matches: @Sendable (URL) -> Bool
  }

  private let lock = NSLock()
  private var events: [DurableWriteEvent] = []
  private var failure: Failure?

  func arm(
    stage: DurableFileWriteStage,
    matchingCheckpointCountBeforeFailure: Int = 0,
    matches: @escaping @Sendable (URL) -> Bool
  ) {
    lock.lock()
    failure = Failure(
      stage: stage,
      matchingCheckpointCountBeforeFailure: matchingCheckpointCountBeforeFailure,
      matches: matches
    )
    lock.unlock()
  }

  func checkpoint(stage: DurableFileWriteStage, url: URL) throws {
    lock.lock()
    events.append(DurableWriteEvent(stage: stage, url: url))
    var shouldFail = false
    if var failure, failure.stage == stage, failure.matches(url) {
      if failure.matchingCheckpointCountBeforeFailure == 0 {
        self.failure = nil
        shouldFail = true
      } else {
        failure.matchingCheckpointCountBeforeFailure -= 1
        self.failure = failure
      }
    }
    lock.unlock()
    if shouldFail {
      throw InjectedDurabilityError.injected
    }
  }

  func clear() {
    lock.lock()
    events.removeAll()
    failure = nil
    lock.unlock()
  }

  func snapshot() -> [DurableWriteEvent] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }
}
