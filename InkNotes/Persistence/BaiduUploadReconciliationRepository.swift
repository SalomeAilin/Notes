import Darwin
import Foundation

@_silgen_name("flock")
private func inkNotesFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

struct BaiduUploadReconciliationRecord: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 2

  let schemaVersion: Int
  let accountScope: BaiduAccountScope
  let attemptID: UUID
  let backupID: UUID
  /// Lowercase SHA-256 of the exact, complete archive `Data` supplied to the uploader.
  /// This is intentionally not the archive format's embedded body checksum.
  let archiveSHA256: String
  let localMD5: String
  let localByteCount: UInt64
  let requestedPath: String

  init(
    accountScope: BaiduAccountScope,
    attemptID: UUID,
    backupID: UUID,
    archiveSHA256: String,
    localMD5: String,
    localByteCount: UInt64,
    requestedPath: String
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.accountScope = accountScope
    self.attemptID = attemptID
    self.backupID = backupID
    self.archiveSHA256 = archiveSHA256
    self.localMD5 = localMD5
    self.localByteCount = localByteCount
    self.requestedPath = requestedPath
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion
    case accountScope
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
    accountScope = try values.decode(BaiduAccountScope.self, forKey: .accountScope)
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
    try values.encode(accountScope, forKey: .accountScope)
    try values.encode(attemptID, forKey: .attemptID)
    try values.encode(backupID, forKey: .backupID)
    try values.encode(archiveSHA256, forKey: .archiveSHA256)
    try values.encode(localMD5, forKey: .localMD5)
    try values.encode(localByteCount, forKey: .localByteCount)
    try values.encode(requestedPath, forKey: .requestedPath)
  }
}

/// A durable, credential-free receipt proving that the exact pending upload was
/// downloaded and verified byte-for-byte before the pending record was retired.
///
/// The receipt intentionally uses the pending record's canonical filename so a
/// single upload identity can never have both an independently addressable
/// pending record and a verified receipt.
struct BaiduVerifiedRemoteBackupReceipt: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 3
  static let currentVerificationVersion = 1
  static let verifiedRecordType = "verifiedReceipt"

  let schemaVersion: Int
  let recordType: String
  let accountScope: BaiduAccountScope
  let attemptID: UUID
  let backupID: UUID
  let archiveSHA256: String
  let localMD5: String
  let localByteCount: UInt64
  let requestedPath: String
  let remoteFSID: UInt64
  let verifiedByteCount: UInt64
  let verifiedSHA256: String
  let verificationVersion: Int

  fileprivate init(
    record: BaiduUploadReconciliationRecord,
    remoteFSID: UInt64,
    verifiedByteCount: UInt64,
    verifiedSHA256: String
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.recordType = Self.verifiedRecordType
    self.accountScope = record.accountScope
    self.attemptID = record.attemptID
    self.backupID = record.backupID
    self.archiveSHA256 = record.archiveSHA256
    self.localMD5 = record.localMD5
    self.localByteCount = record.localByteCount
    self.requestedPath = record.requestedPath
    self.remoteFSID = remoteFSID
    self.verifiedByteCount = verifiedByteCount
    self.verifiedSHA256 = verifiedSHA256
    self.verificationVersion = Self.currentVerificationVersion
  }

  var record: BaiduUploadReconciliationRecord {
    BaiduUploadReconciliationRecord(
      accountScope: accountScope,
      attemptID: attemptID,
      backupID: backupID,
      archiveSHA256: archiveSHA256,
      localMD5: localMD5,
      localByteCount: localByteCount,
      requestedPath: requestedPath
    )
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion
    case recordType
    case accountScope
    case attemptID
    case backupID
    case archiveSHA256
    case localMD5
    case localByteCount
    case requestedPath
    case remoteFSID
    case verifiedByteCount
    case verifiedSHA256
    case verificationVersion
  }

  init(from decoder: Decoder) throws {
    let allKeys = try decoder.container(keyedBy: BaiduUploadReconciliationCodingKey.self)
    let actualKeys = Set(allKeys.allKeys.map(\.stringValue))
    let expectedKeys = Set(CodingKeys.allCases.map(\.rawValue))
    guard actualKeys == expectedKeys else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Unexpected receipt keys")
      )
    }

    let values = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
    recordType = try values.decode(String.self, forKey: .recordType)
    accountScope = try values.decode(BaiduAccountScope.self, forKey: .accountScope)
    attemptID = try values.decode(UUID.self, forKey: .attemptID)
    backupID = try values.decode(UUID.self, forKey: .backupID)
    archiveSHA256 = try values.decode(String.self, forKey: .archiveSHA256)
    localMD5 = try values.decode(String.self, forKey: .localMD5)
    localByteCount = try values.decode(UInt64.self, forKey: .localByteCount)
    requestedPath = try values.decode(String.self, forKey: .requestedPath)
    remoteFSID = try values.decode(UInt64.self, forKey: .remoteFSID)
    verifiedByteCount = try values.decode(UInt64.self, forKey: .verifiedByteCount)
    verifiedSHA256 = try values.decode(String.self, forKey: .verifiedSHA256)
    verificationVersion = try values.decode(Int.self, forKey: .verificationVersion)
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(schemaVersion, forKey: .schemaVersion)
    try values.encode(recordType, forKey: .recordType)
    try values.encode(accountScope, forKey: .accountScope)
    try values.encode(attemptID, forKey: .attemptID)
    try values.encode(backupID, forKey: .backupID)
    try values.encode(archiveSHA256, forKey: .archiveSHA256)
    try values.encode(localMD5, forKey: .localMD5)
    try values.encode(localByteCount, forKey: .localByteCount)
    try values.encode(requestedPath, forKey: .requestedPath)
    try values.encode(remoteFSID, forKey: .remoteFSID)
    try values.encode(verifiedByteCount, forKey: .verifiedByteCount)
    try values.encode(verifiedSHA256, forKey: .verifiedSHA256)
    try values.encode(verificationVersion, forKey: .verificationVersion)
  }
}

