import Foundation
import PencilKit

struct BackupArchivePreview: Equatable, Sendable {
  let createdAt: Date
  let sourceAppVersion: String
  let sourceBuild: String
  let notebookCount: Int
  let pageCount: Int
  let sourceCount: Int
}

enum BackupRestoreDisposition: Equatable, Sendable {
  case imported
  case alreadyImported
}

struct BackupRestoreResult: Equatable, Sendable {
  let library: LibraryDocument
  let selectedNotebookID: UUID
  let selectedPageID: UUID
  let selectedDrawingData: Data
  let selectedPageSources: [PageSourceExcerpt]
  let importedNotebookCount: Int
  let importedPageCount: Int
  let repairedDrawingCount: Int
  let repairedPageIDs: Set<UUID>
  let repairedSourceCount: Int
  let repairedSourcePageIDs: Set<UUID>
  let disposition: BackupRestoreDisposition
}

enum BackupSnapshotError: LocalizedError, Equatable {
  case invalidDrawing
  case backupIdentityConflict
  case invalidRestoreTransaction
  case partialPreviousImport
  case orphanDrawingConflict
  case orphanSourceConflict

  var errorDescription: String? {
    switch self {
    case .invalidDrawing:
      "备份中有一页无法读取，未导入任何内容。"
    case .backupIdentityConflict:
      "这份备份与此前的导入记录不一致。为避免重复或覆盖，已停止导入。"
    case .invalidRestoreTransaction:
      "无法确认此前的恢复记录。为保护现有笔记，已停止导入。"
    case .partialPreviousImport:
      "这份备份以前只导入了一部分。为避免产生重复内容，已停止导入。"
    case .orphanDrawingConflict:
      "导入位置已有其他内容。为避免覆盖，已停止导入。"
    case .orphanSourceConflict:
      "导入位置已有其他来源记录。为避免覆盖，已停止导入。"
    }
  }
}

private enum BackupRestorePresence {
  case none
  case all
  case partial
}

