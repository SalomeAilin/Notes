import Foundation

enum DrawingRepositoryError: LocalizedError, Equatable {
  case unsupportedSchema(found: Int)
  case drawingTooLarge(actual: Int, maximum: Int)

  var errorDescription: String? {
    switch self {
    case .unsupportedSchema(let found):
      "笔记数据版本 \(found) 暂不受支持，原文件未被改写。"
    case .drawingTooLarge(_, let maximum):
      "单页笔迹超过 \(maximum) 字节的安全读取上限。"
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

  func loadDrawing(pageID: UUID, maximumByteCount: Int) throws -> Data? {
    let url = drawingURL(for: pageID)
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
    let url = drawingURL(for: pageID)
    guard fileManager.fileExists(atPath: url.path) else { return }
    try fileManager.removeItem(at: url)
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