private struct BaiduUploadReconciliationLegacyRecordV1: Codable, Sendable {
  static let schemaVersion = 1

  let schemaVersion: Int
  let attemptID: UUID
  let backupID: UUID
  let archiveSHA256: String
  let localMD5: String
  let localByteCount: UInt64
  let requestedPath: String

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
        .init(codingPath: decoder.codingPath, debugDescription: "Unexpected legacy keys")
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

final class BaiduUploadReconciliationLease: @unchecked Sendable {
  let record: BaiduUploadReconciliationRecord

  fileprivate let issuerID: UUID
  private let stateLock = NSLock()
  private var descriptor: Int32?
  private var released = false

  fileprivate init(
    record: BaiduUploadReconciliationRecord,
    issuerID: UUID,
    descriptor: Int32
  ) {
    self.record = record
    self.issuerID = issuerID
    self.descriptor = descriptor
  }

  #if SWIFT_PACKAGE
    static func testingOnly(
      record: BaiduUploadReconciliationRecord
    ) -> BaiduUploadReconciliationLease {
      BaiduUploadReconciliationLease(
        record: record,
        issuerID: UUID(),
        descriptor: -1
      )
    }
  #endif

  fileprivate func withLiveDescriptor<T>(
    _ body: (Int32) throws -> T
  ) throws -> T {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard !released, let descriptor, descriptor >= 0 else {
      throw BaiduUploadReconciliationRepositoryError.invalidLease
    }
    return try body(descriptor)
  }

  func release() {
    stateLock.lock()
    guard !released else {
      stateLock.unlock()
      return
    }
    released = true
    let descriptor = self.descriptor
    self.descriptor = nil
    stateLock.unlock()

    guard let descriptor, descriptor >= 0 else { return }
    _ = inkNotesFlock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
  }

  deinit {
    release()
  }
}

/// An exclusive claim on a pending record for remote full-content
/// verification. This is deliberately distinct from an upload lease: only a
/// verification lease carries the one-time challenge accepted by
/// `commitVerified`.
final class BaiduUploadReconciliationVerificationLease: @unchecked Sendable {
  let record: BaiduUploadReconciliationRecord
  let verificationChallenge: UUID

  fileprivate let issuerID: UUID
  private let stateLock = NSLock()
  private var descriptor: Int32?
  private var released = false

  fileprivate init(
    record: BaiduUploadReconciliationRecord,
    verificationChallenge: UUID,
    issuerID: UUID,
    descriptor: Int32
  ) {
    self.record = record
    self.verificationChallenge = verificationChallenge
    self.issuerID = issuerID
    self.descriptor = descriptor
  }

  fileprivate func withLiveDescriptor<T>(
    _ body: (Int32) throws -> T
  ) throws -> T {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard !released, let descriptor, descriptor >= 0 else {
      throw BaiduUploadReconciliationRepositoryError.invalidLease
    }
    return try body(descriptor)
  }

  func release() {
    stateLock.lock()
    guard !released else {
      stateLock.unlock()
      return
    }
    released = true
    let descriptor = self.descriptor
    self.descriptor = nil
    stateLock.unlock()

    guard let descriptor, descriptor >= 0 else { return }
    _ = inkNotesFlock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
  }

  deinit {
    release()
  }
}

enum BaiduUploadReconciliationAdmission: Equatable, Sendable {
  case created(BaiduUploadReconciliationLease)
  case inProgress(ownerAttemptID: UUID)
  case existing
  case verified(BaiduVerifiedRemoteBackupReceipt)
  case identityConflict

  static func == (
    lhs: BaiduUploadReconciliationAdmission,
    rhs: BaiduUploadReconciliationAdmission
  ) -> Bool {
    switch (lhs, rhs) {
    case (.created, .created), (.existing, .existing), (.identityConflict, .identityConflict):
      true
    case (.inProgress(let lhsOwner), .inProgress(let rhsOwner)):
      lhsOwner == rhsOwner
    case (.verified(let lhsReceipt), .verified(let rhsReceipt)):
      lhsReceipt == rhsReceipt
    default:
      false
    }
  }

  var isCreated: Bool {
    if case .created = self { return true }
    return false
  }

  var createdLease: BaiduUploadReconciliationLease? {
    if case .created(let lease) = self { return lease }
    return nil
  }
}

enum BaiduUploadReconciliationClaim: Equatable, Sendable {
  case claimed(BaiduUploadReconciliationVerificationLease)
  case inProgress(ownerAttemptID: UUID)
  case verified(BaiduVerifiedRemoteBackupReceipt)
  case missing

  static func == (
    lhs: BaiduUploadReconciliationClaim,
    rhs: BaiduUploadReconciliationClaim
  ) -> Bool {
    switch (lhs, rhs) {
    case (.claimed, .claimed), (.missing, .missing):
      true
    case (.inProgress(let lhsOwner), .inProgress(let rhsOwner)):
      lhsOwner == rhsOwner
    case (.verified(let lhsReceipt), .verified(let rhsReceipt)):
      lhsReceipt == rhsReceipt
    default:
      false
    }
  }

  var claimedLease: BaiduUploadReconciliationVerificationLease? {
    if case .claimed(let lease) = self { return lease }
    return nil
  }
}

protocol BaiduUploadReconciliationStoring: Sendable {
  func admit(
    _ record: BaiduUploadReconciliationRecord
  ) async throws -> BaiduUploadReconciliationAdmission

  @discardableResult
  func removeOwned(_ lease: BaiduUploadReconciliationLease) async throws -> Bool
}

enum BaiduUploadReconciliationRepositoryError: LocalizedError, Equatable, Sendable {
  case persistenceDirectoryUnavailable
  case invalidStoreLayout
  case invalidRecord
  case legacyUnscopedRecordsPresent
  case unsupportedSchemaVersion(found: Int)
  case recordTooLarge(actual: Int, maximum: Int)
  case tooManyRecords(maximum: Int)
  case identityConflict
  case invalidLease
  case invalidProof
  case persistenceFailure