extension DrawingRepository {
  func makeBackup(
    library: LibraryDocument,
    drawingOverrides: [UUID: Data],
    sourceAppVersion: String,
    sourceBuild: String,
    createdAt: Date = Date()
  ) throws -> Data {
    let pageIDs = try BackupArchiveCodec.validateLibrary(library)
    try validateDrawingOverrides(
      pageIDs: pageIDs,
      drawingOverrides: drawingOverrides
    )
    // Persist valid live overrides before the slower whole-library scan so the
    // latest strokes do not remain only in memory while a backup is prepared.
    try persistSnapshot(
      library: library,
      pageIDs: pageIDs,
      drawingOverrides: drawingOverrides
    )
    let drawings = try loadValidatedDrawings(
      pageIDs: pageIDs,
      drawingOverrides: drawingOverrides
    )
    var pageSources: [UUID: [PageSourceExcerpt]] = [:]
    for pageID in pageIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      let sources = try loadPageSources(pageID: pageID)
      if !sources.isEmpty {
        pageSources[pageID] = sources
      }
    }
    return try BackupArchiveCodec.encodeBestAvailable(
      library: library,
      drawings: drawings,
      pageSources: pageSources,
      createdAt: createdAt,
      sourceAppVersion: sourceAppVersion,
      sourceBuild: sourceBuild
    )
  }

  func inspectBackup(_ data: Data) throws -> BackupArchivePreview {
    let backup = try decodeAndValidateDrawings(data)
    return BackupArchivePreview(
      createdAt: backup.createdAt,
      sourceAppVersion: backup.sourceAppVersion,
      sourceBuild: backup.sourceBuild,
      notebookCount: backup.library.notebooks.count,
      pageCount: backup.library.notebooks.reduce(0) { $0 + $1.pages.count },
      sourceCount: backup.pageSources.values.reduce(0) { $0 + $1.count }
    )
  }

  func restoreBackupAsCopy(
    _ data: Data,
    currentLibrary: LibraryDocument,
    currentDrawingOverrides: [UUID: Data],
    importedAt: Date = Date()
  ) throws -> BackupRestoreResult {
    let currentPageIDs = try BackupArchiveCodec.validateLibrary(currentLibrary)
    try validateDrawingOverrides(
      pageIDs: currentPageIDs,
      drawingOverrides: currentDrawingOverrides
    )
    // Establish the persistence barrier after validating only the bytes that
    // can replace current files, then scan the remaining persisted drawings.
    try persistSnapshot(
      library: currentLibrary,
      pageIDs: currentPageIDs,
      drawingOverrides: currentDrawingOverrides
    )
    let currentDrawings = try loadValidatedDrawings(
      pageIDs: currentPageIDs,
      drawingOverrides: currentDrawingOverrides
    )

    // Imported content is still fully decoded and validated before any imported
    // page file is written. The only preceding writes persist the current notes.
    let backup = try decodeAndValidateDrawings(data)
    let transaction: BackupRestoreTransaction
    let isNewTransaction: Bool
    if let existingTransaction = try loadRestoreTransaction(backupID: backup.backupID) {
      try validateRestoreTransaction(existingTransaction, backup: backup)
      transaction = existingTransaction
      isNewTransaction = false
    } else {
      try Self.validateNewRestoreCapacity(
        currentLibrary: currentLibrary,
        backupLibrary: backup.library
      )
      transaction = try makeRestoreTransaction(
        backup: backup,
        currentLibrary: currentLibrary,
        currentPageIDs: currentPageIDs,
        importedAt: importedAt
      )
      isNewTransaction = true
    }

    let copiedDrawings = try drawingsForRestoreTransaction(transaction, backup: backup)
    let copiedPageSources = try pageSourcesForRestoreTransaction(transaction, backup: backup)
    switch restorePresence(transaction, in: currentLibrary) {
    case .all:
      let repair = try repairMissingDrawingsForCompletedRestore(
        expectedDrawings: copiedDrawings,
        currentDrawings: currentDrawings
      )
      let repairedSourcePageIDs = try repairMissingPageSourcesForCompletedRestore(
        expectedPageSources: copiedPageSources
      )
      return try makeRestoreResult(
        library: currentLibrary,
        transaction: transaction,
        drawings: repair.drawings,
        pageSources: copiedPageSources,
        disposition: .alreadyImported,
        repairedPageIDs: repair.pageIDs,
        repairedSourcePageIDs: repairedSourcePageIDs
      )
    case .partial:
      throw BackupSnapshotError.partialPreviousImport
    case .none:
      break
    }

    var mergedLibrary = currentLibrary
    mergedLibrary.notebooks.append(contentsOf: transaction.copiedNotebooks)
    try BackupArchiveCodec.validateProjectedManifestBudget(mergedLibrary)

    if isNewTransaction {
      // The immutable plan is the write-ahead record and durable receipt. The
      // complete candidate is admitted before this first restore-specific write.
      try createRestoreTransaction(transaction)
    }

    var drawingsToWrite: [(pageID: UUID, data: Data)] = []
    for copiedPageID in copiedDrawings.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
      guard let expectedDrawing = copiedDrawings[copiedPageID] else {
        throw BackupArchiveError.drawingIndexMismatch
      }
      if let existingDrawing = try loadDrawing(
        pageID: copiedPageID,
        maximumByteCount: BackupArchiveLimits.maximumDrawingByteCount
      ) {
        guard existingDrawing == expectedDrawing else {
          throw BackupSnapshotError.orphanDrawingConflict
        }
        try synchronizeDrawingPersistence(pageID: copiedPageID)
      } else {
        drawingsToWrite.append((copiedPageID, expectedDrawing))
      }
    }

    var pageSourcesToWrite: [(pageID: UUID, sources: [PageSourceExcerpt])] = []
    for copiedPageID in copiedPageSources.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
      guard let expectedSources = copiedPageSources[copiedPageID] else {
        throw BackupArchiveError.invalidPageSources
      }
      let existingSources = try loadPageSources(pageID: copiedPageID)
      if existingSources.isEmpty {
        pageSourcesToWrite.append((copiedPageID, expectedSources))
      } else {
        guard existingSources == expectedSources else {
          throw BackupSnapshotError.orphanSourceConflict
        }
        try synchronizePageSourcesPersistence(pageID: copiedPageID)
      }
    }
    for drawing in drawingsToWrite {
      try saveDrawingForEditing(drawing.data, pageID: drawing.pageID)
    }
    for item in pageSourcesToWrite {
      try savePageSources(item.sources, pageID: item.pageID)
    }

    do {
      // Commit the merged directory last. Until this succeeds, imported files
      // are unreachable resumable WAL content and the existing library remains unchanged.
      try saveLibrary(mergedLibrary)
    } catch {
      // Atomic writes can report an uncertain result. A read-back containing
      // every planned ID proves that the visible directory commit succeeded.
      if let persistedLibrary = try? loadLibrary(),
        restorePresence(transaction, in: persistedLibrary) == .all
      {
        try synchronizeLibraryPersistence()
        return try makeRestoreResult(
          library: persistedLibrary,
          transaction: transaction,
          drawings: copiedDrawings,
          pageSources: copiedPageSources,
          disposition: .imported
        )
      }
      throw error
    }

    return try makeRestoreResult(
      library: mergedLibrary,
      transaction: transaction,
      drawings: copiedDrawings,
      pageSources: copiedPageSources,
      disposition: .imported
    )
  }

  static func validateNewRestoreCapacity(
    currentLibrary: LibraryDocument,
    backupLibrary: LibraryDocument
  ) throws {
    let (notebookCount, notebookOverflow) = currentLibrary.notebooks.count
      .addingReportingOverflow(backupLibrary.notebooks.count)
    guard !notebookOverflow, notebookCount <= BackupArchiveLimits.maximumNotebookCount else {
      throw BackupArchiveError.tooManyNotebooks(
        actual: notebookOverflow ? Int.max : notebookCount,
        maximum: BackupArchiveLimits.maximumNotebookCount
      )
    }

    let currentPageCount = restorePageCount(in: currentLibrary)
    let backupPageCount = restorePageCount(in: backupLibrary)
    let (pageCount, pageOverflow) = currentPageCount.addingReportingOverflow(backupPageCount)
    guard !pageOverflow, pageCount <= BackupArchiveLimits.maximumPageCount else {
      throw BackupArchiveError.tooManyPages(
        actual: pageOverflow ? Int.max : pageCount,
        maximum: BackupArchiveLimits.maximumPageCount
      )
    }
  }

  private static func restorePageCount(in library: LibraryDocument) -> Int {
    var pageCount = 0
    for notebook in library.notebooks {
      let (nextPageCount, overflow) = pageCount.addingReportingOverflow(notebook.pages.count)
      if overflow { return Int.max }
      pageCount = nextPageCount
    }
    return pageCount
  }

  private func makeRestoreTransaction(
    backup: ValidatedBackupArchive,
    currentLibrary: LibraryDocument,
    currentPageIDs: Set<UUID>,
    importedAt: Date
  ) throws -> BackupRestoreTransaction {
    guard importedAt.timeIntervalSince1970.isFinite else {
      throw BackupSnapshotError.invalidRestoreTransaction
    }

    var existingTitles = Set(currentLibrary.notebooks.map(\.title))
    var usedNotebookIDs = Set(currentLibrary.notebooks.map(\.id))
    var usedPageIDs = currentPageIDs
    usedNotebookIDs.formUnion(backup.library.notebooks.map(\.id))
    usedPageIDs.formUnion(backup.library.notebooks.flatMap(\.pages).map(\.id))
    var copiedNotebooks: [Notebook] = []
    copiedNotebooks.reserveCapacity(backup.library.notebooks.count)

    for sourceNotebook in backup.library.notebooks {
      let copiedTitle = uniqueImportedTitle(
        sourceNotebook.title,
        existingTitles: &existingTitles
      )
      var copiedPages: [NotePage] = []
      copiedPages.reserveCapacity(sourceNotebook.pages.count)

      for sourcePage in sourceNotebook.pages {
        let copiedPageID = try makeUniquePageID(usedIDs: &usedPageIDs)
        copiedPages.append(
          NotePage(
            id: copiedPageID,
            title: sourcePage.title,
            background: sourcePage.background,
            createdAt: sourcePage.createdAt,
            updatedAt: sourcePage.updatedAt
          )
        )
      }

      copiedNotebooks.append(
        Notebook(
          id: makeUniqueID(usedIDs: &usedNotebookIDs),
          title: copiedTitle,
          pages: copiedPages,
          createdAt: sourceNotebook.createdAt,
          updatedAt: importedAt
        )
      )
    }

    let transaction = BackupRestoreTransaction(
      backupID: backup.backupID,
      archiveChecksum: backup.archiveChecksum,
      importedAt: importedAt,
      copiedNotebooks: copiedNotebooks
    )
    try validateRestoreTransaction(transaction, backup: backup)
    return transaction
  }

  private func validateRestoreTransaction(
    _ transaction: BackupRestoreTransaction,
    backup: ValidatedBackupArchive
  ) throws {
    guard transaction.version == BackupRestoreTransaction.currentVersion,
      transaction.backupID == backup.backupID,
      isValidSHA256Hex(transaction.archiveChecksum),
      transaction.importedAt.timeIntervalSince1970.isFinite
    else {
      throw BackupSnapshotError.invalidRestoreTransaction
    }
    guard transaction.archiveChecksum == backup.archiveChecksum else {
      throw BackupSnapshotError.backupIdentityConflict
    }
    guard transaction.copiedNotebooks.count == backup.library.notebooks.count else {
      throw BackupSnapshotError.invalidRestoreTransaction
    }

    do {
      _ = try BackupArchiveCodec.validateLibrary(
        LibraryDocument(notebooks: transaction.copiedNotebooks)
      )
    } catch {
      throw BackupSnapshotError.invalidRestoreTransaction
    }

    let sourceNotebookIDs = Set(backup.library.notebooks.map(\.id))
    let sourcePageIDs = Set(backup.library.notebooks.flatMap(\.pages).map(\.id))
    let copiedNotebookIDs = Set(transaction.copiedNotebooks.map(\.id))
    let copiedPageIDs = Set(transaction.copiedNotebooks.flatMap(\.pages).map(\.id))
    guard sourceNotebookIDs.isDisjoint(with: copiedNotebookIDs),
      sourcePageIDs.isDisjoint(with: copiedPageIDs)
    else {
      throw BackupSnapshotError.invalidRestoreTransaction
    }

    for (sourceNotebook, copiedNotebook) in zip(
      backup.library.notebooks,
      transaction.copiedNotebooks
    ) {
      guard sourceNotebook.pages.count == copiedNotebook.pages.count,
        datesMatch(sourceNotebook.createdAt, copiedNotebook.createdAt),
        datesMatch(copiedNotebook.updatedAt, transaction.importedAt)
      else {
        throw BackupSnapshotError.invalidRestoreTransaction
      }

      for (sourcePage, copiedPage) in zip(sourceNotebook.pages, copiedNotebook.pages) {
        guard sourcePage.title == copiedPage.title,
          sourcePage.background == copiedPage.background,
          datesMatch(sourcePage.createdAt, copiedPage.createdAt),
          datesMatch(sourcePage.updatedAt, copiedPage.updatedAt)
        else {
          throw BackupSnapshotError.invalidRestoreTransaction
        }
      }
    }
  }

  private func drawingsForRestoreTransaction(
    _ transaction: BackupRestoreTransaction,
    backup: ValidatedBackupArchive
  ) throws -> [UUID: Data] {
    var copiedDrawings: [UUID: Data] = [:]
    for (sourceNotebook, copiedNotebook) in zip(
      backup.library.notebooks,
      transaction.copiedNotebooks
    ) {
      for (sourcePage, copiedPage) in zip(sourceNotebook.pages, copiedNotebook.pages) {
        guard let drawing = backup.drawings[sourcePage.id] else {
          throw BackupArchiveError.drawingIndexMismatch
        }
        copiedDrawings[copiedPage.id] = drawing
      }
    }
    return copiedDrawings
  }

  private func pageSourcesForRestoreTransaction(
    _ transaction: BackupRestoreTransaction,
    backup: ValidatedBackupArchive
  ) throws -> [UUID: [PageSourceExcerpt]] {
    var copiedPageSources: [UUID: [PageSourceExcerpt]] = [:]
    for (sourceNotebook, copiedNotebook) in zip(
      backup.library.notebooks,
      transaction.copiedNotebooks
    ) {
      for (sourcePage, copiedPage) in zip(sourceNotebook.pages, copiedNotebook.pages) {
        guard let sources = backup.pageSources[sourcePage.id] else { continue }
        guard !sources.isEmpty else {
          throw BackupArchiveError.invalidPageSources
        }
        copiedPageSources[copiedPage.id] = sources
      }
    }
    return copiedPageSources
  }

  private func restorePresence(
    _ transaction: BackupRestoreTransaction,
    in library: LibraryDocument
  ) -> BackupRestorePresence {
    let plannedNotebookIDs = Set(transaction.copiedNotebooks.map(\.id))
    let plannedPageIDs = Set(transaction.copiedNotebooks.flatMap(\.pages).map(\.id))
    let currentNotebookIDs = Set(library.notebooks.map(\.id))
    let currentPageIDs = Set(library.notebooks.flatMap(\.pages).map(\.id))
    let allPresent =
      plannedNotebookIDs.isSubset(of: currentNotebookIDs)
      && plannedPageIDs.isSubset(of: currentPageIDs)
    if allPresent { return .all }

    let anyPresent =
      !plannedNotebookIDs.isDisjoint(with: currentNotebookIDs)
      || !plannedPageIDs.isDisjoint(with: currentPageIDs)
    return anyPresent ? .partial : .none
  }

  private func repairMissingDrawingsForCompletedRestore(
    expectedDrawings: [UUID: Data],
    currentDrawings: [UUID: Data]
  ) throws -> (drawings: [UUID: Data], pageIDs: Set<UUID>) {
    var missingDrawings: [(pageID: UUID, data: Data)] = []
    for pageID in expectedDrawings.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
      guard let expectedDrawing = expectedDrawings[pageID] else {
        throw BackupArchiveError.drawingIndexMismatch
      }
      if try !drawingExists(pageID: pageID) {
        missingDrawings.append((pageID, expectedDrawing))
      } else {
        try synchronizeDrawingPersistence(pageID: pageID)
      }
    }

    var reconciledDrawings = currentDrawings
    for drawing in missingDrawings {
      try saveDrawingForEditing(drawing.data, pageID: drawing.pageID)
      reconciledDrawings[drawing.pageID] = drawing.data
    }
    return (reconciledDrawings, Set(missingDrawings.map(\.pageID)))
  }

  private func repairMissingPageSourcesForCompletedRestore(
    expectedPageSources: [UUID: [PageSourceExcerpt]]
  ) throws -> Set<UUID> {
    var repairedPageIDs = Set<UUID>()
    for pageID in expectedPageSources.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
      guard let expectedSources = expectedPageSources[pageID] else {
        throw BackupArchiveError.invalidPageSources
      }
      let existingSources = try loadPageSources(pageID: pageID)
      if existingSources.isEmpty {
        try savePageSources(expectedSources, pageID: pageID)
        repairedPageIDs.insert(pageID)
      } else {
        guard existingSources == expectedSources else {
          throw BackupSnapshotError.orphanSourceConflict
        }
        try synchronizePageSourcesPersistence(pageID: pageID)
      }
    }
    return repairedPageIDs
  }

  private func makeRestoreResult(
    library: LibraryDocument,
    transaction: BackupRestoreTransaction,
    drawings: [UUID: Data],
    pageSources: [UUID: [PageSourceExcerpt]],
    disposition: BackupRestoreDisposition,
    repairedPageIDs: Set<UUID> = [],
    repairedSourcePageIDs: Set<UUID> = []
  ) throws -> BackupRestoreResult {
    guard let firstNotebook = transaction.copiedNotebooks.first,
      let firstPage = firstNotebook.pages.first,
      let firstDrawing = drawings[firstPage.id]
    else {
      throw BackupSnapshotError.invalidRestoreTransaction
    }

    return BackupRestoreResult(
      library: library,
      selectedNotebookID: firstNotebook.id,
      selectedPageID: firstPage.id,
      selectedDrawingData: firstDrawing,
      selectedPageSources: pageSources[firstPage.id] ?? [],
      importedNotebookCount: transaction.copiedNotebooks.count,
      importedPageCount: transaction.copiedNotebooks.reduce(0) { $0 + $1.pages.count },
      repairedDrawingCount: repairedPageIDs.count,
      repairedPageIDs: repairedPageIDs,
      repairedSourceCount: repairedSourcePageIDs.count,
      repairedSourcePageIDs: repairedSourcePageIDs,
      disposition: disposition
    )
  }

  private func makeUniquePageID(usedIDs: inout Set<UUID>) throws -> UUID {
    while true {
      let candidate = UUID()
      guard !usedIDs.contains(candidate),
        try !drawingExists(pageID: candidate),
        try !pageSourcesExist(pageID: candidate)
      else {
        continue
      }
      usedIDs.insert(candidate)
      return candidate
    }
  }

  private func isValidSHA256Hex(_ string: String) -> Bool {
    let bytes = string.utf8
    return bytes.count == 64
      && bytes.allSatisfy {
        ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
      }
  }

  private func datesMatch(_ lhs: Date, _ rhs: Date) -> Bool {
    abs(lhs.timeIntervalSince(rhs)) < 0.001
  }

  private func loadValidatedDrawings(
    pageIDs: Set<UUID>,
    drawingOverrides: [UUID: Data]
  ) throws -> [UUID: Data] {
    var drawings: [UUID: Data] = [:]
    drawings.reserveCapacity(pageIDs.count)
    var totalByteCount = 0

    for pageID in pageIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      let data: Data
      if let drawingOverride = drawingOverrides[pageID] {
        data = drawingOverride
      } else {
        do {
          let storedDrawing = try loadDrawing(
            pageID: pageID,
            maximumByteCount: BackupArchiveLimits.maximumDrawingByteCount
          )
          data = storedDrawing ?? Data()
        } catch DrawingRepositoryError.drawingTooLarge(let actual, let maximum) {
          throw BackupArchiveError.drawingTooLarge(
            pageID: pageID,
            actual: UInt64(actual),
            maximum: maximum
          )
        }
      }
      guard data.count <= BackupArchiveLimits.maximumDrawingByteCount else {
        throw BackupArchiveError.drawingTooLarge(
          pageID: pageID,
          actual: UInt64(data.count),
          maximum: BackupArchiveLimits.maximumDrawingByteCount
        )
      }
      let (nextTotalByteCount, overflow) = totalByteCount.addingReportingOverflow(data.count)
      guard !overflow,
        nextTotalByteCount <= BackupArchiveLimits.maximumArchiveByteCount
          - BackupArchiveCodec.headerByteCount
      else {
        throw BackupArchiveError.archiveTooLarge(
          actual: overflow ? Int.max : nextTotalByteCount,
          maximum: BackupArchiveLimits.maximumArchiveByteCount
        )
      }
      try Self.validatePencilKitDrawing(data)
      drawings[pageID] = data
      totalByteCount = nextTotalByteCount
    }
    return drawings
  }

  private func validateDrawingOverrides(
    pageIDs: Set<UUID>,
    drawingOverrides: [UUID: Data]
  ) throws {
    for pageID in pageIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      guard let data = drawingOverrides[pageID] else { continue }
      guard data.count <= BackupArchiveLimits.maximumDrawingByteCount else {
        throw BackupArchiveError.drawingTooLarge(
          pageID: pageID,
          actual: UInt64(data.count),
          maximum: BackupArchiveLimits.maximumDrawingByteCount
        )
      }
      try Self.validatePencilKitDrawing(data)
    }
  }

  private func persistSnapshot(
    library: LibraryDocument,
    pageIDs: Set<UUID>,
    drawingOverrides: [UUID: Data]
  ) throws {
    for pageID in pageIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      guard let drawing = drawingOverrides[pageID] else { continue }
      // Overrides originate from the live PencilKit canvas. Persist them before
      // the slower whole-library validation so a backup operation cannot widen
      // the durability window for the user's latest strokes.
      try saveDrawingForEditing(drawing, pageID: pageID)
    }
    try saveLibrary(library)
  }

  private func decodeAndValidateDrawings(_ data: Data) throws -> ValidatedBackupArchive {
    let backup = try BackupArchiveCodec.decode(data)
    for pageID in backup.drawings.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
      guard let drawing = backup.drawings[pageID] else {
        throw BackupArchiveError.drawingIndexMismatch
      }
      try Self.validatePencilKitDrawing(drawing)
    }
    return backup
  }

  private static func validatePencilKitDrawing(_ data: Data) throws {
    guard !data.isEmpty else { return }
    do {
      _ = try PKDrawing(data: data)
    } catch {
      throw BackupSnapshotError.invalidDrawing
    }
  }

  private func uniqueImportedTitle(
    _ sourceTitle: String,
    existingTitles: inout Set<String>
  ) -> String {
    let firstCandidate = title(sourceTitle, appending: "（导入）")
    if existingTitles.insert(firstCandidate).inserted {
      return firstCandidate
    }

    var number = 2
    while true {
      let candidate = title(sourceTitle, appending: "（导入 \(number)）")
      if existingTitles.insert(candidate).inserted {
        return candidate
      }
      number += 1
    }
  }

  private func title(_ sourceTitle: String, appending suffix: String) -> String {
    var prefix = sourceTitle
    let maximum = BackupArchiveLimits.maximumTitleUTF8ByteCount
    while prefix.utf8.count + suffix.utf8.count > maximum {
      prefix.removeLast()
    }
    return prefix + suffix
  }

  private func makeUniqueID(usedIDs: inout Set<UUID>) -> UUID {
    while true {
      let candidate = UUID()
      if usedIDs.insert(candidate).inserted {
        return candidate
      }
    }
  }
}
