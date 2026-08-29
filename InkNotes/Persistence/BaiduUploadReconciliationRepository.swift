import Darwin
import Foundation

struct BaiduUploadReconciliationRecord: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let attemptID: UUID
  let backupID: UUID
  /// Lowercase SHA-256 of the exact, complete archive `Data` supplied to the uploader.
  /// This is intentionally not the archive format's embedded body checksum.
  let archiveSHA256: String
  let localMD5: String
  let localByteCount: UInt64
  let requestedPath: String

  init(
    attemptID: UUID,
    backupID: UUID,
    archiveSHA256: String,
    localMD5: String,
    localByteCount: UInt64,
    requestedPath: String
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.attemptID = attemptID
    self.backupID = backupID
    self.archiveSHA256 = archiveSHA256
    self.localMD5 = localMD5
    self.localByteCount = localByteCount
    self.requestedPath = requestedPath
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion
    case attemptID
    case backupID
    case archiveSHA256
    case localMD5
    case localByteCount
    case requestedPath
  }

  init(from decoder: Decoder) throws {
    let allKeys = try decoder.container(keyedBy: BaiduUploadReconciliationCodingKey.self)
    let actualKeys = Set(allKeys.allKeys.map(\.stringValue))
    let expectedKeys = Set(CodingKeys.allCases.map(\.rawValue))
    guard actualKeys == expectedKeys else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Unexpected record keys")
      )
    }

    let values = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
    attemptID = try values.decode(UUID.self, forKey: .attemptID)
    backupID = try values.decode(UUID.self, forKey: .backupID)
    archiveSHA256 = try values.decode(String.self, forKey: .archiveSHA256)
    localMD5 = try values.decode(String.self, forKey: .localMD5)
    localByteCount = try values.decode(UInt64.self, forKey: .localByteCount)
    requestedPath = try values.decode(String.self, forKey: .requestedPath)
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(schemaVersion, forKey: .schemaVersion)
    try values.encode(attemptID, forKey: .attemptID)
    try values.encode(backupID, forKey: .backupID)
    try values.encode(archiveSHA256, forKey: .archiveSHA256)
    try values.encode(localMD5, forKey: .localMD5)
    try values.encode(localByteCount, forKey: .localByteCount)
    try values.encode(requestedPath, forKey: .requestedPath)
  }
}

enum BaiduUploadReconciliationAdmission: Equatable, Sendable {
  case created
  case existing
  case identityConflict
}

enum BaiduUploadReconciliationRepositoryError: LocalizedError, Equatable, Sendable {
  case persistenceDirectoryUnavailable
  case invalidStoreLayout
  case invalidRecord
  case unsupportedSchemaVersion(found: Int)
  case recordTooLarge(actual: Int, maximum: Int)
  case tooManyRecords(maximum: Int)
  case identityConflict
  case persistenceFailure

  var errorDescription: String? {
    switch self {
    case .persistenceDirectoryUnavailable:
      "无法访问应用的永久存储目录，已停止百度网盘上传。"
    case .invalidStoreLayout:
      "百度网盘上传对账目录不安全或已损坏，已停止上传。"
    case .invalidRecord:
      "百度网盘上传对账记录无效，已停止上传。"
    case .unsupportedSchemaVersion(let found):
      "百度网盘上传对账记录版本 \(found) 暂不受支持。"
    case .recordTooLarge(_, let maximum):
      "百度网盘上传对账记录超过 \(maximum) 字节的安全上限。"
    case .tooManyRecords(let maximum):
      "百度网盘上传对账记录已达到 \(maximum) 份的安全上限。"
    case .identityConflict:
      "同一备份已有不同的上传对账身份，未覆盖或删除原记录。"
    case .persistenceFailure:
      "无法安全读写百度网盘上传对账记录，已停止上传。"
    }
  }
}

