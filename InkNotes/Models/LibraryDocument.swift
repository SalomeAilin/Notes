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

enum PageSourceLimits {
  static let maximumSourceCountPerPage = 100
  static let maximumTitleUTF8ByteCount = 1024
  static let maximumExcerptUTF8ByteCount = 16 * 1024
  static let maximumURLUTF8ByteCount = 2048
  static let maximumDocumentByteCount = 2 * 1024 * 1024
}

enum PageSourceError: LocalizedError, Equatable, Sendable {
  case invalidDocument
  case invalidURL
  case emptySelection
  case titleTooLong
  case excerptTooLong
  case tooManySources
  case duplicateSourceID(UUID)

  var errorDescription: String? {
    switch self {
    case .invalidDocument:
      "这页的来源记录无法确认。为保护原内容，已停止读取。"
    case .invalidURL:
      "只能保存安全网页的来源链接。"
    case .emptySelection:
      "请先在网页中选中需要保存的文字。"
    case .titleTooLong:
      "网页标题太长，暂时无法保存这条摘录。"
    case .excerptTooLong:
      "选中的文字太多，请缩小选择范围后再试。"
    case .tooManySources:
      "这页保存的来源较多，请先整理后再添加。"
    case .duplicateSourceID:
      "这页包含重复的来源记录。为保护原内容，已停止读取。"
    }
  }
}

struct PageSourceExcerpt: Identifiable, Codable, Equatable, Sendable {
  let id: UUID
  let title: String
  let excerpt: String
  let sourceURL: URL
  let capturedAt: Date

  init(
    id: UUID = UUID(),
    title: String,
    excerpt: String,
    sourceURL: URL,
    capturedAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.excerpt = excerpt
    self.sourceURL = sourceURL
    self.capturedAt = capturedAt
  }

  func validated() throws -> PageSourceExcerpt {
    let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanedExcerpt = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanedExcerpt.isEmpty else {
      throw PageSourceError.emptySelection
    }
    guard !cleanedTitle.isEmpty,
      cleanedTitle.utf8.count <= PageSourceLimits.maximumTitleUTF8ByteCount
    else {
      throw PageSourceError.titleTooLong
    }
    guard cleanedExcerpt.utf8.count <= PageSourceLimits.maximumExcerptUTF8ByteCount else {
      throw PageSourceError.excerptTooLong
    }
    guard
      let components = URLComponents(
        url: sourceURL,
        resolvingAgainstBaseURL: false
      ),
      components.scheme?.lowercased() == "https",
      components.host?.isEmpty == false,
      components.user == nil,
      components.password == nil,
      sourceURL.absoluteString.utf8.count <= PageSourceLimits.maximumURLUTF8ByteCount
    else {
      throw PageSourceError.invalidURL
    }
    guard capturedAt.timeIntervalSince1970.isFinite else {
      throw PageSourceError.invalidDocument
    }
    return PageSourceExcerpt(
      id: id,
      title: cleanedTitle,
      excerpt: cleanedExcerpt,
      sourceURL: sourceURL,
      capturedAt: capturedAt
    )
  }
}

struct PageSourceDocument: Codable, Equatable, Sendable {
  static let currentVersion = 1

  let version: Int
  let pageID: UUID
  let sources: [PageSourceExcerpt]

  init(
    version: Int = PageSourceDocument.currentVersion,
    pageID: UUID,
    sources: [PageSourceExcerpt]
  ) {
    self.version = version
    self.pageID = pageID
    self.sources = sources
  }

  func validated(expectedPageID: UUID) throws -> PageSourceDocument {
    guard version == Self.currentVersion,
      pageID == expectedPageID,
      sources.count <= PageSourceLimits.maximumSourceCountPerPage
    else {
      throw sources.count > PageSourceLimits.maximumSourceCountPerPage
        ? PageSourceError.tooManySources
        : PageSourceError.invalidDocument
    }
    var sourceIDs = Set<UUID>()
    var validatedSources: [PageSourceExcerpt] = []
    validatedSources.reserveCapacity(sources.count)
    for source in sources {
      guard sourceIDs.insert(source.id).inserted else {
        throw PageSourceError.duplicateSourceID(source.id)
      }
      validatedSources.append(try source.validated())
    }
    return PageSourceDocument(pageID: pageID, sources: validatedSources)
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
