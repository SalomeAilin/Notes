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
