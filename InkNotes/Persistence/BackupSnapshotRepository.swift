import Foundation
import PencilKit

struct BackupArchivePreview: Equatable, Sendable {
  let createdAt: Date
  let sourceAppVersion: String
  let sourceBuild: String
  let notebookCount: Int
  let pageCount: Int
}

struct BackupRestoreResult: Equatable, Sendable {
  let library: LibraryDocument
  let selectedNotebookID: UUID
  let selectedPageID: UUID
  let selectedDrawingData: Data
  let importedNotebookCount: Int
  let importedPageCount: Int
}

enum BackupSnapshotError: LocalizedError, Equatable {
  case invalidDrawing

  var errorDescription: String? {
    switch self {
    case .invalidDrawing:
      "备份中包含无法解析的 PencilKit 笔迹，未写入任何导入内容。"
    }
  }
}

extension DrawingRepository {
  func makeBackup(
    library: LibraryDocument,
    drawingOverrides: [UUID: Data],
    sourceAppVersion: String,
    sourceBuild: String,
    createdAt: Date = Date()
  ) throws -> Data {
    let currentPageIDs = Set(library.notebooks.flatMap(\.pages).map(\.id))
    try persistSnapshot(
      library: library,
      pageIDs: currentPageIDs,
      drawingOverrides: drawingOverrides
    )
    let pageIDs = try BackupArchiveCodec.validateLibrary(library)
    let drawings = try loadValidatedDrawings(
      pageIDs: pageIDs,
      drawingOverrides: drawingOverrides
    )
    return try BackupArchiveCodec.encode(
      library: library,
      drawings: drawings,
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
      pageCount: backup.library.notebooks.reduce(0) { $0 + $1.pages.count }
    )
  }

  func restoreBackupAsCopy(
    _ data: Data,
    currentLibrary: LibraryDocument,
    currentDrawingOverrides: [UUID: Data],
    importedAt: Date = Date()
  ) throws -> BackupRestoreResult {
    let persistedPageIDs = Set(currentLibrary.notebooks.flatMap(\.pages).map(\.id))
    // Establish a strict persistence barrier for the user's current library.
    try persistSnapshot(
      library: currentLibrary,
      pageIDs: persistedPageIDs,
      drawingOverrides: currentDrawingOverrides
    )
    let currentPageIDs = try BackupArchiveCodec.validateLibrary(currentLibrary)
    _ = try loadValidatedDrawings(
      pageIDs: currentPageIDs,
      drawingOverrides: currentDrawingOverrides
    )

    // Imported content is still fully decoded and validated before any imported
    // page file is written. The only preceding writes persist the current notes.
    let backup = try decodeAndValidateDrawings(data)

    var existingTitles = Set(currentLibrary.notebooks.map(\.title))
    var usedNotebookIDs = Set(currentLibrary.notebooks.map(\.id))
    var usedPageIDs = currentPageIDs
    var copiedNotebooks: [Notebook] = []
    var copiedDrawings: [UUID: Data] = [:]
    var createdPageIDs: [UUID] = []

    for sourceNotebook in backup.library.notebooks {
      let copiedTitle = uniqueImportedTitle(
        sourceNotebook.title,
        existingTitles: &existingTitles
      )
      var copiedPages: [NotePage] = []

      for sourcePage in sourceNotebook.pages {
        let copiedPageID = makeUniqueID(usedIDs: &usedPageIDs)
        let copiedPage = NotePage(
          id: copiedPageID,
          title: sourcePage.title,
          background: sourcePage.background,
          createdAt: sourcePage.createdAt,
          updatedAt: sourcePage.updatedAt
        )
        copiedPages.append(copiedPage)
        copiedDrawings[copiedPageID] = backup.drawings[sourcePage.id] ?? Data()
        createdPageIDs.append(copiedPageID)
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

    guard let firstNotebook = copiedNotebooks.first,
      let firstPage = firstNotebook.pages.first,
      let firstDrawing = copiedDrawings[firstPage.id]
    else {
      throw BackupArchiveError.invalidLibraryStructure
    }

    var mergedLibrary = currentLibrary
    mergedLibrary.notebooks.append(contentsOf: copiedNotebooks)
    _ = try BackupArchiveCodec.validateLibrary(mergedLibrary)

    do {
      for pageID in createdPageIDs {
        guard let drawing = copiedDrawings[pageID] else {
          throw BackupArchiveError.drawingIndexMismatch
        }
        try saveDrawing(drawing, pageID: pageID)
      }
      // Commit the merged directory last. Until this succeeds, imported files
      // are unreachable orphans and the existing library remains unchanged.
      try saveLibrary(mergedLibrary)
    } catch {
      for pageID in createdPageIDs {
        try? removeDrawingIfPresent(pageID: pageID)
      }
      throw error
    }

    return BackupRestoreResult(
      library: mergedLibrary,
      selectedNotebookID: firstNotebook.id,
      selectedPageID: firstPage.id,
      selectedDrawingData: firstDrawing,
      importedNotebookCount: copiedNotebooks.count,
      importedPageCount: createdPageIDs.count
    )
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
      try saveDrawing(drawing, pageID: pageID)
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
