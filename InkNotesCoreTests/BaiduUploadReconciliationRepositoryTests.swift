import Darwin
import Foundation
import Testing

@testable import InkNotesCore

@_silgen_name("flock")
private func reconciliationTestFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

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
    let firstLease = try #require(
      (try await firstRepository.admit(expected)).createdLease
    )

    let recordURL = self.recordURL(rootURL: rootURL, backupID: backupID)
    let directoryURL = recordURL.deletingLastPathComponent()
    let lockURL = rootURL.appendingPathComponent(".UploadReconciliation.lock")
    #expect(try permissions(at: directoryURL, fileManager: fileManager) == 0o700)
    #expect(try permissions(at: recordURL, fileManager: fileManager) == 0o600)
    #expect(try permissions(at: lockURL, fileManager: fileManager) == 0o600)
    let originalBytes = try Data(contentsOf: recordURL)
    firstLease.release()

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
      "baidu_name", "netdisk_name", "avatar_url", "expiresAt", "expirationDate",
      "expires_at",
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
    let originalLease = try #require(
      (try await repository.admit(original)).createdLease
    )
    let url = recordURL(rootURL: rootURL, backupID: backupID)
    let originalBytes = try Data(contentsOf: url)

    let restartedAttempt = record(
      attemptID: UUID(uuidString: "A2000000-0000-0000-0000-000000000002")!
    )
    originalLease.release()
    #expect(try await repository.admit(restartedAttempt) == .existing)
    #expect(try Data(contentsOf: url) == originalBytes)
    #expect(
      try await repository.load(accountScope: self.accountScope(), backupID: backupID) == original)
    await #expect(throws: BaiduUploadReconciliationRepositoryError.invalidLease) {
      try await repository.removeOwned(.testingOnly(record: restartedAttempt))
    }
  }

  @Test("Same backup with a different upload identity never overwrites bytes")
  func identityConflictsPreserveOriginalBytes() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let original = record()
    let originalLease = try #require(
      (try await repository.admit(original)).createdLease
    )
    defer { originalLease.release() }
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

  @Test("Only the issuing repository's live lease can remove its exact record")
  func removalRequiresIssuerBoundLiveLease() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let owned = record()
    let lease = try #require((try await repository.admit(owned)).createdLease)

    let foreignRootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: foreignRootURL) }
    let foreignRepository = BaiduUploadReconciliationRepository(rootURL: foreignRootURL)
    let foreignLease = try #require(
      (try await foreignRepository.admit(owned)).createdLease
    )
    defer { foreignLease.release() }
    await #expect(throws: BaiduUploadReconciliationRepositoryError.invalidLease) {
      try await repository.removeOwned(foreignLease)
    }
    #expect(
      try await repository.load(accountScope: self.accountScope(), backupID: backupID) == owned)

    #expect(try await repository.removeOwned(lease))
    #expect(try await repository.load(accountScope: self.accountScope(), backupID: backupID) == nil)
    #expect(try await repository.removeOwned(lease) == false)
    lease.release()
  }

  @Test("Owned record deletion never delegates to recursive FileManager removal")
  func ownedRecordDeletionNeverRecursesIntoASwappedDirectory() async throws {
    let fileManager = ReconciliationRecursiveRemovalTrapFileManager()
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let recordURL = self.recordURL(rootURL: rootURL, backupID: backupID)
    let victimURL = rootURL.appendingPathComponent("victim", isDirectory: true)
    let markerURL = victimURL.appendingPathComponent("must-survive.txt")
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: victimURL, withIntermediateDirectories: false)
    try Data("must survive".utf8).write(to: markerURL)
    fileManager.arm(recordURL: recordURL, victimURL: victimURL)
    let repository = BaiduUploadReconciliationRepository(
      rootURL: rootURL,
      fileManager: fileManager
    )
    let owned = record()
    let lease = try #require((try await repository.admit(owned)).createdLease)

    #expect(try await repository.removeOwned(lease))
    lease.release()
    #expect(FileManager.default.fileExists(atPath: markerURL.path))
    #expect(!FileManager.default.fileExists(atPath: recordURL.path))
  }

  @Test("Owned record deletion does not recover unrelated temporary records")
  func ownedRecordDeletionOnlyRemovesItsTarget() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let owned = record()
    let lease = try #require((try await repository.admit(owned)).createdLease)

    let directoryURL = recordURL(rootURL: rootURL, backupID: backupID)
      .deletingLastPathComponent()
    let temporaryURL = directoryURL.appendingPathComponent(
      ".11111111-1111-1111-1111-111111111111.tmp"
    )
    let temporaryBytes = Data("pending writer".utf8)
    try writeRestricted(temporaryBytes, to: temporaryURL, fileManager: fileManager)

    #expect(try await repository.removeOwned(lease))
    lease.release()
    #expect(try Data(contentsOf: temporaryURL) == temporaryBytes)
  }

  @Test("Temporary recovery never delegates to recursive FileManager removal")
  func temporaryRecoveryNeverRecursesIntoASwappedDirectory() async throws {
    let fileManager = ReconciliationRecursiveRemovalTrapFileManager()
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let directoryURL = rootURL.appendingPathComponent(
      BaiduUploadReconciliationRepository.reconciliationDirectoryName,
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directoryURL.path
    )
    let temporaryURL = directoryURL.appendingPathComponent(
      ".22222222-2222-2222-2222-222222222222.tmp"
    )
    try writeRestricted(Data("temporary".utf8), to: temporaryURL, fileManager: fileManager)
    let victimURL = rootURL.appendingPathComponent("victim", isDirectory: true)
    let markerURL = victimURL.appendingPathComponent("must-survive.txt")
    try FileManager.default.createDirectory(at: victimURL, withIntermediateDirectories: false)
    try Data("must survive".utf8).write(to: markerURL)
    fileManager.arm(recordURL: temporaryURL, victimURL: victimURL)
    let repository = BaiduUploadReconciliationRepository(
      rootURL: rootURL,
      fileManager: fileManager
    )

    let lease = try #require((try await repository.admit(record())).createdLease)
    lease.release()
    #expect(FileManager.default.fileExists(atPath: markerURL.path))
    #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
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

    #expect(admissions.filter { $0.isCreated }.count == 1)
    #expect(admissions.filter { $0 == .identityConflict }.count == 1)
    let persisted = try await firstRepository.load(
      accountScope: self.accountScope(), backupID: backupID)
    #expect(persisted == firstRecord || persisted == secondRecord)
  }

  @Test("A live record lease blocks another repository until explicit release")
  func liveLeaseBlocksSameProcessRepositories() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let firstRepository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let secondRepository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let expected = record()

    let lease = try #require(
      (try await firstRepository.admit(expected)).createdLease
    )
    #expect(
      try await secondRepository.admit(expected)
        == .inProgress(ownerAttemptID: expected.attemptID)
    )
    #expect(
      try await secondRepository.admit(
        record(archiveSHA256: String(repeating: "c", count: 64))
      ) == .identityConflict
    )

    lease.release()
    lease.release()
    #expect(try await secondRepository.admit(expected) == .existing)
  }

  @Test("Lease deinitialization releases the cross-repository record lock")
  func leaseDeinitReleasesRecordLock() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let firstRepository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let secondRepository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let expected = record()

    var lease: BaiduUploadReconciliationLease?
    do {
      let admission = try await firstRepository.admit(expected)
      guard case .created(let createdLease) = admission else {
        Issue.record("Expected the first repository to create a live lease")
        return
      }
      lease = createdLease
    }
    weak let weakLease = lease
    #expect(
      try await secondRepository.admit(expected)
        == .inProgress(ownerAttemptID: expected.attemptID)
    )

    lease = nil
    #expect(weakLease == nil)
    #expect(try await secondRepository.admit(expected) == .existing)
  }

  @Test("A released lease cannot delete its persistent record")
  func releasedLeaseCannotDeleteRecord() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let expected = record()
    let lease = try #require((try await repository.admit(expected)).createdLease)

    lease.release()
    await #expect(throws: BaiduUploadReconciliationRepositoryError.invalidLease) {
      try await repository.removeOwned(lease)
    }
    #expect(
      try await repository.load(accountScope: expected.accountScope, backupID: expected.backupID)
        == expected
    )
  }

  @Test("An inode replacement cannot be deleted through the original live lease")
  func replacedRecordPathInvalidatesLiveLeaseDeletion() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let expected = record()
    let lease = try #require((try await repository.admit(expected)).createdLease)
    defer { lease.release() }
    let url = recordURL(rootURL: rootURL, backupID: backupID)
    let originalBytes = try Data(contentsOf: url)
    let originalIdentity = try fileIdentity(at: url)
    try writeRestricted(originalBytes, to: url, fileManager: fileManager)
    let replacementIdentity = try fileIdentity(at: url)
    #expect(originalIdentity != replacementIdentity)
    let restartedRepository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    #expect(try await restartedRepository.admit(expected) == .existing)

    await #expect(throws: BaiduUploadReconciliationRepositoryError.invalidStoreLayout) {
      try await repository.removeOwned(lease)
    }
    #expect(try Data(contentsOf: url) == originalBytes)
  }

  @Test("A child process crash releases its inherited record lock but preserves the WAL")
  func childProcessCrashReleasesRecordLock() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let firstRepository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let secondRepository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let expected = record()
    let lease = try #require(
      (try await firstRepository.admit(expected)).createdLease
    )
    lease.release()

    let url = recordURL(rootURL: rootURL, backupID: backupID)
    var descriptor = url.path.withCString { path in
      Darwin.open(path, O_RDONLY | O_NOFOLLOW)
    }
    #expect(descriptor >= 0)
    guard descriptor >= 0 else { return }
    defer {
      if descriptor >= 0 {
        Darwin.close(descriptor)
      }
    }
    #expect(reconciliationTestFlock(descriptor, LOCK_EX | LOCK_NB) == 0)

    var processID = pid_t()
    var arguments: [UnsafeMutablePointer<CChar>?] = [
      strdup("/bin/sleep"), strdup("30"), nil,
    ]
    var environment: [UnsafeMutablePointer<CChar>?] = [nil]
    defer {
      for argument in arguments {
        free(argument)
      }
    }
    let spawnResult = arguments.withUnsafeMutableBufferPointer { argumentBuffer in
      environment.withUnsafeMutableBufferPointer { environmentBuffer in
        posix_spawn(
          &processID,
          "/bin/sleep",
          nil,
          nil,
          argumentBuffer.baseAddress,
          environmentBuffer.baseAddress
        )
      }
    }
    #expect(spawnResult == 0)
    guard spawnResult == 0 else { return }
    var childWasReaped = false
    defer {
      if !childWasReaped {
        _ = Darwin.kill(processID, SIGKILL)
        var status = Int32()
        while Darwin.waitpid(processID, &status, 0) == -1, errno == EINTR {}
      }
    }

    Darwin.close(descriptor)
    descriptor = -1
    #expect(
      try await secondRepository.admit(expected)
        == .inProgress(ownerAttemptID: expected.attemptID)
    )

    #expect(Darwin.kill(processID, SIGKILL) == 0)
    var status = Int32()
    var waitResult: pid_t
    repeat {
      waitResult = Darwin.waitpid(processID, &status, 0)
    } while waitResult == -1 && errno == EINTR
    #expect(waitResult == processID)
    childWasReaped = true
    #expect(try await secondRepository.admit(expected) == .existing)
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

    let firstLease = try #require(
      (try await repository.admit(firstRecord)).createdLease
    )
    let secondLease = try #require(
      (try await repository.admit(secondRecord)).createdLease
    )
    defer {
      firstLease.release()
      secondLease.release()
    }
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

    let ownerLease = try #require((try await repository.admit(owner)).createdLease)
    let otherLease = try #require(
      (try await repository.admit(wrongAccountRecord)).createdLease
    )
    #expect(try await repository.removeOwned(otherLease))
    otherLease.release()
    #expect(
      try await repository.load(accountScope: accountScope(), backupID: backupID) == owner
    )
    #expect(try await repository.removeOwned(ownerLease))
    ownerLease.release()
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

    #expect(admissions.allSatisfy { $0.isCreated })
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

  @Test("A legacy record appearing during a live v2 lease blocks owned removal")
  func legacyRecordBlocksLiveLeaseRemoval() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let owned = record()
    let lease = try #require((try await repository.admit(owned)).createdLease)
    defer { lease.release() }

    let directoryURL = recordURL(rootURL: rootURL, backupID: backupID)
      .deletingLastPathComponent()
    let legacyBackupID = UUID(uuidString: "B2000000-0000-0000-0000-000000000099")!
    let legacyURL = directoryURL.appendingPathComponent(
      "\(legacyBackupID.uuidString.lowercased()).json"
    )
    let legacyBytes = try legacyRecordData(backupID: legacyBackupID)
    try writeRestricted(legacyBytes, to: legacyURL, fileManager: fileManager)

    await #expect(
      throws: BaiduUploadReconciliationRepositoryError.legacyUnscopedRecordsPresent
    ) {
      try await repository.removeOwned(lease)
    }
    #expect(try Data(contentsOf: legacyURL) == legacyBytes)
    #expect(fileManager.fileExists(atPath: recordURL(rootURL: rootURL, backupID: backupID).path))
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
    #expect((try await repository.admit(record())).isCreated)
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
    #expect((try await repository.admit(expected)).isCreated)
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
    #expect((try await repository.admit(record())).isCreated)
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

  @Test("A verified commit atomically persists one strict v3 receipt across restart")
  func verifiedCommitPersistsStrictReceiptAcrossRestart() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let expected = record()
    let uploadLease = try #require(
      (try await repository.admit(expected)).createdLease
    )
    let canonicalURL = recordURL(rootURL: rootURL, backupID: backupID)
    let pendingIdentity = try fileIdentity(at: canonicalURL)
    uploadLease.release()

    let verificationLease = try #require(
      (try await repository.claimPending(
        accountScope: expected.accountScope,
        backupID: expected.backupID
      )).claimedLease
    )
    defer { verificationLease.release() }
    let receipt = try await repository.commitVerified(
      verificationLease,
      proof: proof(for: verificationLease, fsID: 9_001)
    )

    #expect(receipt.schemaVersion == 3)
    #expect(receipt.recordType == "verifiedReceipt")
    #expect(receipt.verificationVersion == 1)
    #expect(receipt.record == expected)
    #expect(receipt.remoteFSID == 9_001)
    #expect(receipt.verifiedByteCount == expected.localByteCount)
    #expect(receipt.verifiedSHA256 == expected.archiveSHA256)
    #expect(try permissions(at: canonicalURL, fileManager: fileManager) == 0o600)
    let receiptIdentity = try fileIdentity(at: canonicalURL)
    #expect(
      receiptIdentity.device != pendingIdentity.device
        || receiptIdentity.inode != pendingIdentity.inode
    )

    let persistedBytes = try Data(contentsOf: canonicalURL)
    let persistedObject = try #require(
      JSONSerialization.jsonObject(with: persistedBytes) as? [String: Any]
    )
    #expect(
      Set(persistedObject.keys)
        == Set([
          "schemaVersion", "recordType", "accountScope", "attemptID", "backupID",
          "archiveSHA256", "localMD5", "localByteCount", "requestedPath", "remoteFSID",
          "verifiedByteCount", "verifiedSHA256", "verificationVersion",
        ])
    )
    #expect(persistedObject["schemaVersion"] as? Int == 3)
    #expect(persistedObject["recordType"] as? String == "verifiedReceipt")
    #expect(persistedObject["verificationVersion"] as? Int == 1)
    let directoryEntries = try fileManager.contentsOfDirectory(
      atPath: canonicalURL.deletingLastPathComponent().path
    )
    #expect(directoryEntries == [canonicalURL.lastPathComponent])

    verificationLease.release()
    let restartedRepository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    #expect(
      try await restartedRepository.loadPending(
        accountScope: expected.accountScope,
        backupID: expected.backupID
      ) == nil
    )
    #expect(
      try await restartedRepository.loadVerifiedReceipt(
        accountScope: expected.accountScope,
        backupID: expected.backupID
      ) == receipt
    )
    let restartedAttempt = record(
      attemptID: UUID(uuidString: "A2000000-0000-0000-0000-000000000002")!
    )
    #expect(try await restartedRepository.admit(restartedAttempt) == .verified(receipt))
    #expect(
      try await restartedRepository.admit(
        record(archiveSHA256: String(repeating: "c", count: 64))
      ) == .identityConflict
    )
    #expect(
      try await restartedRepository.claimPending(
        accountScope: expected.accountScope,
        backupID: expected.backupID
      ) == .verified(receipt)
    )
    #expect(try Data(contentsOf: canonicalURL) == persistedBytes)
  }

  @Test("Post-swap recovery keeps the verified receipt authoritative without blind upload")
  func postSwapRecoveryKeepsVerifiedReceiptAuthoritative() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let expected = record()
    let uploadLease = try #require(
      (try await repository.admit(expected)).createdLease
    )
    let canonicalURL = recordURL(
      rootURL: rootURL,
      accountScope: expected.accountScope,
      backupID: expected.backupID
    )
    let pendingBytes = try Data(contentsOf: canonicalURL)
    let pendingObject = try #require(
      JSONSerialization.jsonObject(with: pendingBytes) as? [String: Any]
    )
    #expect(pendingObject["schemaVersion"] as? Int == 2)
    uploadLease.release()

    let verificationLease = try #require(
      (try await repository.claimPending(
        accountScope: expected.accountScope,
        backupID: expected.backupID
      )).claimedLease
    )
    let receipt = try await repository.commitVerified(
      verificationLease,
      proof: proof(for: verificationLease, fsID: 9_003)
    )
    verificationLease.release()
    let verifiedBytes = try Data(contentsOf: canonicalURL)
    let verifiedObject = try #require(
      JSONSerialization.jsonObject(with: verifiedBytes) as? [String: Any]
    )
    #expect(verifiedObject["schemaVersion"] as? Int == 3)
    #expect(verifiedBytes != pendingBytes)

    let temporaryURL = canonicalURL.deletingLastPathComponent().appendingPathComponent(
      ".33333333-3333-3333-3333-333333333333.tmp"
    )
    try writeRestricted(pendingBytes, to: temporaryURL, fileManager: fileManager)
    #expect(try permissions(at: temporaryURL, fileManager: fileManager) == 0o600)
    #expect(try Data(contentsOf: temporaryURL) == pendingBytes)

    let restartedRepository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    #expect(
      try await restartedRepository.loadVerifiedReceipt(
        accountScope: expected.accountScope,
        backupID: expected.backupID
      ) == receipt
    )
    #expect(!fileManager.fileExists(atPath: temporaryURL.path))
    #expect(try Data(contentsOf: canonicalURL) == verifiedBytes)
    #expect(
      try await restartedRepository.loadPending(
        accountScope: expected.accountScope,
        backupID: expected.backupID
      ) == nil
    )

    let restartedAttempt = record(
      attemptID: UUID(uuidString: "A2000000-0000-0000-0000-000000000003")!
    )
    #expect(try await restartedRepository.admit(restartedAttempt) == .verified(receipt))
    #expect(try Data(contentsOf: canonicalURL) == verifiedBytes)
  }

  @Test("Claims report missing, in-progress, and verified state across repositories")
  func claimStatesAreStableAcrossRepositories() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let firstRepository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let secondRepository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let expected = record()

    #expect(
      try await firstRepository.claimPending(
        accountScope: expected.accountScope,
        backupID: expected.backupID
      ) == .missing
    )
    let uploadLease = try #require(
      (try await firstRepository.admit(expected)).createdLease
    )
    #expect(
      try await secondRepository.claimPending(
        accountScope: expected.accountScope,
        backupID: expected.backupID
      ) == .inProgress(ownerAttemptID: expected.attemptID)
    )
    uploadLease.release()

    let verificationLease = try #require(
      (try await firstRepository.claimPending(
        accountScope: expected.accountScope,
        backupID: expected.backupID
      )).claimedLease
    )
    #expect(
      try await secondRepository.claimPending(
        accountScope: expected.accountScope,
        backupID: expected.backupID
      ) == .inProgress(ownerAttemptID: expected.attemptID)
    )
    let receipt = try await firstRepository.commitVerified(
      verificationLease,
      proof: proof(for: verificationLease, fsID: 9_002)
    )
    verificationLease.release()
    #expect(
      try await secondRepository.claimPending(
        accountScope: expected.accountScope,
        backupID: expected.backupID
      ) == .verified(receipt)
    )
  }

  @Test("Upload and verification leases mutually exclude each other")
  func uploadAndVerificationLeasesMutuallyExclude() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let uploadRepository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let verificationRepository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let expected = record()

    let uploadLease = try #require(
      (try await uploadRepository.admit(expected)).createdLease
    )
    #expect(
      try await verificationRepository.claimPending(
        accountScope: expected.accountScope,
        backupID: expected.backupID
      ) == .inProgress(ownerAttemptID: expected.attemptID)
    )
    uploadLease.release()

    let verificationLease = try #require(
      (try await verificationRepository.claimPending(
        accountScope: expected.accountScope,
        backupID: expected.backupID
      )).claimedLease
    )
    #expect(
      try await uploadRepository.admit(expected)
        == .inProgress(ownerAttemptID: expected.attemptID)
    )
    verificationLease.release()
    #expect(try await uploadRepository.admit(expected) == .existing)
  }

  @Test("Verification commit rejects foreign and released leases without changing the WAL")
  func verificationCommitRequiresIssuerBoundLiveLease() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let expected = record()
    let uploadLease = try #require(
      (try await repository.admit(expected)).createdLease
    )
    uploadLease.release()
    let canonicalURL = recordURL(rootURL: rootURL, backupID: backupID)
    let originalBytes = try Data(contentsOf: canonicalURL)
    let originalIdentity = try fileIdentity(at: canonicalURL)

    let foreignRootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: foreignRootURL) }
    let foreignRepository = BaiduUploadReconciliationRepository(rootURL: foreignRootURL)
    let foreignUploadLease = try #require(
      (try await foreignRepository.admit(expected)).createdLease
    )
    foreignUploadLease.release()
    let foreignLease = try #require(
      (try await foreignRepository.claimPending(
        accountScope: expected.accountScope,
        backupID: expected.backupID
      )).claimedLease
    )
    defer { foreignLease.release() }
    await #expect(throws: BaiduUploadReconciliationRepositoryError.invalidLease) {
      try await repository.commitVerified(
        foreignLease,
        proof: self.proof(for: foreignLease, fsID: 9_003)
      )
    }

    let localLease = try #require(
      (try await repository.claimPending(
        accountScope: expected.accountScope,
        backupID: expected.backupID
      )).claimedLease
    )
    let releasedProof = proof(for: localLease, fsID: 9_004)
    localLease.release()
    await #expect(throws: BaiduUploadReconciliationRepositoryError.invalidLease) {
      try await repository.commitVerified(localLease, proof: releasedProof)
    }
    #expect(try Data(contentsOf: canonicalURL) == originalBytes)
    let currentIdentity = try fileIdentity(at: canonicalURL)
    #expect(currentIdentity.device == originalIdentity.device)
    #expect(currentIdentity.inode == originalIdentity.inode)
  }

  @Test("A sealed proof must match every record field, challenge, digest, size, and FS ID")
  func invalidProofsPreserveExactPendingInodeAndBytes() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let expected = record()
    let uploadLease = try #require(
      (try await repository.admit(expected)).createdLease
    )
    uploadLease.release()
    let verificationLease = try #require(
      (try await repository.claimPending(
        accountScope: expected.accountScope,
        backupID: expected.backupID
      )).claimedLease
    )
    defer { verificationLease.release() }
    let canonicalURL = recordURL(rootURL: rootURL, backupID: backupID)
    let originalBytes = try Data(contentsOf: canonicalURL)
    let originalIdentity = try fileIdentity(at: canonicalURL)
    let differentBackupID = UUID(
      uuidString: "B2000000-0000-0000-0000-000000000002"
    )!
    let invalidProofs = [
      proof(
        record: expected,
        fsID: 9_005,
        verificationChallenge: UUID()
      ),
      proof(
        record: record(
          attemptID: UUID(uuidString: "A2000000-0000-0000-0000-000000000002")!
        ),
        fsID: 9_005,
        verificationChallenge: verificationLease.verificationChallenge
      ),
      proof(
        record: record(
          accountScope: accountScope(
            UUID(uuidString: "D2000000-0000-0000-0000-000000000002")!
          )
        ),
        fsID: 9_005,
        verificationChallenge: verificationLease.verificationChallenge
      ),
      proof(
        record: record(backupID: differentBackupID),
        fsID: 9_005,
        verificationChallenge: verificationLease.verificationChallenge
      ),
      proof(
        record: record(
          requestedPath: try canonicalPath(folderName: "另一个应用", backupID: backupID)
        ),
        fsID: 9_005,
        verificationChallenge: verificationLease.verificationChallenge
      ),
      proof(
        record: record(localMD5: String(repeating: "c", count: 32)),
        fsID: 9_005,
        verificationChallenge: verificationLease.verificationChallenge
      ),
      proof(
        record: record(archiveSHA256: String(repeating: "c", count: 64)),
        fsID: 9_005,
        verificationChallenge: verificationLease.verificationChallenge
      ),
      proof(
        record: record(localByteCount: expected.localByteCount + 1),
        fsID: 9_005,
        verificationChallenge: verificationLease.verificationChallenge
      ),
      proof(
        record: expected,
        fsID: 0,
        verificationChallenge: verificationLease.verificationChallenge
      ),
      proof(
        record: expected,
        fsID: 9_005,
        byteCount: expected.localByteCount + 1,
        verificationChallenge: verificationLease.verificationChallenge
      ),
      proof(
        record: expected,
        fsID: 9_005,
        sha256: String(repeating: "c", count: 64),
        verificationChallenge: verificationLease.verificationChallenge
      ),
    ]

    for invalidProof in invalidProofs {
      await #expect(throws: BaiduUploadReconciliationRepositoryError.invalidProof) {
        try await repository.commitVerified(verificationLease, proof: invalidProof)
      }
      #expect(try Data(contentsOf: canonicalURL) == originalBytes)
      let currentIdentity = try fileIdentity(at: canonicalURL)
      #expect(currentIdentity.device == originalIdentity.device)
      #expect(currentIdentity.inode == originalIdentity.inode)
    }
  }

  @Test("A proof cannot be replayed after a new verification challenge is issued")
  func proofReplayFailsAfterNewClaimChallenge() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let expected = record()
    let uploadLease = try #require(
      (try await repository.admit(expected)).createdLease
    )
    uploadLease.release()
    let firstLease = try #require(
      (try await repository.claimPending(
        accountScope: expected.accountScope,
        backupID: expected.backupID
      )).claimedLease
    )
    let replayedProof = proof(for: firstLease, fsID: 9_006)
    firstLease.release()

    let secondLease = try #require(
      (try await repository.claimPending(
        accountScope: expected.accountScope,
        backupID: expected.backupID
      )).claimedLease
    )
    defer { secondLease.release() }
    #expect(secondLease.verificationChallenge != firstLease.verificationChallenge)
    let canonicalURL = recordURL(rootURL: rootURL, backupID: backupID)
    let originalBytes = try Data(contentsOf: canonicalURL)
    let originalIdentity = try fileIdentity(at: canonicalURL)
    await #expect(throws: BaiduUploadReconciliationRepositoryError.invalidProof) {
      try await repository.commitVerified(secondLease, proof: replayedProof)
    }
    #expect(try Data(contentsOf: canonicalURL) == originalBytes)
    let currentIdentity = try fileIdentity(at: canonicalURL)
    #expect(currentIdentity.device == originalIdentity.device)
    #expect(currentIdentity.inode == originalIdentity.inode)

    let receipt = try await repository.commitVerified(
      secondLease,
      proof: proof(for: secondLease, fsID: 9_006)
    )
    #expect(receipt.remoteFSID == 9_006)
  }

  @Test("Corrupt, non-strict, and wrong-constant receipts fail closed")
  func invalidCanonicalReceiptsFailClosed() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let expected = record()
    _ = try await commitVerified(
      expected,
      fsID: 9_007,
      repository: repository
    )
    let canonicalURL = recordURL(rootURL: rootURL, backupID: backupID)
    let validBytes = try Data(contentsOf: canonicalURL)
    let validObject = try #require(
      JSONSerialization.jsonObject(with: validBytes) as? [String: Any]
    )

    try writeRestricted(Data("not-json".utf8), to: canonicalURL, fileManager: fileManager)
    await #expect(throws: BaiduUploadReconciliationRepositoryError.invalidRecord) {
      _ = try await repository.loadVerifiedReceipt(
        accountScope: expected.accountScope,
        backupID: expected.backupID
      )
    }

    var variants: [[String: Any]] = []
    var extraKey = validObject
    extraKey["unexpected"] = true
    variants.append(extraKey)
    var wrongRecordType = validObject
    wrongRecordType["recordType"] = "pending"
    variants.append(wrongRecordType)
    var wrongVerificationVersion = validObject
    wrongVerificationVersion["verificationVersion"] = 2
    variants.append(wrongVerificationVersion)

    for variant in variants {
      let data = try JSONSerialization.data(
        withJSONObject: variant,
        options: [.prettyPrinted, .sortedKeys]
      )
      try writeRestricted(data, to: canonicalURL, fileManager: fileManager)
      await #expect(throws: BaiduUploadReconciliationRepositoryError.invalidRecord) {
        _ = try await repository.loadVerifiedReceipt(
          accountScope: expected.accountScope,
          backupID: expected.backupID
        )
      }
    }

    var unsupportedSchema = validObject
    unsupportedSchema["schemaVersion"] = 4
    try writeRestricted(
      try JSONSerialization.data(
        withJSONObject: unsupportedSchema,
        options: [.prettyPrinted, .sortedKeys]
      ),
      to: canonicalURL,
      fileManager: fileManager
    )
    await #expect(
      throws: BaiduUploadReconciliationRepositoryError.unsupportedSchemaVersion(found: 4)
    ) {
      _ = try await repository.loadVerifiedReceipt(
        accountScope: expected.accountScope,
        backupID: expected.backupID
      )
    }

    try writeRestricted(validBytes, to: canonicalURL, fileManager: fileManager)
    #expect(
      try await repository.loadVerifiedReceipt(
        accountScope: expected.accountScope,
        backupID: expected.backupID
      ) != nil
    )
  }

  @Test("Insecure receipt permissions and canonical symlinks fail closed")
  func insecureCanonicalReceiptLayoutFailsClosed() async throws {
    let fileManager = FileManager.default
    let rootURL = makeRootURL(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: rootURL) }
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let expected = record()
    _ = try await commitVerified(
      expected,
      fsID: 9_008,
      repository: repository
    )
    let canonicalURL = recordURL(rootURL: rootURL, backupID: backupID)
    let validBytes = try Data(contentsOf: canonicalURL)

    try fileManager.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: canonicalURL.path
    )
    await #expect(throws: BaiduUploadReconciliationRepositoryError.invalidStoreLayout) {
      _ = try await repository.loadVerifiedReceipt(
        accountScope: expected.accountScope,
        backupID: expected.backupID
      )
    }

    try fileManager.removeItem(at: canonicalURL)
    let victimURL = rootURL.appendingPathComponent("receipt-victim.json")
    try writeRestricted(validBytes, to: victimURL, fileManager: fileManager)
    try fileManager.createSymbolicLink(at: canonicalURL, withDestinationURL: victimURL)
    await #expect(throws: BaiduUploadReconciliationRepositoryError.invalidStoreLayout) {
      _ = try await repository.loadVerifiedReceipt(
        accountScope: expected.accountScope,
        backupID: expected.backupID
      )
    }
    #expect(try Data(contentsOf: victimURL) == validBytes)
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

  private func fileIdentity(at url: URL) throws -> (device: dev_t, inode: ino_t) {
    var status = stat()
    guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0 else {
      throw CocoaError(.fileReadUnknown)
    }
    return (status.st_dev, status.st_ino)
  }

  private func proof(
    for lease: BaiduUploadReconciliationVerificationLease,
    fsID: UInt64
  ) -> BaiduVerifiedRemoteBackupContentProof {
    proof(
      record: lease.record,
      fsID: fsID,
      verificationChallenge: lease.verificationChallenge
    )
  }

  private func proof(
    record: BaiduUploadReconciliationRecord,
    fsID: UInt64,
    byteCount: UInt64? = nil,
    sha256: String? = nil,
    verificationChallenge: UUID
  ) -> BaiduVerifiedRemoteBackupContentProof {
    .testingOnly(
      record: record,
      fsID: fsID,
      byteCount: byteCount ?? record.localByteCount,
      sha256: sha256 ?? record.archiveSHA256,
      verificationChallenge: verificationChallenge
    )
  }

  private func commitVerified(
    _ record: BaiduUploadReconciliationRecord,
    fsID: UInt64,
    repository: BaiduUploadReconciliationRepository
  ) async throws -> BaiduVerifiedRemoteBackupReceipt {
    let uploadLease = try #require(
      (try await repository.admit(record)).createdLease
    )
    uploadLease.release()
    let verificationLease = try #require(
      (try await repository.claimPending(
        accountScope: record.accountScope,
        backupID: record.backupID
      )).claimedLease
    )
    defer { verificationLease.release() }
    return try await repository.commitVerified(
      verificationLease,
      proof: proof(for: verificationLease, fsID: fsID)
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

private final class ReconciliationRecursiveRemovalTrapFileManager: FileManager,
  @unchecked Sendable
{
  private let stateLock = NSLock()
  private var armedRecordURL: URL?
  private var armedVictimURL: URL?

  func arm(recordURL: URL, victimURL: URL) {
    stateLock.withLock {
      armedRecordURL = recordURL
      armedVictimURL = victimURL
    }
  }

  override func removeItem(at URL: URL) throws {
    let victimURL = stateLock.withLock { () -> URL? in
      guard URL == armedRecordURL else { return nil }
      return armedVictimURL
    }
    guard let victimURL else {
      try super.removeItem(at: URL)
      return
    }

    try FileManager.default.removeItem(at: URL)
    try FileManager.default.moveItem(at: victimURL, to: URL)
    try super.removeItem(at: URL)
  }
}