  var errorDescription: String? {
    switch self {
    case .persistenceDirectoryUnavailable:
      "无法访问应用的永久存储目录，已停止百度网盘上传。"
    case .invalidStoreLayout:
      "百度网盘上传对账目录不安全或已损坏，已停止上传。"
    case .invalidRecord:
      "百度网盘上传对账记录无效，已停止上传。"
    case .legacyUnscopedRecordsPresent:
      "检测到未绑定账号的旧版上传记录；完成远端核验前已停止所有百度网盘上传。"
    case .unsupportedSchemaVersion(let found):
      "百度网盘上传对账记录版本 \(found) 暂不受支持。"
    case .recordTooLarge(_, let maximum):
      "百度网盘上传对账记录超过 \(maximum) 字节的安全上限。"
    case .tooManyRecords(let maximum):
      "百度网盘上传对账记录已达到 \(maximum) 份的安全上限。"
    case .identityConflict:
      "同一备份已有不同的上传对账身份，未覆盖或删除原记录。"
    case .invalidLease:
      "百度网盘上传对账租约无效或已释放，未删除记录。"
    case .invalidProof:
      "百度网盘完整性核验证明与待核对记录不匹配，未写入核验回执。"
    case .persistenceFailure:
      "无法安全读写百度网盘上传对账记录，已停止上传。"
    }
  }
}

private enum BaiduUploadReconciliationEntry: Equatable, Sendable {
  case pending(BaiduUploadReconciliationRecord)
  case verified(BaiduVerifiedRemoteBackupReceipt)

  var accountScope: BaiduAccountScope {
    switch self {
    case .pending(let record): record.accountScope
    case .verified(let receipt): receipt.accountScope
    }
  }

