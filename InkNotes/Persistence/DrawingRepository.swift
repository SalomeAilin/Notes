import Foundation

enum DrawingRepositoryError: LocalizedError, Equatable {
  case persistenceDirectoryUnavailable
  case unsupportedSchema(found: Int)
  case drawingTooLarge(actual: Int, maximum: Int)

  var errorDescription: String? {
    switch self {
    case .persistenceDirectoryUnavailable:
      "无法访问应用的永久存储目录。为避免笔记被写入可能清理的临时目录，当前已停止保存。"
    case .unsupportedSchema(let found):
      "笔记数据版本 \(found) 暂不受支持，原文件未被改写。"
    case .drawingTooLarge(_, let maximum):
      "单页笔迹超过 \(maximum) 字节的安全读取上限。"
    }
  }
}

actor DrawingRepository {
  static let persistedDirectoryName = "InkNotes"
  static let libraryFilename = "library.json"
  static let drawingsDirectoryName = "Drawings"
  static let drawingFileExtension = "drawing"

  private let fileManager: FileManager
  private let rootURL: URL?

  init(
    rootURL: URL,
    fileManager: FileManager = .default
  ) {
    self.rootURL = rootURL
    self.fileManager = fileManager
  }

  init(fileManager: FileManager = .default) {
    self.rootURL = DrawingRepository.defaultRootURL(fileManager: fileManager)
    self.fileManager = fileManager
  }

  static func defaultRootURL(fileManager: FileManager = .default) -> URL? {
    guard
      let applicationSupport = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      return nil
    }

    return applicationSupport.appendingPathComponent(persistedDirectoryName, isDirectory: true)
  }

  func loadLibrary() throws -> LibraryDocument? {
    let url = try libraryURL()
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
    try data.write(to: libraryURL(), options: .atomic)
  }

  func loadDrawing(pageID: UUID) throws -> Data? {
    let url = try drawingURL(for: pageID)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    return try Data(contentsOf: url)
  }

  func loadDrawing(pageID: UUID, maximumByteCount: Int) throws -> Data? {
    let url = try drawingURL(for: pageID)
    guard fileManager.fileExists(atPath: url.path) else { return nil }

    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    if let size = (attributes[.size] as? NSNumber)?.uint64Value,
      size > UInt64(maximumByteCount)
    {
      throw DrawingRepositoryError.drawingTooLarge(
        actual: size > UInt64(Int.max) ? Int.max : Int(size),
        maximum: maximumByteCount
      )
    }

    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var data = Data()
    data.reserveCapacity(min((attributes[.size] as? NSNumber)?.intValue ?? 0, maximumByteCount))

    let chunkByteCount = 1024 * 1024
    while true {
      try Task.checkCancellation()
      let remainingByteCount = maximumByteCount - data.count
      let requestedByteCount = min(chunkByteCount, remainingByteCount + 1)
      let chunk = try handle.read(upToCount: requestedByteCount) ?? Data()
      guard !chunk.isEmpty else { break }

      let (nextByteCount, overflow) = data.count.addingReportingOverflow(chunk.count)
      guard !overflow, nextByteCount <= maximumByteCount else {
        throw DrawingRepositoryError.drawingTooLarge(
          actual: overflow ? Int.max : nextByteCount,
          maximum: maximumByteCount
        )
      }
      data.append(chunk)
    }
    return data
  }

  func saveDrawing(_ data: Data, pageID: UUID) throws {
    try prepareDirectories()
    try data.write(to: drawingURL(for: pageID), options: .atomic)
  }

  func removeDrawingIfPresent(pageID: UUID) throws {
    let url = try drawingURL(for: pageID)
    guard fileManager.fileExists(atPath: url.path) else { return }
    try fileManager.removeItem(at: url)
  }

  private func requiredRootURL() throws -> URL {
    guard let rootURL else {
      throw DrawingRepositoryError.persistenceDirectoryUnavailable
    }
    return rootURL
  }

  private func libraryURL() throws -> URL {
    try requiredRootURL().appendingPathComponent(Self.libraryFilename, isDirectory: false)
  }

  private func drawingsURL() throws -> URL {
    try requiredRootURL().appendingPathComponent(Self.drawingsDirectoryName, isDirectory: true)
  }

  private func drawingURL(for pageID: UUID) throws -> URL {
    try drawingsURL().appendingPathComponent(
      "\(pageID.uuidString).\(Self.drawingFileExtension)",
      isDirectory: false
    )
  }

  private func prepareDirectories() throws {
    try fileManager.createDirectory(
      at: drawingsURL(),
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
