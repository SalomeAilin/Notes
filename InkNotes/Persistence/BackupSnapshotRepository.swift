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
    let pageIDs = try BackupArchiveCodec.validateLibrary(library)
    let drawings = try loadValidatedDrawings(
      pageIDs: pageIDs,
      drawingOverrides: drawingOverrides
    )
    let archive = try BackupArchiveCodec.encode(
      library: library,
      drawings: drawings,
      createdAt: createdAt,
      sourceAppVersion: sourceAppVersion,
      sourceBuild: sourceBuild
    )

    try persistSnapshot(
      library: library,
      pageIDs: pageIDs,
      drawingOverrides: drawingOverrides
    )
    return archive
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
    // Decode and validate the complete incoming archive before the first write.
    let backup = try decodeAndValidateDrawings(data)
    let currentPageIDs = try BackupArchiveCodec.validateLibrary(currentLibrary)
    _ = try loadValidatedDrawings(
      pageIDs: currentPageIDs,
      drawingOverrides: currentDrawingOverrides
    )

    // Establish a strict persistence barrier for the user's current library.
    try persistSnapshot(
      library: currentLibrary,
      pageIDs: currentPageIDs,
      drawingOverrides: currentDrawingOverrides
    )

    var existingTitles = Set(currentLibrary.notebooks.map(\.title))
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
        let copiedPageID = UUID()
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
          id: UUID(),
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

    for pageID in pageIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      let data: Data
      if let drawingOverride = drawingOverrides[pageID] {
        data = drawingOverride
      } else {
        data = try loadDrawing(pageID: pageID) ?? Data()
      }
      try Self.validatePencilKitDrawing(data)
      drawings[pageID] = data
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
      try Self.validatePencilKitDrawing(drawing)
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
}