  var backupID: UUID {
    switch self {
    case .pending(let record): record.backupID
    case .verified(let receipt): receipt.backupID
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
  // A verified commit briefly has one canonical entry plus one same-directory
  // swap entry. Recovery still rejects more than one temporary entry.
  private static let maximumDirectoryEntryCount = maximumRecordCount + 1
  private static let processLock = NSLock()

  private let fileManager: FileManager
  private let rootURL: URL?
  private let leaseIssuerID = UUID()

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
    let recordURL = try self.recordURL(
      accountScope: record.accountScope,
      backupID: record.backupID
    )
    try prepareRootDirectory()

    return try withExclusiveStoreLock {
      let directoryURL = try prepareReconciliationDirectory()
      let recordCount = try recoverTemporaryFilesAndCountRecords(in: directoryURL)
      if let existing = try loadEntryIfPresent(
        at: recordURL,
        expectedAccountScope: record.accountScope,
        expectedBackupID: record.backupID
      ) {
        return try admissionForExisting(existing, requested: record, at: recordURL)
      }

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
          let existing = try loadEntryIfPresent(
            at: recordURL,
            expectedAccountScope: record.accountScope,
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
        try loadEntryIfPresent(
          at: recordURL,
          expectedAccountScope: record.accountScope,
          expectedBackupID: record.backupID
        ) == .pending(record)
      else {
        throw BaiduUploadReconciliationRepositoryError.invalidRecord
      }
      guard let descriptor = try acquireRecordDescriptor(for: record, at: recordURL) else {
        return .inProgress(ownerAttemptID: record.attemptID)
      }
      return .created(
        BaiduUploadReconciliationLease(
          record: record,
          issuerID: leaseIssuerID,
          descriptor: descriptor
        )
      )
    }
  }

  func load(
    accountScope: BaiduAccountScope,
    backupID: UUID
  ) throws -> BaiduUploadReconciliationRecord? {
    try loadPending(accountScope: accountScope, backupID: backupID)
  }

  func loadPending(
    accountScope: BaiduAccountScope,
    backupID: UUID
  ) throws -> BaiduUploadReconciliationRecord? {
    let recordURL = try self.recordURL(accountScope: accountScope, backupID: backupID)
    guard try validateRootDirectoryIfPresent() else { return nil }
    return try withExclusiveStoreLock {
      guard try inspectExistingReconciliationDirectory() != nil else { return nil }
      let entry = try loadEntryIfPresent(
        at: recordURL,
        expectedAccountScope: accountScope,
        expectedBackupID: backupID
      )
      guard case .pending(let record) = entry else { return nil }
      return record
    }
  }

  func loadVerifiedReceipt(
    accountScope: BaiduAccountScope,
    backupID: UUID
  ) throws -> BaiduVerifiedRemoteBackupReceipt? {
    let recordURL = try self.recordURL(accountScope: accountScope, backupID: backupID)
    guard try validateRootDirectoryIfPresent() else { return nil }
    return try withExclusiveStoreLock {
      guard try inspectExistingReconciliationDirectory() != nil else { return nil }
      let entry = try loadEntryIfPresent(
        at: recordURL,
        expectedAccountScope: accountScope,
        expectedBackupID: backupID
      )
      guard case .verified(let receipt) = entry else { return nil }
      return receipt
    }
  }

  func claimPending(
    accountScope: BaiduAccountScope,
    backupID: UUID
  ) throws -> BaiduUploadReconciliationClaim {
    let recordURL = try self.recordURL(accountScope: accountScope, backupID: backupID)
    guard try validateRootDirectoryIfPresent() else { return .missing }
    return try withExclusiveStoreLock {
      guard try inspectExistingReconciliationDirectory() != nil else { return .missing }
      guard
        let entry = try loadEntryIfPresent(
          at: recordURL,
          expectedAccountScope: accountScope,
          expectedBackupID: backupID
        )
      else {
        return .missing
      }
      switch entry {
      case .verified(let receipt):
        return .verified(receipt)
      case .pending(let record):
        guard let descriptor = try acquireRecordDescriptor(for: record, at: recordURL) else {
          return .inProgress(ownerAttemptID: record.attemptID)
        }
        return .claimed(
          BaiduUploadReconciliationVerificationLease(
            record: record,
            verificationChallenge: UUID(),
            issuerID: leaseIssuerID,
            descriptor: descriptor
          )
        )
      }
    }
  }

  func commitVerified(
    _ lease: BaiduUploadReconciliationVerificationLease,
    proof: BaiduVerifiedRemoteBackupContentProof
  ) throws -> BaiduVerifiedRemoteBackupReceipt {
    guard lease.issuerID == leaseIssuerID else {
      throw BaiduUploadReconciliationRepositoryError.invalidLease
    }
    let record = lease.record
    try Self.validate(record)
    guard proof.verificationChallenge == lease.verificationChallenge,
      proof.record == record,
      proof.fsID > 0,
      proof.byteCount == record.localByteCount,
      proof.sha256 == record.archiveSHA256,
      Self.isLowercaseHex(proof.sha256, byteCount: 64)
    else {
      throw BaiduUploadReconciliationRepositoryError.invalidProof
    }

    let receipt = BaiduVerifiedRemoteBackupReceipt(
      record: record,
      remoteFSID: proof.fsID,
      verifiedByteCount: proof.byteCount,
      verifiedSHA256: proof.sha256
    )
    try Self.validate(receipt)
    let recordURL = try self.recordURL(
      accountScope: record.accountScope,
      backupID: record.backupID
    )
    return try lease.withLiveDescriptor { recordDescriptor in
      guard try validateRootDirectoryIfPresent() else {
        throw BaiduUploadReconciliationRepositoryError.persistenceFailure
      }
      return try withExclusiveStoreLock {
        guard try inspectExistingReconciliationDirectory() != nil else {
          throw BaiduUploadReconciliationRepositoryError.persistenceFailure
        }
        try replacePendingWithVerifiedReceipt(
          receipt,
          expectedPendingRecord: record,
          recordDescriptor: recordDescriptor,
          at: recordURL
        )
        return receipt
      }
    }
  }

  @discardableResult
  func removeOwned(_ lease: BaiduUploadReconciliationLease) throws -> Bool {
    guard lease.issuerID == leaseIssuerID else {
      throw BaiduUploadReconciliationRepositoryError.invalidLease
    }
    let record = lease.record
    try Self.validate(record)
    let recordURL = try self.recordURL(
      accountScope: record.accountScope,
      backupID: record.backupID
    )
    return try lease.withLiveDescriptor { recordDescriptor in
      guard try validateRootDirectoryIfPresent() else { return false }
      return try withExclusiveStoreLock {
        guard
          try inspectExistingReconciliationDirectory(
            removeTemporaryFiles: false
          ) != nil
        else {
          return false
        }
        return try unlinkOwnedRecord(
          record,
          recordDescriptor: recordDescriptor,
          at: recordURL
        )
      }
    }
  }

  private func unlinkOwnedRecord(
    _ record: BaiduUploadReconciliationRecord,
    recordDescriptor: Int32,
    at recordURL: URL
  ) throws -> Bool {
    let directoryURL = recordURL.deletingLastPathComponent()
    let directoryDescriptor = directoryURL.path.withCString { path in
      Darwin.open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
    }
    guard directoryDescriptor >= 0 else {
      let openError = errno
      if openError == ENOENT { return false }
      if openError == ELOOP || openError == ENOTDIR {
        throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
      }
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    defer { Darwin.close(directoryDescriptor) }

    var directoryStatus = stat()
    guard Darwin.fstat(directoryDescriptor, &directoryStatus) == 0 else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    guard directoryStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      directoryStatus.st_mode & mode_t(0o7777) == mode_t(Self.directoryPermissions)
    else {
      throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
    }

    let filename = recordURL.lastPathComponent
    var descriptorStatus = stat()
    guard Darwin.fstat(recordDescriptor, &descriptorStatus) == 0 else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    let data = try readRecordData(from: recordDescriptor, status: descriptorStatus)
    let existing = try decode(data)
    try Self.validate(existing)
    guard existing.accountScope == record.accountScope,
      existing.backupID == record.backupID,
      filename
        == Self.recordFilename(
          accountScope: existing.accountScope,
          backupID: existing.backupID
        )
    else {
      throw BaiduUploadReconciliationRepositoryError.invalidRecord
    }
    guard existing == record else {
      throw BaiduUploadReconciliationRepositoryError.identityConflict
    }

    var pathStatus = stat()
    let statusResult = filename.withCString { name in
      Darwin.fstatat(directoryDescriptor, name, &pathStatus, AT_SYMLINK_NOFOLLOW)
    }
    guard statusResult == 0 else {
      let statusError = errno
      if statusError == ENOENT { return false }
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    guard pathStatus.st_dev == descriptorStatus.st_dev,
      pathStatus.st_ino == descriptorStatus.st_ino,
      pathStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      pathStatus.st_mode & mode_t(0o7777) == mode_t(Self.filePermissions)
    else {
      throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
    }

    let unlinkResult = filename.withCString { name in
      Darwin.unlinkat(directoryDescriptor, name, 0)
    }
    guard unlinkResult == 0 else {
      let unlinkError = errno
      if unlinkError == ENOENT { return false }
      if unlinkError == EISDIR || unlinkError == EPERM {
        throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
      }
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    guard Darwin.fsync(directoryDescriptor) == 0 else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    return true
  }

  private func replacePendingWithVerifiedReceipt(
    _ receipt: BaiduVerifiedRemoteBackupReceipt,
    expectedPendingRecord: BaiduUploadReconciliationRecord,
    recordDescriptor: Int32,
    at recordURL: URL
  ) throws {
    try validateLockedPendingDescriptor(
      recordDescriptor,
      expected: expectedPendingRecord,
      at: recordURL
    )

    let receiptData = try encode(receipt)
    guard receiptData.count <= Self.maximumRecordByteCount else {
      throw BaiduUploadReconciliationRepositoryError.recordTooLarge(
        actual: receiptData.count,
        maximum: Self.maximumRecordByteCount
      )
    }

    let directoryURL = recordURL.deletingLastPathComponent()
    let directoryDescriptor = directoryURL.path.withCString { path in
      Darwin.open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
    }
    guard directoryDescriptor >= 0 else {
      let openError = errno
      if openError == ELOOP || openError == ENOTDIR {
        throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
      }
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    defer { Darwin.close(directoryDescriptor) }
    try validateReconciliationDirectoryDescriptor(directoryDescriptor)

    let canonicalFilename = recordURL.lastPathComponent
    guard
      canonicalFilename
        == Self.recordFilename(
          accountScope: expectedPendingRecord.accountScope,
          backupID: expectedPendingRecord.backupID
        )
    else {
      throw BaiduUploadReconciliationRepositoryError.invalidRecord
    }
    let temporaryFilename = ".\(UUID().uuidString.lowercased()).tmp"
    let temporaryDescriptor = temporaryFilename.withCString { name in
      Darwin.openat(
        directoryDescriptor,
        name,
        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        mode_t(Self.filePermissions)
      )
    }
    guard temporaryDescriptor >= 0 else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }

    var didSwap = false
    var didUnlinkSwappedPending = false
    defer {
      Darwin.close(temporaryDescriptor)
      if !didSwap {
        temporaryFilename.withCString { _ = Darwin.unlinkat(directoryDescriptor, $0, 0) }
      } else if didUnlinkSwappedPending {
        // The expected post-commit state has no temporary path. No cleanup is
        // attempted after an ambiguous swap because that path would contain
        // the original pending inode.
      }
    }

    var receiptDescriptorStatus = stat()
    guard Darwin.fstat(temporaryDescriptor, &receiptDescriptorStatus) == 0,
      receiptDescriptorStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      receiptDescriptorStatus.st_mode & mode_t(0o7777) == mode_t(Self.filePermissions)
    else {
      throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
    }
    try writeAll(receiptData, to: temporaryDescriptor)
    guard Darwin.fsync(temporaryDescriptor) == 0 else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }

    // Revalidate immediately before the exchange. The caller's flock remains
    // held for this whole operation, and the store lock excludes cooperating
    // path writers in other processes.
    try validateLockedPendingDescriptor(
      recordDescriptor,
      expected: expectedPendingRecord,
      at: recordURL
    )

    let swapResult = temporaryFilename.withCString { temporaryName in
      canonicalFilename.withCString { canonicalName in
        Darwin.renameatx_np(
          directoryDescriptor,
          temporaryName,
          directoryDescriptor,
          canonicalName,
          UInt32(RENAME_SWAP)
        )
      }
    }
    guard swapResult == 0 else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    didSwap = true

    // After RENAME_SWAP the open receipt descriptor must be the canonical
    // path, while the temporary path must be exactly the original, still
    // locked pending inode. Any uncertainty leaves both names intact.
    guard Darwin.fstat(temporaryDescriptor, &receiptDescriptorStatus) == 0 else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    var pendingDescriptorStatus = stat()
    guard Darwin.fstat(recordDescriptor, &pendingDescriptorStatus) == 0 else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    var canonicalPathStatus = stat()
    let canonicalStatusResult = canonicalFilename.withCString { name in
      Darwin.fstatat(directoryDescriptor, name, &canonicalPathStatus, AT_SYMLINK_NOFOLLOW)
    }
    var temporaryPathStatus = stat()
    let temporaryStatusResult = temporaryFilename.withCString { name in
      Darwin.fstatat(directoryDescriptor, name, &temporaryPathStatus, AT_SYMLINK_NOFOLLOW)
    }
    guard canonicalStatusResult == 0,
      temporaryStatusResult == 0,
      Self.isSameRegularFile(canonicalPathStatus, receiptDescriptorStatus),
      Self.isSameRegularFile(temporaryPathStatus, pendingDescriptorStatus)
    else {
      throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
    }

    let persistedReceiptData = try readRecordData(
      from: temporaryDescriptor,
      status: receiptDescriptorStatus
    )
    guard try decodeEntry(persistedReceiptData) == .verified(receipt) else {
      throw BaiduUploadReconciliationRepositoryError.invalidRecord
    }
    let persistedPendingData = try readRecordData(
      from: recordDescriptor,
      status: pendingDescriptorStatus
    )
    guard try decodeEntry(persistedPendingData) == .pending(expectedPendingRecord) else {
      throw BaiduUploadReconciliationRepositoryError.invalidRecord
    }

    guard Darwin.fsync(directoryDescriptor) == 0 else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    let unlinkResult = temporaryFilename.withCString { name in
      Darwin.unlinkat(directoryDescriptor, name, 0)
    }
    guard unlinkResult == 0 else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    didUnlinkSwappedPending = true
    guard Darwin.fsync(directoryDescriptor) == 0 else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
  }

  private func validateLockedPendingDescriptor(
    _ descriptor: Int32,
    expected: BaiduUploadReconciliationRecord,
    at recordURL: URL
  ) throws {
    var descriptorStatus = stat()
    guard Darwin.fstat(descriptor, &descriptorStatus) == 0 else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    let data = try readRecordData(from: descriptor, status: descriptorStatus)
    guard try decodeEntry(data) == .pending(expected) else {
      throw BaiduUploadReconciliationRepositoryError.invalidRecord
    }

    let directoryURL = recordURL.deletingLastPathComponent()
    let directoryDescriptor = directoryURL.path.withCString { path in
      Darwin.open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
    }
    guard directoryDescriptor >= 0 else {
      let openError = errno
      if openError == ELOOP || openError == ENOTDIR {
        throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
      }
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    defer { Darwin.close(directoryDescriptor) }
    try validateReconciliationDirectoryDescriptor(directoryDescriptor)

    let filename = recordURL.lastPathComponent
    guard
      filename
        == Self.recordFilename(
          accountScope: expected.accountScope,
          backupID: expected.backupID
        )
    else {
      throw BaiduUploadReconciliationRepositoryError.invalidRecord
    }
    var pathStatus = stat()
    let statusResult = filename.withCString { name in
      Darwin.fstatat(directoryDescriptor, name, &pathStatus, AT_SYMLINK_NOFOLLOW)
    }
    guard statusResult == 0 else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    guard Self.isSameRegularFile(pathStatus, descriptorStatus) else {
      throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
    }
  }

  private func validateReconciliationDirectoryDescriptor(_ descriptor: Int32) throws {
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0 else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      status.st_mode & mode_t(0o7777) == mode_t(Self.directoryPermissions)
    else {
      throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
    }
  }

  private static func isSameRegularFile(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev
      && lhs.st_ino == rhs.st_ino
      && lhs.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
      && rhs.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
      && lhs.st_mode & mode_t(0o7777) == mode_t(filePermissions)
      && rhs.st_mode & mode_t(0o7777) == mode_t(filePermissions)
  }

  private func writeAll(_ data: Data, to descriptor: Int32) throws {
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

  private func recordURL(accountScope: BaiduAccountScope, backupID: UUID) throws -> URL {
    try reconciliationDirectoryURL().appendingPathComponent(
      Self.recordFilename(accountScope: accountScope, backupID: backupID),
      isDirectory: false
    )
  }

  static func recordFilename(accountScope: BaiduAccountScope, backupID: UUID) -> String {
    "\(accountScope.persistenceKey).\(backupID.uuidString.lowercased()).\(recordFileExtension)"
  }

  private static func legacyRecordFilename(backupID: UUID) -> String {
    "\(backupID.uuidString.lowercased()).\(recordFileExtension)"
  }

  private static func scopedRecordIdentity(
    from filename: String
  ) -> (accountScope: BaiduAccountScope, backupID: UUID)? {
    let components = filename.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3,
      components[2] == Substring(recordFileExtension),
      let bindingID = UUID(uuidString: String(components[0])),
      let accountScope = try? BaiduAccountScope(brokerBindingID: bindingID),
      String(components[0]) == accountScope.persistenceKey,
      let backupID = UUID(uuidString: String(components[1])),
      String(components[1]) == backupID.uuidString.lowercased()
    else {
      return nil
    }
    return (accountScope, backupID)
  }

  private static func legacyBackupID(from filename: String) -> UUID? {
    let url = URL(fileURLWithPath: filename)
    guard url.pathExtension == recordFileExtension,
      let backupID = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
      filename == legacyRecordFilename(backupID: backupID)
    else {
      return nil
    }
    return backupID
  }

  private static func isCanonicalTemporaryFilename(_ filename: String) -> Bool {
    let bytes = Array(filename.utf8)
    guard bytes.count == 41,
      bytes[0] == 0x2E,
      bytes[37] == 0x2E,
      bytes[38] == 0x74,
      bytes[39] == 0x6D,
      bytes[40] == 0x70
    else {
      return false
    }
    let uuidString = String(decoding: bytes[1..<37], as: UTF8.self)
    guard let uuid = UUID(uuidString: uuidString) else { return false }
    return filename == ".\(uuid.uuidString.lowercased()).tmp"
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

  private func inspectExistingReconciliationDirectory(
    removeTemporaryFiles: Bool = true
  ) throws -> Int? {
    let directoryURL = try reconciliationDirectoryURL()
    guard let attributes = try attributesIfPresent(at: directoryURL) else { return nil }
    try validateDirectoryAttributes(
      attributes,
      requiredPermissions: Self.directoryPermissions
    )
    return try recoverTemporaryFilesAndCountRecords(
      in: directoryURL,
      removeTemporaryFiles: removeTemporaryFiles
    )
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
        try synchronizeDirectory(at: url.deletingLastPathComponent())
        return
      }
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }

    guard let attributes = try attributesIfPresent(at: url) else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    try validateDirectoryAttributes(attributes, requiredPermissions: requiredPermissions)
    try synchronizeDirectory(at: url.deletingLastPathComponent())
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
    _ existing: BaiduUploadReconciliationEntry,
    requested: BaiduUploadReconciliationRecord,
    at recordURL: URL
  ) throws -> BaiduUploadReconciliationAdmission {
    switch existing {
    case .verified(let receipt):
      guard Self.hasSameUploadIdentity(receipt.record, requested) else {
        return .identityConflict
      }
      try synchronizeExistingRecord(at: recordURL)
      return .verified(receipt)
    case .pending(let record):
      guard Self.hasSameUploadIdentity(record, requested) else {
        return .identityConflict
      }
      try synchronizeExistingRecord(at: recordURL)
      guard let descriptor = try acquireRecordDescriptor(for: record, at: recordURL) else {
        return .inProgress(ownerAttemptID: record.attemptID)
      }
      _ = inkNotesFlock(descriptor, LOCK_UN)
      Darwin.close(descriptor)
      return .existing
    }
  }

  private func acquireRecordDescriptor(
    for expected: BaiduUploadReconciliationRecord,
    at recordURL: URL
  ) throws -> Int32? {
    let descriptor = recordURL.path.withCString { path in
      Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      if errno == ELOOP {
        throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
      }
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    var shouldClose = true
    defer {
      if shouldClose {
        Darwin.close(descriptor)
      }
    }

    while inkNotesFlock(descriptor, LOCK_EX | LOCK_NB) == -1 {
      let lockError = errno
      if lockError == EINTR { continue }
      if lockError == EWOULDBLOCK || lockError == EAGAIN {
        return nil
      }
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    try validateLockedPendingDescriptor(descriptor, expected: expected, at: recordURL)
    shouldClose = false
    return descriptor
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

  private func loadEntryIfPresent(
    at recordURL: URL,
    expectedAccountScope: BaiduAccountScope,
    expectedBackupID: UUID
  ) throws -> BaiduUploadReconciliationEntry? {
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
    let entry = try decodeEntry(data)
    guard entry.accountScope == expectedAccountScope,
      entry.backupID == expectedBackupID,
      recordURL.lastPathComponent
        == Self.recordFilename(
          accountScope: entry.accountScope,
          backupID: entry.backupID
        )
    else {
      throw BaiduUploadReconciliationRepositoryError.invalidRecord
    }
    return entry
  }

  private func recoverTemporaryFilesAndCountRecords(
    in directoryURL: URL,
    removeTemporaryFiles: Bool = true
  ) throws -> Int {
    var enumerationFailed = false
    guard
      let enumerator = fileManager.enumerator(
        at: directoryURL,
        includingPropertiesForKeys: nil,
        options: [.skipsSubdirectoryDescendants],
        errorHandler: { _, _ in
          enumerationFailed = true
          return false
        }
      )
    else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }

    var entries: [URL] = []
    while let value = enumerator.nextObject() {
      guard let entry = value as? URL else {
        throw BaiduUploadReconciliationRepositoryError.persistenceFailure
      }
      entries.append(entry)
      guard entries.count <= Self.maximumDirectoryEntryCount else {
        throw BaiduUploadReconciliationRepositoryError.tooManyRecords(
          maximum: Self.maximumDirectoryEntryCount
        )
      }
    }
    guard !enumerationFailed else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }

    var recordCount = 0
    var legacyRecordFound = false
    var temporaryFiles: [URL] = []
    for entry in entries {
      if let scopedIdentity = Self.scopedRecordIdentity(from: entry.lastPathComponent) {
        guard
          try loadEntryIfPresent(
            at: entry,
            expectedAccountScope: scopedIdentity.accountScope,
            expectedBackupID: scopedIdentity.backupID
          ) != nil
        else {
          throw BaiduUploadReconciliationRepositoryError.persistenceFailure
        }
        recordCount += 1
        guard recordCount <= Self.maximumRecordCount else {
          throw BaiduUploadReconciliationRepositoryError.tooManyRecords(
            maximum: Self.maximumRecordCount
          )
        }
        continue
      }

      if let legacyBackupID = Self.legacyBackupID(from: entry.lastPathComponent) {
        try validateFile(at: entry)
        _ = try loadLegacyRecord(at: entry, expectedBackupID: legacyBackupID)
        legacyRecordFound = true
        recordCount += 1
        guard recordCount <= Self.maximumRecordCount else {
          throw BaiduUploadReconciliationRepositoryError.tooManyRecords(
            maximum: Self.maximumRecordCount
          )
        }
        continue
      }

      guard Self.isCanonicalTemporaryFilename(entry.lastPathComponent) else {
        throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
      }
      try validateFile(at: entry)
      temporaryFiles.append(entry)
    }

    guard !legacyRecordFound else {
      throw BaiduUploadReconciliationRepositoryError.legacyUnscopedRecordsPresent
    }
    guard temporaryFiles.count <= 1 else {
      throw BaiduUploadReconciliationRepositoryError.tooManyRecords(
        maximum: Self.maximumRecordCount
      )
    }

    if removeTemporaryFiles {
      for temporaryFile in temporaryFiles {
        _ = try unlinkValidatedTemporaryFile(at: temporaryFile)
      }
      if !temporaryFiles.isEmpty {
        try synchronizeDirectory(at: directoryURL)
      }
    }
    return recordCount
  }

  @discardableResult
  private func unlinkValidatedTemporaryFile(at temporaryURL: URL) throws -> Bool {
    let directoryURL = temporaryURL.deletingLastPathComponent()
    let directoryDescriptor = directoryURL.path.withCString { path in
      Darwin.open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
    }
    guard directoryDescriptor >= 0 else {
      let openError = errno
      if openError == ENOENT { return false }
      if openError == ELOOP || openError == ENOTDIR {
        throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
      }
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    defer { Darwin.close(directoryDescriptor) }

    var directoryStatus = stat()
    guard Darwin.fstat(directoryDescriptor, &directoryStatus) == 0 else {
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    guard directoryStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      directoryStatus.st_mode & mode_t(0o7777) == mode_t(Self.directoryPermissions)
    else {
      throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
    }

    let filename = temporaryURL.lastPathComponent
    guard Self.isCanonicalTemporaryFilename(filename) else {
      throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
    }
    let fileDescriptor = filename.withCString { name in
      Darwin.openat(directoryDescriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard fileDescriptor >= 0 else {
      let openError = errno
      if openError == ENOENT { return false }
      if openError == ELOOP || openError == ENOTDIR {
        throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
      }
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    defer { Darwin.close(fileDescriptor) }

    var descriptorStatus = stat()
    guard Darwin.fstat(fileDescriptor, &descriptorStatus) == 0,
      descriptorStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      descriptorStatus.st_mode & mode_t(0o7777) == mode_t(Self.filePermissions)
    else {
      throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
    }

    var pathStatus = stat()
    let statusResult = filename.withCString { name in
      Darwin.fstatat(directoryDescriptor, name, &pathStatus, AT_SYMLINK_NOFOLLOW)
    }
    guard statusResult == 0 else {
      let statusError = errno
      if statusError == ENOENT { return false }
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    guard pathStatus.st_dev == descriptorStatus.st_dev,
      pathStatus.st_ino == descriptorStatus.st_ino,
      pathStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      pathStatus.st_mode & mode_t(0o7777) == mode_t(Self.filePermissions)
    else {
      throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
    }

    let unlinkResult = filename.withCString { name in
      Darwin.unlinkat(directoryDescriptor, name, 0)
    }
    guard unlinkResult == 0 else {
      let unlinkError = errno
      if unlinkError == ENOENT { return false }
      if unlinkError == EISDIR || unlinkError == EPERM {
        throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
      }
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    return true
  }

  private func loadLegacyRecord(
    at recordURL: URL,
    expectedBackupID: UUID
  ) throws -> BaiduUploadReconciliationLegacyRecordV1 {
    let data = try readRecordData(at: recordURL)
    let record: BaiduUploadReconciliationLegacyRecordV1
    do {
      record = try Self.makeDecoder().decode(
        BaiduUploadReconciliationLegacyRecordV1.self,
        from: data
      )
    } catch {
      throw BaiduUploadReconciliationRepositoryError.invalidRecord
    }
    try Self.validate(record)
    guard record.backupID == expectedBackupID,
      recordURL.lastPathComponent == Self.legacyRecordFilename(backupID: record.backupID)
    else {
      throw BaiduUploadReconciliationRepositoryError.invalidRecord
    }
    return record
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
    let descriptor = url.path.withCString { path in
      Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      if errno == ELOOP {
        throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
      }
      throw BaiduUploadReconciliationRepositoryError.persistenceFailure
    }
    defer { Darwin.close(descriptor) }

    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0,
      status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      status.st_mode & mode_t(0o7777) == mode_t(Self.filePermissions),
      status.st_size >= 0
    else {
      throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
    }

    return try readRecordData(from: descriptor, status: status)
  }

  private func readRecordData(from descriptor: Int32, status: stat) throws -> Data {
    guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      status.st_mode & mode_t(0o7777) == mode_t(Self.filePermissions),
      status.st_size >= 0
    else {
      throw BaiduUploadReconciliationRepositoryError.invalidStoreLayout
    }

    let size = UInt64(status.st_size)
    if size > UInt64(Self.maximumRecordByteCount) {
      throw BaiduUploadReconciliationRepositoryError.recordTooLarge(
        actual: size > UInt64(Int.max) ? Int.max : Int(size),
        maximum: Self.maximumRecordByteCount
      )
    }

    var data = Data()
    data.reserveCapacity(Int(size))
    var buffer = [UInt8](repeating: 0, count: 4 * 1024)
    while true {
      let remainingByteCount = Self.maximumRecordByteCount - data.count
      let requestedByteCount = min(4 * 1024, remainingByteCount + 1)
      let readByteCount = buffer.withUnsafeMutableBytes { rawBuffer in
        Darwin.pread(
          descriptor,
          rawBuffer.baseAddress,
          requestedByteCount,
          off_t(data.count)
        )
      }
      if readByteCount == -1, errno == EINTR { continue }
      guard readByteCount >= 0 else {
        throw BaiduUploadReconciliationRepositoryError.persistenceFailure
      }
      guard readByteCount > 0 else { break }

      let (nextByteCount, overflow) = data.count.addingReportingOverflow(readByteCount)
      guard !overflow, nextByteCount <= Self.maximumRecordByteCount else {
        throw BaiduUploadReconciliationRepositoryError.recordTooLarge(
          actual: overflow ? Int.max : nextByteCount,
          maximum: Self.maximumRecordByteCount
        )
      }
      data.append(contentsOf: buffer.prefix(readByteCount))
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

  private func encode(_ receipt: BaiduVerifiedRemoteBackupReceipt) throws -> Data {
    do {
      return try Self.makeEncoder().encode(receipt)
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

  private func decodeEntry(_ data: Data) throws -> BaiduUploadReconciliationEntry {
    let schemaVersion: Int
    do {
      schemaVersion = try Self.makeDecoder().decode(
        BaiduUploadReconciliationSchemaDiscriminator.self,
        from: data
      ).schemaVersion
    } catch {
      throw BaiduUploadReconciliationRepositoryError.invalidRecord
    }

    switch schemaVersion {
    case BaiduUploadReconciliationLegacyRecordV1.schemaVersion:
      // Schema v1 is valid only under its unscoped legacy filename and is
      // handled by the global legacy barrier, never as a scoped entry.
      throw BaiduUploadReconciliationRepositoryError.invalidRecord
    case BaiduUploadReconciliationRecord.currentSchemaVersion:
      let record = try decode(data)
      try Self.validate(record)
      return .pending(record)
    case BaiduVerifiedRemoteBackupReceipt.currentSchemaVersion:
      let receipt: BaiduVerifiedRemoteBackupReceipt
      do {
        receipt = try Self.makeDecoder().decode(
          BaiduVerifiedRemoteBackupReceipt.self,
          from: data
        )
      } catch {
        throw BaiduUploadReconciliationRepositoryError.invalidRecord
      }
      try Self.validate(receipt)
      return .verified(receipt)
    default:
      throw BaiduUploadReconciliationRepositoryError.unsupportedSchemaVersion(
        found: schemaVersion
      )
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

  private static func validate(_ receipt: BaiduVerifiedRemoteBackupReceipt) throws {
    guard receipt.schemaVersion == BaiduVerifiedRemoteBackupReceipt.currentSchemaVersion else {
      throw BaiduUploadReconciliationRepositoryError.unsupportedSchemaVersion(
        found: receipt.schemaVersion
      )
    }
    guard receipt.recordType == BaiduVerifiedRemoteBackupReceipt.verifiedRecordType,
      receipt.verificationVersion
        == BaiduVerifiedRemoteBackupReceipt.currentVerificationVersion,
      receipt.remoteFSID > 0,
      receipt.verifiedByteCount == receipt.localByteCount,
      receipt.verifiedSHA256 == receipt.archiveSHA256
    else {
      throw BaiduUploadReconciliationRepositoryError.invalidRecord
    }
    try validate(receipt.record)
  }

  private static func validate(
    _ record: BaiduUploadReconciliationLegacyRecordV1
  ) throws {
    guard record.schemaVersion == BaiduUploadReconciliationLegacyRecordV1.schemaVersion else {
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
    lhs.accountScope == rhs.accountScope
      && lhs.backupID == rhs.backupID
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

extension BaiduUploadReconciliationRepository: BaiduUploadReconciliationStoring {}

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

private struct BaiduUploadReconciliationSchemaDiscriminator: Decodable {
  let schemaVersion: Int

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
  }
}

private enum BaiduUploadReconciliationWriteError: Error {
  case destinationAlreadyExists
}
