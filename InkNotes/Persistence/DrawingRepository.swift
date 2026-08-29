import Foundation

enum DrawingRepositoryError: LocalizedError, Equatable {
  case persistenceDirectoryUnavailable
  case unsupportedSchema(found: Int)
  case drawingTooLarge(actual: Int, maximum: Int)
  case restoreTransactionTooLarge(actual: Int, maximum: Int)
  case tooManyRestoreTransactions(maximum: Int)
  case restoreTransactionAlreadyExists
  case invalidRestoreTransaction

  var errorDescription: String? {
    switch self {
    case .persistenceDirectoryUnavailable:
      "无法访问应用的永久存储目录。为避免笔记被写入可能清理的临时目录，当前已停止保存。"
    case .unsupportedSchema(let found):
      "笔记数据版本 \(found) 暂不受支持，原文件未被改写。"
    case .drawingTooLarge(_, let maximum):
      "单页笔迹超过 \(maximum) 字节的安全读取上限。"
    case .restoreTransactionTooLarge(_, let maximum):
      "备份恢复记录超过 \(maximum) 字节的安全读取上限。"
    case .tooManyRestoreTransactions(let maximum):
      "本地备份恢复记录已达到 \(maximum) 份的安全上限。"
    case .restoreTransactionAlreadyExists:
      "这份备份的恢复记录已存在，未覆盖原记录。"
    case .invalidRestoreTransaction:
      "备份恢复记录损坏，已停止导入以保护现有笔记。"
    }
  }
}

actor DrawingRepository {
  static let persistedDirectoryName = "InkNotes"
  static let libraryFilename = "library.json"
  static let drawingsDirectoryName = "Drawings"
  static let drawingFileExtension = "drawing"
  static let restoreTransactionsDirectoryName = "RestoreTransactions"
  static let restoreTransactionFileExtension = "json"
  static let maximumRestoreTransactionByteCount = BackupArchiveLimits.maximumManifestByteCount
  static let maximumRestoreTransactionCount = 1_000

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

  func drawingExists(pageID: UUID) throws -> Bool {
    try fileManager.fileExists(atPath: drawingURL(for: pageID).path)
  }

  func loadRestoreTransaction(backupID: UUID) throws -> BackupRestoreTransaction? {
    let url = try restoreTransactionURL(backupID: backupID)
    guard fileManager.fileExists(atPath: url.path) else { return nil }

    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    if let size = (attributes[.size] as? NSNumber)?.uint64Value,
      size > UInt64(Self.maximumRestoreTransactionByteCount)
    {
      throw DrawingRepositoryError.restoreTransactionTooLarge(
        actual: size > UInt64(Int.max) ? Int.max : Int(size),
        maximum: Self.maximumRestoreTransactionByteCount
      )
    }

    let data = try Data(contentsOf: url)
    guard data.count <= Self.maximumRestoreTransactionByteCount else {
      throw DrawingRepositoryError.restoreTransactionTooLarge(
        actual: data.count,
        maximum: Self.maximumRestoreTransactionByteCount
      )
    }
    do {
      return try Self.makeDecoder().decode(BackupRestoreTransaction.self, from: data)
    } catch {
      throw DrawingRepositoryError.invalidRestoreTransaction
    }
  }

  func createRestoreTransaction(_ transaction: BackupRestoreTransaction) throws {
    let data: Data
    do {
      data = try Self.makeEncoder().encode(transaction)
    } catch {
      throw DrawingRepositoryError.invalidRestoreTransaction
    }
    guard data.count <= Self.maximumRestoreTransactionByteCount else {
      throw DrawingRepositoryError.restoreTransactionTooLarge(
        actual: data.count,
        maximum: Self.maximumRestoreTransactionByteCount
      )
    }

    let directoryURL = try restoreTransactionsURL()
    let transactionURL = try restoreTransactionURL(backupID: transaction.backupID)
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    guard !fileManager.fileExists(atPath: transactionURL.path) else {
      throw DrawingRepositoryError.restoreTransactionAlreadyExists
    }
    let entries = try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil
    )
    guard entries.count < Self.maximumRestoreTransactionCount else {
      throw DrawingRepositoryError.tooManyRestoreTransactions(
        maximum: Self.maximumRestoreTransactionCount
      )
    }
    try data.write(to: transactionURL, options: .atomic)
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

  private func restoreTransactionsURL() throws -> URL {
    try requiredRootURL().appendingPathComponent(
      Self.restoreTransactionsDirectoryName,
      isDirectory: true
    )
  }

  private func restoreTransactionURL(backupID: UUID) throws -> URL {
    try restoreTransactionsURL().appendingPathComponent(
      "\(backupID.uuidString.lowercased()).\(Self.restoreTransactionFileExtension)",
      isDirectory: false
    )
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
