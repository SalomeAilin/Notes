import Foundation

enum DrawingRepositoryError: LocalizedError, Equatable {
  case unsupportedSchema(found: Int)

  var errorDescription: String? {
    switch self {
    case .unsupportedSchema(let found):
      "笔记数据版本 \(found) 暂不受支持，原文件未被改写。"
    }
  }
}

actor DrawingRepository {
  private let fileManager: FileManager
  private let rootURL: URL

  init(
    rootURL: URL = DrawingRepository.defaultRootURL(),
    fileManager: FileManager = .default
  ) {
    self.rootURL = rootURL
    self.fileManager = fileManager
  }

  static func defaultRootURL(fileManager: FileManager = .default) -> URL {
    let applicationSupport =
      fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first ?? fileManager.temporaryDirectory

    return applicationSupport.appendingPathComponent("InkNotes", isDirectory: true)
  }

  func loadLibrary() throws -> LibraryDocument? {
    let url = libraryURL
    guard fileManager.fileExists(atPath: url.path) else { return nil }

    let data = try Data(contentsOf: url)
    let document = try Self.makeDecoder().decode(LibraryDocument.self, from: data)
    guard document.schemaVersion == LibraryDocument.currentSchemaVersion else {
      throw DrawingRepositoryError.unsupportedSchema(found: document.schemaVersion)
    }
    return document
  }

  func saveLibrary(_ document: LibraryDocument) throws {
    try prepareDirectories()
    let data = try Self.makeEncoder().encode(document)
    try data.write(to: libraryURL, options: .atomic)
  }

  func loadDrawing(pageID: UUID) throws -> Data? {
    let url = drawingURL(for: pageID)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    return try Data(contentsOf: url)
  }

  func saveDrawing(_ data: Data, pageID: UUID) throws {
    try prepareDirectories()
    try data.write(to: drawingURL(for: pageID), options: .atomic)
  }

  private var libraryURL: URL {
    rootURL.appendingPathComponent("library.json", isDirectory: false)
  }

  private var drawingsURL: URL {
    rootURL.appendingPathComponent("Drawings", isDirectory: true)
  }

  private func drawingURL(for pageID: UUID) -> URL {
    drawingsURL.appendingPathComponent("\(pageID.uuidString).drawing", isDirectory: false)
  }

  private func prepareDirectories() throws {
    try fileManager.createDirectory(
      at: drawingsURL,
      withIntermediateDirectories: true
    )
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return decoder
  }
}
