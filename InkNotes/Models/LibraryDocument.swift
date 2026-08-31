import Foundation

enum PageBackground: String, Codable, CaseIterable, Identifiable, Sendable {
  case blank
  case ruled
  case grid

  var id: String { rawValue }

  var title: String {
    switch self {
    case .blank: "空白"
    case .ruled: "横线"
    case .grid: "方格"
    }
  }

  var systemImage: String {
    switch self {
    case .blank: "doc"
    case .ruled: "line.3.horizontal"
    case .grid: "grid"
    }
  }
}

struct NotePage: Identifiable, Codable, Equatable, Sendable {
  let id: UUID
  var title: String
  var background: PageBackground
  let createdAt: Date
  var updatedAt: Date

  init(
    id: UUID = UUID(),
    title: String,
    background: PageBackground = .ruled,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.background = background
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

struct Notebook: Identifiable, Codable, Equatable, Sendable {
  let id: UUID
  var title: String
  var pages: [NotePage]
  let createdAt: Date
  var updatedAt: Date

  init(
    id: UUID = UUID(),
    title: String,
    pages: [NotePage] = [],
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.pages = pages
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

struct LibraryDocument: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  var schemaVersion: Int
  var notebooks: [Notebook]

  init(
    schemaVersion: Int = LibraryDocument.currentSchemaVersion,
    notebooks: [Notebook]
  ) {
    self.schemaVersion = schemaVersion
    self.notebooks = notebooks
  }

  static func starter() -> LibraryDocument {
    let page = NotePage(title: "第 1 页")
    let notebook = Notebook(title: "我的笔记本", pages: [page])
    return LibraryDocument(notebooks: [notebook])
  }
}

enum LibraryDocumentStructureError: LocalizedError, Equatable, Sendable {
  case invalidStructure
  case duplicateNotebookID(UUID)
  case duplicatePageID(UUID)
  case invalidDate

  var errorDescription: String? {
    switch self {
    case .invalidStructure:
      "本地笔记内容不完整，原内容没有被改写。"
    case .duplicateNotebookID:
      "本地笔记中出现重复的笔记本，原内容没有被改写。"
    case .duplicatePageID:
      "本地笔记中出现重复的页面，原内容没有被改写。"
    case .invalidDate:
      "本地笔记的时间信息异常，原内容没有被改写。"
    }
  }
}

extension LibraryDocument {
  @discardableResult
  func validatedPageIDs() throws -> Set<UUID> {
    guard !notebooks.isEmpty, notebooks.allSatisfy({ !$0.pages.isEmpty }) else {
      throw LibraryDocumentStructureError.invalidStructure
    }

    var notebookIDs = Set<UUID>()
    var pageIDs = Set<UUID>()
    for notebook in notebooks {
      guard notebookIDs.insert(notebook.id).inserted else {
        throw LibraryDocumentStructureError.duplicateNotebookID(notebook.id)
      }
      try Self.validatePersistedDate(notebook.createdAt)
      try Self.validatePersistedDate(notebook.updatedAt)

      for page in notebook.pages {
        guard pageIDs.insert(page.id).inserted else {
          throw LibraryDocumentStructureError.duplicatePageID(page.id)
        }
        try Self.validatePersistedDate(page.createdAt)
        try Self.validatePersistedDate(page.updatedAt)
      }
    }
    return pageIDs
  }

  private static func validatePersistedDate(_ date: Date) throws {
    guard date.timeIntervalSince1970.isFinite else {
      throw LibraryDocumentStructureError.invalidDate
    }
  }
}