actor BaiduUploadReconciliationRepository {
  static let persistedDirectoryName = "InkNotes"
  static let reconciliationDirectoryName = "UploadReconciliation"
  static let recordFileExtension = "json"
  static let maximumRecordByteCount = 16 * 1024
  static let maximumRecordCount = 1_000
  static let maximumRequestedPathUTF8ByteCount = 512

  private static let directoryPermissions = 0o700
  private static let filePermissions = 0o600
  private static let lockFilename = ".UploadReconciliation.lock"
  private static let processLock = NSLock()

  private let fileManager: FileManager
  private let rootURL: URL?

  init(rootURL: URL, fileManager: FileManager = .default) {
    self.rootURL = rootURL
    self.fileManager = fileManager
  }

  init(fileManager: FileManager = .default) {
    self.rootURL = Self.defaultRootURL(fileManager: fileManager)
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

  func admit(
    _ record: BaiduUploadReconciliationRecord
  ) throws -> BaiduUploadReconciliationAdmission {
    try Self.validate(record)
    let recordURL = try self.recordURL(backupID: record.backupID)
    try prepareRootDirectory()

    return try withExclusiveStoreLock {
      if let existing = try loadRecordIfPresent(
        at: recordURL,
        expectedBackupID: record.backupID
      ) {
        return try admissionForExisting(existing, requested: record, at: recordURL)
      }

      let directoryURL = try prepareReconciliationDirectory()
      let recordCount = try countAndValidateRecordFiles(in: directoryURL)
      guard recordCount < Self.maximumRecordCount else {
        throw BaiduUploadReconciliationRepositoryError.tooManyRecords(
          maximum: Self.maximumRecordCount
        )
      }

      let data = try encode(record)
      guard data.count <= Self.maximumRecordByteCount else {
        throw BaiduUploadReconciliationRepositoryError.recordTooLarge(
          actual: data.count,
          maximum: Self.maximumRecordByteCount
        )
      }

      do {
        try writeNewRecordData(data, to: recordURL)
      } catch BaiduUploadReconciliationWriteError.destinationAlreadyExists {
        guard
          let existing = try loadRecordIfPresent(
            at: recordURL,
            expectedBackupID: record.backupID
          )
        else {
          throw BaiduUploadReconciliationRepositoryError.persistenceFailure
        }
        return try admissionForExisting(existing, requested: record, at: recordURL)
      } catch let error as BaiduUploadReconciliationRepositoryError {
        throw error
      } catch {
        throw BaiduUploadReconciliationRepositoryError.persistenceFailure
      }

      guard
        try loadRecordIfPresent(
          at: recordURL,
          expectedBackupID: record.backupID
        ) == record
      else {
        throw BaiduUploadReconciliationRepositoryError.invalidRecord
      }
      return .created
    }
  }

  func load(backupID: UUID) throws -> BaiduUploadReconciliationRecord? {
    let recordURL = try self.recordURL(backupID: backupID)
    guard try validateRootDirectoryIfPresent() else { return nil }
    return try withExclusiveStoreLock {
      try loadRecordIfPresent(at: recordURL, expectedBackupID: backupID)
    }
  }

  @discardableResult
  func removeOwned(_ record: BaiduUploadReconciliationRecord) throws -> Bool {
    try Self.validate(record)
    let recordURL = try self.recordURL(backupID: record.backupID)
    guard try validateRootDirectoryIfPresent() else { return false }
    return try withExclusiveStoreLock {
      guard
        let existing = try loadRecordIfPresent(
          at: recordURL,
          expectedBackupID: record.backupID
        )
      else {
        return false
      }
      guard existing == record else {
        throw BaiduUploadReconciliationRepositoryError.identityConflict
      }

      do {
        try fileManager.removeItem(at: recordURL)
        return true
      } catch let error as NSError where Self.isMissingFileError(error) {
        return false
      } catch {
        throw BaiduUploadReconciliationRepositoryError.persistenceFailure
      }
    }
  }

  private func requiredRootURL() throws -> URL {
    guard let rootURL else {
      throw BaiduUploadReconciliationRepositoryError.persistenceDirectoryUnavailable
    }
    return rootURL
  }

  private func reconciliationDirectoryURL() throws -> URL {
    try requiredRootURL().appendingPathComponent(
      Self.reconciliationDirectoryName,
      isDirectory: true
    )
  }

  private func recordURL(backupID: UUID) throws -> URL {
    try reconciliationDirectoryURL().appendingPathComponent(
      Self.recordFilename(backupID: backupID),
      isDirectory: false
    )
  }

  private static func recordFilename(backupID: UUID) -> String {
    "\(backupID.uuidString.lowercased()).\(recordFileExtension)"
  }

  private func prepareRootDirectory() throws {
    try createDirectoryIfNeeded(at: requiredRootURL(), requiredPermissions: nil)
  }

  private func validateRootDirectoryIfPresent() throws -> Bool {
    guard let attributes = try attributesIfPresent(at: requiredRootURL()) else { return false }
    try validateDirectoryAttributes(attributes, requiredPermissions: nil)
    return true
  }

  private func withExclusiveStoreLock<T>(_ body: () throws -> T) throws -> T {
    Self.processLock.lock()
    defer { Self.processLock.unlock() }

    let lockURL = try requiredRootURL().appendingPathComponent(
      Self.lockFilename,
      isDirectory: false
    )
    let descriptor = lockURL.path.withCString { path in
      Darwin.open(
        path,
        O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
        mode_t(Self.filePermissions)
      )
    }
    guard descriptor >= 0 else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    defer { Darwin.close(descriptor) }

    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0,
      status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      status.st_mode & mode_t(0o7777) == mode_t(Self.filePermissions)
    else {
      throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
    }
    var lock = flock()
    lock.l_type = Int16(F_WRLCK)
    lock.l_whence = Int16(SEEK_SET)
    while Darwin.fcntl(descriptor, F_SETLKW, &lock) == -1 {
      guard errno == EINTR else {
        throw BaiduUploadReconciliationRepositoryError.persistenceFailure
      }
    }
    defer {
      lock.l_type = Int16(F_UNLCK)
      _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
    }

    guard try validateRootDirectoryIfPresent() else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    return try body()
  }

  private func prepareReconciliationDirectory() throws -> URL {
    let directoryURL = try reconciliationDirectoryURL()
    try createDirectoryIfNeeded(
      at: directoryURL,
      requiredPermissions: Self.directoryPermissions
    )
    return directoryURL
  }

  private func createDirectoryIfNeeded(
    at url: URL,
    requiredPermissions: Int?
  ) throws {
    if let attributes = try attributesIfPresent(at: url) {
      try validateDirectoryAttributes(attributes, requiredPermissions: requiredPermissions)
      return
    }

    do {
      try fileManager.createDirectory(
        at: url,
        withIntermediateDirectories: false,
        attributes: requiredPermissions.map { [.posixPermissions: $0 as Any] }
      )
    } catch {
      if let attributes = try attributesIfPresent(at: url) {
        try validateDirectoryAttributes(attributes, requiredPermissions: requiredPermissions)
        return
      }
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }

    guard let attributes = try attributesIfPresent(at: url) else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    try validateDirectoryAttributes(attributes, requiredPermissions: requiredPermissions)
  }

  private func writeNewRecordData(_ data: Data, to recordURL: URL) throws {
    let temporaryURL = recordURL.deletingLastPathComponent().appendingPathComponent(
      ".\(UUID().uuidString.lowercased()).tmp",
      isDirectory: false
    )
    let descriptor = temporaryURL.path.withCString { path in
      Darwin.open(
        path,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        mode_t(Self.filePermissions)
      )
    }
    guard descriptor >= 0 else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    defer {
      Darwin.close(descriptor)
      temporaryURL.path.withCString { _ = Darwin.unlink($0) }
    }

    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0,
      status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      status.st_mode & mode_t(0o7777) == mode_t(Self.filePermissions)
    else {
      throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
    }

    try data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else {
        throw BaiduUploadReconciliationRepositoryError.persistenceFailure
      }
      var writtenByteCount = 0
      while writtenByteCount < rawBuffer.count {
        let result = Darwin.write(
          descriptor,
          baseAddress.advanced(by: writtenByteCount),
          rawBuffer.count - writtenByteCount
        )
        if result == -1, errno == EINTR { continue }
        guard result > 0 else {
          throw BaiduUploadReconciliationRepositoryError.persistenceFailure
        }
        writtenByteCount += result
      }
    }
    guard Darwin.fsync(descriptor) == 0 else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }

    let renameResult = temporaryURL.path.withCString { temporaryPath in
      recordURL.path.withCString { recordPath in
        Darwin.renamex_np(temporaryPath, recordPath, UInt32(RENAME_EXCL))
      }
    }
    guard renameResult == 0 else {
      if errno == EEXIST {
        throw BaiduUploadReconciliationWriteError.destinationAlreadyExists
      }
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }

    try synchronizeDirectory(at: recordURL.deletingLastPathComponent())
  }

  private func admissionForExisting(
    _ existing: BaiduUploadReconciliationRecord,
    requested: BaiduUploadReconciliationRecord,
    at recordURL: URL
  ) throws -> BaiduUploadReconciliationAdmission {
    guard Self.hasSameUploadIdentity(existing, requested) else {
      return .identityConflict
    }
    try synchronizeExistingRecord(at: recordURL)
    return .existing
  }

  private func synchronizeExistingRecord(at recordURL: URL) throws {
    let descriptor = recordURL.path.withCString { path in
      Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    defer { Darwin.close(descriptor) }

    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0,
      status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      status.st_mode & mode_t(0o7777) == mode_t(Self.filePermissions)
    else {
      throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
    }
    guard Darwin.fsync(descriptor) == 0 else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    try synchronizeDirectory(at: recordURL.deletingLastPathComponent())
  }

  private func synchronizeDirectory(at directoryURL: URL) throws {
    let directoryDescriptor = directoryURL.path.withCString { path in
      Darwin.open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
    }
    guard directoryDescriptor >= 0 else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    defer { Darwin.close(directoryDescriptor) }
    guard Darwin.fsync(directoryDescriptor) == 0 else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
  }

  private func loadRecordIfPresent(
    at recordURL: URL,
    expectedBackupID: UUID
  ) throws -> BaiduUploadReconciliationRecord? {
    let rootURL = try requiredRootURL()
    guard let rootAttributes = try attributesIfPresent(at: rootURL) else { return nil }
    try validateDirectoryAttributes(rootAttributes, requiredPermissions: nil)

    let directoryURL = try reconciliationDirectoryURL()
    guard let directoryAttributes = try attributesIfPresent(at: directoryURL) else { return nil }
    try validateDirectoryAttributes(
      directoryAttributes,
      requiredPermissions: Self.directoryPermissions
    )

    guard try attributesIfPresent(at: recordURL) != nil else { return nil }
    try validateFile(at: recordURL)
    let data = try readRecordData(at: recordURL)
    let record = try decode(data)
    try Self.validate(record)
    guard record.backupID == expectedBackupID,
      recordURL.lastPathComponent == Self.recordFilename(backupID: record.backupID)
    else {
      throw BaiduUploadReconciliationRepositoryError.invalidRecord
    }
    return record
  }

  private func countAndValidateRecordFiles(in directoryURL: URL) throws -> Int {
    let entries: [URL]
    do {
      entries = try fileManager.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: nil,
        options: []
      )
    } catch {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }

    guard entries.count <= Self.maximumRecordCount else {
      throw BaiduUploadReconciliationRepositoryError.tooManyRecords(
        maximum: Self.maximumRecordCount
      )
    }
    for entry in entries {
      guard entry.pathExtension == Self.recordFileExtension,
        let backupID = UUID(uuidString: entry.deletingPathExtension().lastPathComponent),
        entry.lastPathComponent == Self.recordFilename(backupID: backupID)
      else {
        throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
      }
      try validateFile(at: entry)
    }
    return entries.count
  }

  private func validateFile(at url: URL) throws {
    guard let attributes = try attributesIfPresent(at: url),
      attributes[.type] as? FileAttributeType == .typeRegular,
      Self.permissions(from: attributes) == Self.filePermissions
    else {
      throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
    }
  }

  private func validateDirectoryAttributes(
    _ attributes: [FileAttributeKey: Any],
    requiredPermissions: Int?
  ) throws {
    guard attributes[.type] as? FileAttributeType == .typeDirectory else {
      throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
    }
    if let requiredPermissions,
      Self.permissions(from: attributes) != requiredPermissions
    {
      throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
    }
  }

  private func attributesIfPresent(at url: URL) throws -> [FileAttributeKey: Any]? {
    do {
      return try fileManager.attributesOfItem(atPath: url.path)
    } catch let error as NSError where Self.isMissingFileError(error) {
      return nil
    } catch {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
  }

  private func readRecordData(at url: URL) throws -> Data {
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try fileManager.attributesOfItem(atPath: url.path)
    } catch {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    if let size = (attributes[.size] as? NSNumber)?.uint64Value,
      size > UInt64(Self.maximumRecordByteCount)
    {
      throw BaiduUploadReconciliationRepositoryError.recordTooLarge(
        actual: size > UInt64(Int.max) ? Int.max : Int(size),
        maximum: Self.maximumRecordByteCount
      )
    }

    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    defer { try? handle.close() }

    var data = Data()
    data.reserveCapacity(
      min((attributes[.size] as? NSNumber)?.intValue ?? 0, Self.maximumRecordByteCount)
    )
    while true {
      let remainingByteCount = Self.maximumRecordByteCount - data.count
      let requestedByteCount = min(4 * 1024, remainingByteCount + 1)
      let chunk: Data
      do {
        chunk = try handle.read(upToCount: requestedByteCount) ?? Data()
      } catch {
        throw BaiduUploadReconciliationRepositoryError.persistenceFailure
      }
      guard !chunk.isEmpty else { break }

      let (nextByteCount, overflow) = data.count.addingReportingOverflow(chunk.count)
      guard !overflow, nextByteCount <= Self.maximumRecordByteCount else {
        throw BaiduUploadReconciliationRepositoryError.recordTooLarge(
          actual: overflow ? Int.max : nextByteCount,
          maximum: Self.maximumRecordByteCount
        )
      }
      data.append(chunk)
    }
    return data
  }

  private func encode(_ record: BaiduUploadReconciliationRecord) throws -> Data {
    do {
      return try Self.makeEncoder().encode(record)
    } catch {
      throw BaiduUploadReconciliationRepositoryError.invalidRecord
    }
  }

  private func decode(_ data: Data) throws -> BaiduUploadReconciliationRecord {
    do {
      return try Self.makeDecoder().decode(BaiduUploadReconciliationRecord.self, from: data)
    } catch {
      throw BaiduUploadReconciliationRepositoryError.invalidRecord
    }
  }

  private static func validate(_ record: BaiduUploadReconciliationRecord) throws {
    guard record.schemaVersion == currentRecordSchemaVersion else {
      throw BaiduUploadReconciliationRepositoryError.unsupportedSchemaVersion(
        found: record.schemaVersion
      )
    }
    guard isLowercaseHex(record.archiveSHA256, byteCount: 64),
      isLowercaseHex(record.localMD5, byteCount: 32),
      record.localByteCount >= UInt64(BackupArchiveCodec.headerByteCount),
      record.localByteCount <= UInt64(BackupArchiveLimits.maximumArchiveByteCount),
      record.requestedPath.utf8.count <= maximumRequestedPathUTF8ByteCount,
      isCanonicalRequestedPath(record.requestedPath, backupID: record.backupID)
    else {
      throw BaiduUploadReconciliationRepositoryError.invalidRecord
    }
  }

  private static var currentRecordSchemaVersion: Int {
    BaiduUploadReconciliationRecord.currentSchemaVersion
  }

  private static func isLowercaseHex(_ value: String, byteCount: Int) -> Bool {
    value.utf8.count == byteCount
      && value.unicodeScalars.allSatisfy {
        (48...57).contains($0.value) || (97...102).contains($0.value)
      }
  }

  private static func isCanonicalRequestedPath(_ path: String, backupID: UUID) -> Bool {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 4,
      components[0].isEmpty,
      components[1] == "apps",
      let directory = try? BaiduNetdiskAppDirectory(folderName: String(components[2]))
    else {
      return false
    }
    return directory.backupPath(backupID: backupID) == path
  }

  private static func hasSameUploadIdentity(
    _ lhs: BaiduUploadReconciliationRecord,
    _ rhs: BaiduUploadReconciliationRecord
  ) -> Bool {
    lhs.backupID == rhs.backupID
      && lhs.archiveSHA256 == rhs.archiveSHA256
      && lhs.localMD5 == rhs.localMD5
      && lhs.localByteCount == rhs.localByteCount
      && lhs.requestedPath == rhs.requestedPath
  }

  private static func permissions(from attributes: [FileAttributeKey: Any]) -> Int? {
    (attributes[.posixPermissions] as? NSNumber)?.intValue
  }

  private static func isMissingFileError(_ error: NSError) -> Bool {
    (error.domain == NSCocoaErrorDomain
      && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError))
      || (error.domain == NSPOSIXErrorDomain && error.code == 2)
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  private static func makeDecoder() -> JSONDecoder {
    JSONDecoder()
  }
}

private struct BaiduUploadReconciliationCodingKey: CodingKey, Hashable {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    self.intValue = nil
  }

  init?(intValue: Int) {
    self.stringValue = String(intValue)
    self.intValue = intValue
  }
}

private enum BaiduUploadReconciliationWriteError: Error {
  case destinationAlreadyExists
}
