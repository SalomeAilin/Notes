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
    #expect(
      try await restartedRepository.load(accountScope: self.accountScope(), backupID: backupID)
        == expected)
    #expect(try await restartedRepository.admit(expected) == .existing)
    #expect(try Data(contentsOf: recordURL) == originalBytes)

    let object = try #require(
      JSONSerialization.jsonObject(with: originalBytes) as? [String: Any]
    )
    #expect(
      Set(object.keys)
        == Set([
          "schemaVersion", "accountScope", "attemptID", "backupID", "archiveSHA256",
          "localMD5", "localByteCount", "requestedPath",
        ])
    )
    let persistedText = try #require(String(data: originalBytes, encoding: .utf8))
    for forbidden in [
      "access_token", "refresh_token", "uploadid", "rawResponse", "tokenHash", "uk",
      "baidu_name", "netdisk_name", "avatar_url",
    ] {
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
    #expect(
      try await repository.load(accountScope: self.accountScope(), backupID: backupID) == original)
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
    #expect(
      try await repository.load(accountScope: self.accountScope(), backupID: backupID) == owned)

    #expect(try await repository.removeOwned(owned))
    #expect(try await repository.load(accountScope: self.accountScope(), backupID: backupID) == nil)
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
    let persisted = try await firstRepository.load(
      accountScope: self.accountScope(), backupID: backupID)
    #expect(persisted == firstRecord || persisted == secondRecord)
  }

  @Test("Different account scopes isolate the same backup ID")
  func differentAccountScopesAreIndependent() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let firstScope = accountScope()
    let secondScope = accountScope(
      UUID(uuidString: "D2000000-0000-0000-0000-000000000002")!
    )
    let firstRecord = record(accountScope: firstScope)
    let secondRecord = record(accountScope: secondScope)

    #expect(try await repository.admit(firstRecord) == .created)
    #expect(try await repository.admit(secondRecord) == .created)
    #expect(
      recordURL(rootURL: rootURL, accountScope: firstScope, backupID: backupID)
        != recordURL(rootURL: rootURL, accountScope: secondScope, backupID: backupID)
    )
    #expect(
      try await repository.load(accountScope: firstScope, backupID: backupID) == firstRecord
    )
    #expect(
      try await repository.load(accountScope: secondScope, backupID: backupID) == secondRecord
    )
  }

  @Test("A record from another account scope cannot remove the owner record")
  func crossAccountRemovalCannotDeleteOwner() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let owner = record()
    let otherScope = accountScope(
      UUID(uuidString: "D2000000-0000-0000-0000-000000000002")!
    )
    let wrongAccountRecord = record(accountScope: otherScope)

    #expect(try await repository.admit(owner) == .created)
    #expect(try await repository.removeOwned(wrongAccountRecord) == false)
    #expect(
      try await repository.load(accountScope: accountScope(), backupID: backupID) == owner
    )
  }

  @Test("Concurrent admissions for different account scopes both succeed")
  func concurrentDifferentAccountScopesDoNotConflict() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let firstRepository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let secondRepository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let firstRecord = record()
    let secondRecord = record(
      accountScope: accountScope(
        UUID(uuidString: "D2000000-0000-0000-0000-000000000002")!
      )
    )

    async let firstAdmission = firstRepository.admit(firstRecord)
    async let secondAdmission = secondRepository.admit(secondRecord)
    let admissions = try await [firstAdmission, secondAdmission]

    #expect(admissions.allSatisfy { $0 == .created })
  }

  @Test("Any valid unscoped v1 record globally blocks v2 without changing bytes")
  func legacyV1RecordBlocksEveryAccountAndBackup() async throws {
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
    let legacyURL = directoryURL.appendingPathComponent(
      "\(backupID.uuidString.lowercased()).json"
    )
    let legacyBytes = try legacyRecordData(backupID: backupID)
    try writeRestricted(legacyBytes, to: legacyURL, fileManager: fileManager)

    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let otherBackupID = UUID(uuidString: "B2000000-0000-0000-0000-000000000099")!
    let requested = record(
      accountScope: accountScope(
        UUID(uuidString: "D2000000-0000-0000-0000-000000000002")!
      ),
      backupID: otherBackupID
    )

    await #expect(
      throws: BaiduUploadReconciliationRepositoryError.legacyUnscopedRecordsPresent
    ) {
      try await repository.admit(requested)
    }
    await #expect(
      throws: BaiduUploadReconciliationRepositoryError.legacyUnscopedRecordsPresent
    ) {
      _ = try await repository.load(
        accountScope: requested.accountScope,
        backupID: otherBackupID
      )
    }
    await #expect(
      throws: BaiduUploadReconciliationRepositoryError.legacyUnscopedRecordsPresent
    ) {
      try await repository.removeOwned(requested)
    }
    #expect(try Data(contentsOf: legacyURL) == legacyBytes)
    #expect(
      !fileManager.fileExists(
        atPath: recordURL(
          rootURL: rootURL,
          accountScope: requested.accountScope,
          backupID: otherBackupID
        ).path
      )
    )
  }

  @Test("Record schema and filename layout cannot be cross-labeled")
  func recordSchemaMustMatchFilenameLayout() async throws {
    let fileManager = FileManager.default
    let scopedFilename = BaiduUploadReconciliationRepository.recordFilename(
      accountScope: accountScope(),
      backupID: backupID
    )
    let legacyFilename = "\(backupID.uuidString.lowercased()).json"
    let cases = [
      (scopedFilename, try legacyRecordData(backupID: backupID)),
      (legacyFilename, try JSONEncoder().encode(record())),
    ]

    for (filename, bytes) in cases {
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
      let misplacedURL = directoryURL.appendingPathComponent(filename)
      try writeRestricted(bytes, to: misplacedURL, fileManager: fileManager)
      let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
      let otherBackupID = UUID()

      await #expect(throws: BaiduUploadReconciliationRepositoryError.invalidRecord) {
        try await repository.admit(self.record(backupID: otherBackupID))
      }
      #expect(try Data(contentsOf: misplacedURL) == bytes)
    }
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
    #expect(
      try await repository.load(accountScope: self.accountScope(), backupID: backupID) == record())
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
      _ = try await repository.load(accountScope: self.accountScope(), backupID: self.backupID)
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
      _ = try await repository.load(accountScope: self.accountScope(), backupID: self.backupID)
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
      _ = try await repository.load(accountScope: self.accountScope(), backupID: self.backupID)
    }
    #expect(try Data(contentsOf: url) == unsupportedBytes)
  }

  @Test("Descriptor reads enforce the actual record byte limit")
  func recordReadsEnforceActualSizeBoundary() async throws {
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
      _ = try await repository.load(accountScope: self.accountScope(), backupID: self.backupID)
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
      let markerScope = accountScope(UUID())
      let markerBackupID = UUID()
      let markerRecord = record(
        accountScope: markerScope,
        backupID: markerBackupID
      )
      let markerURL = directoryURL.appendingPathComponent(
        BaiduUploadReconciliationRepository.recordFilename(
          accountScope: markerScope,
          backupID: markerBackupID
        )
      )
      #expect(
        fileManager.createFile(
          atPath: markerURL.path,
          contents: try JSONEncoder().encode(markerRecord),
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
      _ = try await secondRepository.load(
        accountScope: self.accountScope(), backupID: self.backupID)
    }
  }

  private func record(
    accountScope: BaiduAccountScope? = nil,
    backupID: UUID? = nil,
    attemptID: UUID? = nil,
    archiveSHA256: String = String(repeating: "a", count: 64),
    localMD5: String = String(repeating: "b", count: 32),
    localByteCount: UInt64 = 4_096,
    requestedPath: String? = nil
  ) -> BaiduUploadReconciliationRecord {
    let effectiveBackupID = backupID ?? self.backupID
    return BaiduUploadReconciliationRecord(
      accountScope: accountScope ?? self.accountScope(),
      attemptID: attemptID ?? self.attemptID,
      backupID: effectiveBackupID,
      archiveSHA256: archiveSHA256,
      localMD5: localMD5,
      localByteCount: localByteCount,
      requestedPath: requestedPath
        ?? (try! canonicalPath(folderName: "测试应用", backupID: effectiveBackupID))
    )
  }

  private func accountScope(
    _ bindingID: UUID = UUID(uuidString: "D2000000-0000-0000-0000-000000000001")!
  ) -> BaiduAccountScope {
    try! BaiduAccountScope(brokerBindingID: bindingID)
  }

  private func canonicalPath(folderName: String, backupID: UUID) throws -> String {
    try BaiduNetdiskAppDirectory(folderName: folderName).backupPath(backupID: backupID)
  }

  private func makeRootURL(fileManager: FileManager) -> URL {
    fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  private func recordURL(
    rootURL: URL,
    accountScope: BaiduAccountScope? = nil,
    backupID: UUID
  ) -> URL {
    rootURL
      .appendingPathComponent(
        BaiduUploadReconciliationRepository.reconciliationDirectoryName,
        isDirectory: true
      )
      .appendingPathComponent(
        BaiduUploadReconciliationRepository.recordFilename(
          accountScope: accountScope ?? self.accountScope(),
          backupID: backupID
        )
      )
  }

  private func legacyRecordData(backupID: UUID) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "schemaVersion": 1,
        "attemptID": attemptID.uuidString,
        "backupID": backupID.uuidString,
        "archiveSHA256": String(repeating: "a", count: 64),
        "localMD5": String(repeating: "b", count: 32),
        "localByteCount": 4_096,
        "requestedPath": try canonicalPath(folderName: "测试应用", backupID: backupID),
      ],
      options: [.prettyPrinted, .sortedKeys]
    )
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
