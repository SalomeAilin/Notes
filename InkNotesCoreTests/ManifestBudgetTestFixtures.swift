import Foundation

@testable import InkNotesCore

struct ManifestBudgetTestFixture {
  let exact: LibraryDocument
  let oneByteOver: LibraryDocument
  let bulkNotebookID: UUID
  let singletonPageID: UUID?
}

enum ManifestBudgetTestFixtureError: Error {
  case baseAlreadyExceedsLimit
  case insufficientTitleCapacity
  case exactSizeMismatch
  case noOneByteOverflowCapacity
}

func makeManifestBudgetTestFixture(
  includingSingletonNotebook: Bool = false
) throws -> ManifestBudgetTestFixture {
  let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
  let bulkNotebookID = UUID(uuidString: "72000000-0000-0000-0000-000000000001")!
  let singletonPageID =
    includingSingletonNotebook
    ? UUID(uuidString: "71000000-0000-0000-0000-000000000001")!
    : nil
  let bulkPages = (0..<2_000).map { index in
    NotePage(
      id: UUID(
        uuidString: String(
          format: "73000000-0000-0000-0000-%012X",
          index + 1
        )
      )!,
      title: "x",
      createdAt: timestamp,
      updatedAt: timestamp
    )
  }
  let bulkNotebook = Notebook(
    id: bulkNotebookID,
    title: "x",
    pages: bulkPages,
    createdAt: timestamp,
    updatedAt: timestamp
  )
  var notebooks: [Notebook] = []
  if let singletonPageID {
    notebooks.append(
      Notebook(
        id: UUID(uuidString: "70000000-0000-0000-0000-000000000001")!,
        title: "x",
        pages: [
          NotePage(
            id: singletonPageID,
            title: "x",
            createdAt: timestamp,
            updatedAt: timestamp
          )
        ],
        createdAt: timestamp,
        updatedAt: timestamp
      )
    )
  }
  notebooks.append(bulkNotebook)

  var exact = LibraryDocument(notebooks: notebooks)
  let baseByteCount = try BackupArchiveCodec.projectedManifestByteCount(for: exact)
  guard baseByteCount < BackupArchiveLimits.maximumManifestByteCount else {
    throw ManifestBudgetTestFixtureError.baseAlreadyExceedsLimit
  }

  let bulkNotebookIndex = exact.notebooks.count - 1
  var remaining = BackupArchiveLimits.maximumManifestByteCount - baseByteCount
  for pageIndex in exact.notebooks[bulkNotebookIndex].pages.indices where remaining > 0 {
    let additionalByteCount = min(
      remaining,
      BackupArchiveLimits.maximumTitleUTF8ByteCount - 1
    )
    exact.notebooks[bulkNotebookIndex].pages[pageIndex].title += String(
      repeating: "a",
      count: additionalByteCount
    )
    remaining -= additionalByteCount
  }
  guard remaining == 0 else {
    throw ManifestBudgetTestFixtureError.insufficientTitleCapacity
  }
  guard
    try BackupArchiveCodec.projectedManifestByteCount(for: exact)
      == BackupArchiveLimits.maximumManifestByteCount
  else {
    throw ManifestBudgetTestFixtureError.exactSizeMismatch
  }

  var oneByteOver = exact
  guard
    let overflowPageIndex = oneByteOver.notebooks[bulkNotebookIndex].pages.firstIndex(
      where: { $0.title.utf8.count < BackupArchiveLimits.maximumTitleUTF8ByteCount }
    )
  else {
    throw ManifestBudgetTestFixtureError.noOneByteOverflowCapacity
  }
  oneByteOver.notebooks[bulkNotebookIndex].pages[overflowPageIndex].title += "a"
  guard
    try BackupArchiveCodec.projectedManifestByteCount(for: oneByteOver)
      == BackupArchiveLimits.maximumManifestByteCount + 1
  else {
    throw ManifestBudgetTestFixtureError.exactSizeMismatch
  }

  return ManifestBudgetTestFixture(
    exact: exact,
    oneByteOver: oneByteOver,
    bulkNotebookID: bulkNotebookID,
    singletonPageID: singletonPageID
  )
}
