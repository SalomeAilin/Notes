import Foundation
import Testing

@testable import InkNotesCore

@Suite("Baidu upload reconciliation repository")
struct BaiduUploadReconciliationRepositoryTests {
  private let backupID = UUID(uuidString: "B2000000-0000-0000-0000-000000000001")!
  private let attemptID = UUID(uuidString: "A2000000-0000-0000-0000-000000000001")!

  @Test("Default storage fails closed without permanent Application Support")
  func defaultStorageRequiresApplicationSupport() async throws {
    let fileManager = ReconciliationApplicationSupportUnavailableFileManager()
    let isolatedTemporaryDirectory = fileManager.temporaryDirectory
    defer { try? FileManager.default.removeItem(at: isolatedTemporaryDirectory) }
    let repository = BaiduUploadReconciliationRepository(fileManager: fileManager)

    await #expect(
      throws: BaiduUploadReconciliationRepositoryError.persistenceDirectoryUnavailable
    ) {
      try await repository.admit(self.record())
    }
  }

  @Test("Admission survives a new repository instance and is idempotent")
  func admissionPersistsAcrossInstances() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let expected = record()

    let firstRepository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    #expect(try await firstRepository.admit(expected) == .created)

    let recordURL = self.recordURL(rootURL: rootURL, backupID: backupID)
    let directoryURL = recordURL.deletingLastPathComponent()
    let lockURL = rootURL.appendingPathComponent(".UploadReconciliation.lock")
    #expect(try permissions(at: directoryURL, fileManager: fileManager) == 0o700)
    #expect(try permissions(at: recordURL, fileManager: fileManager) == 0o600)
    #expect(try permissions(at: lockURL, fileManager: fileManager) == 0o600)
    let originalBytes = try Data(contentsOf: recordURL)

    let restartedRepository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    #expect(try await restartedRepository.load(backupID: backupID) == expected)
    #expect(try await restartedRepository.admit(expected) == .existing)
    #expect(try Data(contentsOf: recordURL) == originalBytes)

    let object = try #require(
      JSONSerialization.jsonObject(with: originalBytes) as? [String: Any]
    )
    #expect(
      Set(object.keys)
        == Set([
          "schemaVersion", "attemptID", "backupID", "archiveSHA256", "localMD5",
          "localByteCount", "requestedPath",
        ])
    )
    let persistedText = try #require(String(data: originalBytes, encoding: .utf8))
    for forbidden in ["access_token", "refresh_token", "uploadid", "rawResponse", "tokenHash"] {
      #expect(!persistedText.contains(forbidden))
    }
  }

  @Test("A restarted attempt with the same upload identity reuses the immutable owner record")
  func restartedAttemptReusesExistingIdentityWithoutTakingOwnership() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let original = record()
    #expect(try await repository.admit(original) == .created)
    let url = recordURL(rootURL: rootURL, backupID: backupID)
    let originalBytes = try Data(contentsOf: url)

    let restartedAttempt = record(
      attemptID: UUID(uuidString: "A2000000-0000-0000-0000-000000000002")!
    )
    #expect(try await repository.admit(restartedAttempt) == .existing)
    #expect(try Data(contentsOf: url) == originalBytes)
    #expect(try await repository.load(backupID: backupID) == original)
    await #expect(throws: BaiduUploadReconciliationRepositoryError.identityConflict) {
      try await repository.removeOwned(restartedAttempt)
    }
  }

  @Test("Same backup with a different upload identity never overwrites bytes")
  func identityConflictsPreserveOriginalBytes() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let original = record()
    #expect(try await repository.admit(original) == .created)
    let url = recordURL(rootURL: rootURL, backupID: backupID)
    let originalBytes = try Data(contentsOf: url)

    let variants = [
      record(archiveSHA256: String(repeating: "1", count: 64)),
      record(localMD5: String(repeating: "2", count: 32)),
      record(localByteCount: 4_097),
      record(requestedPath: try canonicalPath(folderName: "另一个应用", backupID: backupID)),
    ]
    for variant in variants {
      #expect(try await repository.admit(variant) == .identityConflict)
      #expect(try Data(contentsOf: url) == originalBytes)
    }
  }

  @Test("Only the owning attempt and full identity can remove a record")
  func removalRequiresExactOwnership() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let owned = record()
    #expect(try await repository.admit(owned) == .created)

    let otherAttempt = record(
      attemptID: UUID(uuidString: "A2000000-0000-0000-0000-000000000099")!
    )
    await #expect(throws: BaiduUploadReconciliationRepositoryError.identityConflict) {
      try await repository.removeOwned(otherAttempt)
    }
    await #expect(throws: BaiduUploadReconciliationRepositoryError.identityConflict) {
      try await repository.removeOwned(
        self.record(localMD5: String(repeating: "3", count: 32))
      )
    }
    #expect(try await repository.load(backupID: backupID) == owned)

    #expect(try await repository.removeOwned(owned))
    #expect(try await repository.load(backupID: backupID) == nil)
    #expect(try await repository.removeOwned(owned) == false)
  }

  @Test("Concurrent repository instances atomically preserve one identity")
  func concurrentInstancesPreserveOneIdentity() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let firstRepository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let secondRepository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let firstRecord = record()
    let secondRecord = record(archiveSHA256: String(repeating: "c", count: 64))

    async let firstAdmission = firstRepository.admit(firstRecord)
    async let secondAdmission = secondRepository.admit(secondRecord)
    let admissions = try await [firstAdmission, secondAdmission]

    #expect(admissions.filter { $0 == .created }.count == 1)
    #expect(admissions.filter { $0 == .identityConflict }.count == 1)
    let persisted = try await firstRepository.load(backupID: backupID)
    #expect(persisted == firstRecord || persisted == secondRecord)
  }

  @Test("A restart removes a canonical restricted temporary record before admission")
  func canonicalTemporaryRecordIsRecoveredAfterRestart() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let directoryURL = rootURL.appendingPathComponent(
      BaiduUploadReconciliationRepository.reconciliationDirectoryName,
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    let temporaryURL = directoryURL.appendingPathComponent(
      ".\(UUID().uuidString.lowercased()).tmp"
    )
    #expect(
      fileManager.createFile(
        atPath: temporaryURL.path,
        contents: Data("partial-record".utf8),
        attributes: [.posixPermissions: 0o600]
      )
    )

    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    #expect(try await repository.admit(record()) == .created)
    #expect(!fileManager.fileExists(atPath: temporaryURL.path))
    #expect(try await repository.load(backupID: backupID) == record())
  }

  @Test("Unknown or insecure temporary entries remain fail-closed")
  func invalidTemporaryEntriesAreNeverRemoved() async throws {
    let fileManager = FileManager.default
    let cases = [
      (".tmp", 0o600),
      ("..tmp", 0o600),
      (".not-a-uuid.tmp", 0o600),
      (".A2000000-0000-0000-0000-000000000001.tmp", 0o600),
      (".\(UUID().uuidString.lowercased()).tmp", 0o644),
    ]

    for (filename, permissions) in cases {
      let rootURL = makeRootURL(fileManager: fileManager)
      defer { try? fileManager.removeItem(at: rootURL) }
      let directoryURL = rootURL.appendingPathComponent(
        BaiduUploadReconciliationRepository.reconciliationDirectoryName,
        isDirectory: true
      )
      try fileManager.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try fileManager.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directoryURL.path
      )
      let temporaryURL = directoryURL.appendingPathComponent(filename)
      #expect(
        fileManager.createFile(
          atPath: temporaryURL.path,
          contents: Data(),
          attributes: [.posixPermissions: permissions]
        )
      )

      let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
      await #expect(throws: BaiduUploadReconciliationRepositoryError.invalidStoreLayout) {
        try await repository.admit(self.record())
      }
      #expect(fileManager.fileExists(atPath: temporaryURL.path))
    }
  }

  @Test("A canonical temporary symlink remains fail-closed")
  func temporarySymlinkIsNeverRemoved() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let directoryURL = rootURL.appendingPathComponent(
      BaiduUploadReconciliationRepository.reconciliationDirectoryName,
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    let targetURL = rootURL.appendingPathComponent("temporary-target")
    try writeRestricted(Data("do-not-remove".utf8), to: targetURL, fileManager: fileManager)
    let temporaryURL = directoryURL.appendingPathComponent(
      ".\(UUID().uuidString.lowercased()).tmp"
    )
    try fileManager.createSymbolicLink(at: temporaryURL, withDestinationURL: targetURL)

    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    await #expect(throws: BaiduUploadReconciliationRepositoryError.invalidStoreLayout) {
      try await repository.admit(self.record())
    }
    #expect(fileManager.fileExists(atPath: temporaryURL.path))
    #expect(try Data(contentsOf: targetURL) == Data("do-not-remove".utf8))
  }

  @Test("Temporary recovery is bounded by the global directory entry limit")
  func excessiveTemporaryEntriesFailClosed() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let directoryURL = rootURL.appendingPathComponent(
      BaiduUploadReconciliationRepository.reconciliationDirectoryName,
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    for _ in 0...BaiduUploadReconciliationRepository.maximumRecordCount {
      let temporaryURL = directoryURL.appendingPathComponent(
        ".\(UUID().uuidString.lowercased()).tmp"
      )
      #expect(
        fileManager.createFile(
          atPath: temporaryURL.path,
          contents: Data(),
          attributes: [.posixPermissions: 0o600]
        )
      )
    }

    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    await #expect(
      throws: BaiduUploadReconciliationRepositoryError.tooManyRecords(
        maximum: BaiduUploadReconciliationRepository.maximumRecordCount
      )
    ) {
      try await repository.admit(self.record())
    }
    #expect(
      try fileManager.contentsOfDirectory(atPath: directoryURL.path).count
        == BaiduUploadReconciliationRepository.maximumRecordCount + 1
    )
  }

  @Test("Invalid digests, sizes, and noncanonical paths are rejected before writing")
  func invalidIdentityBoundariesFailClosed() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)

    let invalidRecords = [
      record(archiveSHA256: String(repeating: "A", count: 64)),
      record(archiveSHA256: String(repeating: "a", count: 63)),
      record(localMD5: String(repeating: "g", count: 32)),
      record(localByteCount: 0),
      record(localByteCount: UInt64(BackupArchiveCodec.headerByteCount - 1)),
      record(localByteCount: UInt64(BackupArchiveLimits.maximumArchiveByteCount) + 1),
      record(requestedPath: "/apps/测试应用/../\(backupID.uuidString).notesbackup"),
      record(requestedPath: "/apps/测试应用/backup-wrong.notesbackup"),
    ]
    for invalidRecord in invalidRecords {
      await #expect(throws: BaiduUploadReconciliationRepositoryError.invalidRecord) {
        try await repository.admit(invalidRecord)
      }
    }
    #expect(!fileManager.fileExists(atPath: rootURL.path))
  }

  @Test("Corrupt, extra-key, and unsupported-version records never get replaced")
  func strictRecordDecodingFailsClosed() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let expected = record()
    #expect(try await repository.admit(expected) == .created)
    let url = recordURL(rootURL: rootURL, backupID: backupID)
    let canonicalBytes = try Data(contentsOf: url)

    let corruptBytes = Data("not-json".utf8)
    try writeRestricted(corruptBytes, to: url, fileManager: fileManager)
    await #expect(throws: BaiduUploadReconciliationRepositoryError.invalidRecord) {
      _ = try await repository.load(backupID: self.backupID)
    }
    await #expect(throws: BaiduUploadReconciliationRepositoryError.invalidRecord) {
      try await repository.admit(expected)
    }
    #expect(try Data(contentsOf: url) == corruptBytes)

    var object = try #require(
      JSONSerialization.jsonObject(with: canonicalBytes) as? [String: Any]
    )
    object["access_token"] = "must-not-be-accepted"
    let extraKeyBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try writeRestricted(extraKeyBytes, to: url, fileManager: fileManager)
    await #expect(throws: BaiduUploadReconciliationRepositoryError.invalidRecord) {
      _ = try await repository.load(backupID: self.backupID)
    }
    #expect(try Data(contentsOf: url) == extraKeyBytes)

    object.removeValue(forKey: "access_token")
    object["schemaVersion"] = 999
    let unsupportedBytes = try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys])
    try writeRestricted(unsupportedBytes, to: url, fileManager: fileManager)
    await #expect(
      throws: BaiduUploadReconciliationRepositoryError.unsupportedSchemaVersion(found: 999)
    ) {
      _ = try await repository.load(backupID: self.backupID)
    }
    #expect(try Data(contentsOf: url) == unsupportedBytes)
  }

  @Test("Both reported and actual record byte counts are bounded")
  func recordReadsEnforceBothSizeBoundaries() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    #expect(try await repository.admit(record()) == .created)
    let url = recordURL(rootURL: rootURL, backupID: backupID)
    let oversizedBytes = Data(
      repeating: 0x20,
      count: BaiduUploadReconciliationRepository.maximumRecordByteCount + 1
    )
    try writeRestricted(oversizedBytes, to: url, fileManager: fileManager)

    await #expect(
      throws: BaiduUploadReconciliationRepositoryError.recordTooLarge(
        actual: oversizedBytes.count,
        maximum: BaiduUploadReconciliationRepository.maximumRecordByteCount
      )
    ) {
      _ = try await repository.load(backupID: self.backupID)
    }

    let underreportingFileManager = ReconciliationUnderreportingFileManager(recordURL: url)
    let underreportingRepository = BaiduUploadReconciliationRepository(
      rootURL: rootURL,
      fileManager: underreportingFileManager
    )
    await #expect(
      throws: BaiduUploadReconciliationRepositoryError.recordTooLarge(
        actual: oversizedBytes.count,
        maximum: BaiduUploadReconciliationRepository.maximumRecordByteCount
      )
    ) {
      _ = try await underreportingRepository.load(backupID: self.backupID)
    }
  }

  @Test("Record count is globally bounded before a new attempt is admitted")
  func recordCountIsBounded() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let directoryURL = rootURL.appendingPathComponent(
      BaiduUploadReconciliationRepository.reconciliationDirectoryName,
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

    for _ in 0..<BaiduUploadReconciliationRepository.maximumRecordCount {
      let markerURL = directoryURL.appendingPathComponent(
        "\(UUID().uuidString.lowercased()).json"
      )
      #expect(
        fileManager.createFile(
          atPath: markerURL.path,
          contents: Data(),
          attributes: [.posixPermissions: 0o600]
        )
      )
    }

    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    await #expect(
      throws: BaiduUploadReconciliationRepositoryError.tooManyRecords(
        maximum: BaiduUploadReconciliationRepository.maximumRecordCount
      )
    ) {
      try await repository.admit(self.record())
    }
  }

  @Test("A file where a directory or record belongs is rejected")
  func directoryAndFileTypesFailClosed() async throws {
    let fileManager = FileManager.default
    let firstRootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: firstRootURL) }
    try fileManager.createDirectory(at: firstRootURL, withIntermediateDirectories: true)
    let directoryAsFileURL = firstRootURL.appendingPathComponent(
      BaiduUploadReconciliationRepository.reconciliationDirectoryName
    )
    #expect(fileManager.createFile(atPath: directoryAsFileURL.path, contents: Data()))
    let firstRepository = BaiduUploadReconciliationRepository(rootURL: firstRootURL)
    await #expect(throws: BaiduUploadReconciliationRepositoryError.invalidStoreLayout) {
      try await firstRepository.admit(self.record())
    }

    let secondRootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: secondRootURL) }
    let recordAsDirectoryURL = recordURL(rootURL: secondRootURL, backupID: backupID)
    try fileManager.createDirectory(
      at: recordAsDirectoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: recordAsDirectoryURL.deletingLastPathComponent().path
    )
    let secondRepository = BaiduUploadReconciliationRepository(rootURL: secondRootURL)
    await #expect(throws: BaiduUploadReconciliationRepositoryError.invalidStoreLayout) {
      _ = try await secondRepository.load(backupID: self.backupID)
    }
  }

  private func record(
    attemptID: UUID? = nil,
    archiveSHA256: String = String(repeating: "a", count: 64),
    localMD5: String = String(repeating: "b", count: 32),
    localByteCount: UInt64 = 4_096,
    requestedPath: String? = nil
  ) -> BaiduUploadReconciliationRecord {
    BaiduUploadReconciliationRecord(
      attemptID: attemptID ?? self.attemptID,
      backupID: backupID,
      archiveSHA256: archiveSHA256,
      localMD5: localMD5,
      localByteCount: localByteCount,
      requestedPath: requestedPath ?? (try! canonicalPath(folderName: "测试应用", backupID: backupID))
    )
  }

  private func canonicalPath(folderName: String, backupID: UUID) throws -> String {
    try BaiduNetdiskAppDirectory(folderName: folderName).backupPath(backupID: backupID)
  }

  private func makeRootURL(fileManager: FileManager) -> URL {
    fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  private func recordURL(rootURL: URL, backupID: UUID) -> URL {
    rootURL
      .appendingPathComponent(
        BaiduUploadReconciliationRepository.reconciliationDirectoryName,
        isDirectory: true
      )
      .appendingPathComponent("\(backupID.uuidString.lowercased()).json")
  }

  private func permissions(at url: URL, fileManager: FileManager) throws -> Int? {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue
  }

  private func writeRestricted(_ data: Data, to url: URL, fileManager: FileManager) throws {
    try data.write(to: url, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

private final class ReconciliationApplicationSupportUnavailableFileManager: FileManager,
  @unchecked Sendable
{
  private let isolatedTemporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)

  override var temporaryDirectory: URL {
    isolatedTemporaryDirectory
  }

  override func urls(
    for directory: FileManager.SearchPathDirectory,
    in domainMask: FileManager.SearchPathDomainMask
  ) -> [URL] {
    []
  }
}

private final class ReconciliationUnderreportingFileManager: FileManager, @unchecked Sendable {
  private let recordPath: String

  init(recordURL: URL) {
    self.recordPath = recordURL.path
    super.init()
  }

  override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
    var attributes = try super.attributesOfItem(atPath: path)
    if path == recordPath {
      attributes[.size] = NSNumber(value: 0)
    }
    return attributes
  }
}
