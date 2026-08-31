import CryptoKit
import Foundation
import Testing

@testable import InkNotesCore

@Suite("Baidu remote backup reconciliation authority")
struct BaiduRemoteBackupReconciliationAuthorityTests {
  private let fsID: UInt64 = 91_001

  @Test("An exact full-byte proof atomically replaces pending v2 with a durable v3 receipt")
  func exactProofCommitsDurableReceipt() async throws {
    let rootURL = temporaryRootURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let archive = Data((0..<4_097).map { UInt8($0 % 251) })
    let record = try makeRecord(archive: archive)
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    try await installUnlockedPending(record, in: repository)
    let metadataTransport = ScriptedBaiduHTTPTransport(handlers: [
      { _ in try Self.metadataResponse(record: record, fsID: self.fsID) }
    ])
    let byteStreamer = ScriptedBaiduRemoteBackupByteStreamer(handlers: [
      { _, _ in
        BaiduStreamedDownloadDigest(
          byteCount: UInt64(archive.count),
          sha256: Self.sha256Hex(archive)
        )
      }
    ])
    let authority = makeAuthority(
      repository: repository,
      metadataTransport: metadataTransport,
      byteStreamer: byteStreamer
    )

    let outcome = await authority.reconcile(
      backupID: record.backupID,
      fsID: fsID,
      credential: try credential(scope: record.accountScope)
    )
    guard case .reconciled(let receipt) = outcome else {
      Issue.record("Expected an exact proof to commit a verified receipt, got \(outcome)")
      return
    }

    #expect(receipt.record == record)
    #expect(receipt.schemaVersion == BaiduVerifiedRemoteBackupReceipt.currentSchemaVersion)
    #expect(receipt.remoteFSID == fsID)
    #expect(receipt.verifiedByteCount == record.localByteCount)
    #expect(receipt.verifiedSHA256 == record.archiveSHA256)
    #expect(await metadataTransport.requestCount() == 1)
    #expect(await byteStreamer.requestCount() == 1)

    let restartedRepository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    #expect(
      try await restartedRepository.loadVerifiedReceipt(
        accountScope: record.accountScope,
        backupID: record.backupID
      ) == receipt
    )
    #expect(
      try await restartedRepository.loadPending(
        accountScope: record.accountScope,
        backupID: record.backupID
      ) == nil
    )
    #expect(
      try await restartedRepository.load(
        accountScope: record.accountScope,
        backupID: record.backupID
      ) == nil
    )

    let receiptURL =
      rootURL
      .appendingPathComponent(
        BaiduUploadReconciliationRepository.reconciliationDirectoryName,
        isDirectory: true
      )
      .appendingPathComponent(
        BaiduUploadReconciliationRepository.recordFilename(
          accountScope: record.accountScope,
          backupID: record.backupID
        )
      )
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any]
    )
    #expect(object["schemaVersion"] as? Int == 3)
    #expect(object["recordType"] as? String == "verifiedReceipt")
  }

  @Test("A receipt is authoritative for the same fs_id and conflicts with another fs_id")
  func receiptShortCircuitsWithoutNetwork() async throws {
    let rootURL = temporaryRootURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let archive = Data(repeating: 0x41, count: 1_024)
    let record = try makeRecord(archive: archive)
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let credential = try credential(scope: record.accountScope)
    let receipt = try await installAndReconcileExact(
      record: record,
      archive: archive,
      fsID: fsID,
      credential: credential,
      repository: repository
    )
    let metadataTransport = ScriptedBaiduHTTPTransport(handlers: [])
    let byteStreamer = ScriptedBaiduRemoteBackupByteStreamer(handlers: [])
    let restartedAuthority = makeAuthority(
      repository: BaiduUploadReconciliationRepository(rootURL: rootURL),
      metadataTransport: metadataTransport,
      byteStreamer: byteStreamer
    )

    #expect(
      await restartedAuthority.reconcile(
        backupID: record.backupID,
        fsID: fsID,
        credential: credential
      ) == .alreadyVerified(receipt)
    )
    #expect(
      await restartedAuthority.reconcile(
        backupID: record.backupID,
        fsID: fsID + 1,
        credential: credential
      ) == .failed(.verifiedReceiptConflict)
    )
    #expect(await metadataTransport.requestCount() == 0)
    #expect(await byteStreamer.requestCount() == 0)
  }

  @Test("A full-content mismatch preserves the pending record")
  func mismatchPreservesPending() async throws {
    let rootURL = temporaryRootURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let archive = Data(repeating: 0x42, count: 1_536)
    let record = try makeRecord(archive: archive)
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    try await installUnlockedPending(record, in: repository)
    let metadataTransport = ScriptedBaiduHTTPTransport(handlers: [
      { _ in
        try Self.metadataResponse(
          record: record,
          fsID: self.fsID,
          byteCount: record.localByteCount + 1
        )
      }
    ])
    let byteStreamer = ScriptedBaiduRemoteBackupByteStreamer(handlers: [])
    let authority = makeAuthority(
      repository: repository,
      metadataTransport: metadataTransport,
      byteStreamer: byteStreamer
    )

    #expect(
      await authority.reconcile(
        backupID: record.backupID,
        fsID: fsID,
        credential: try credential(scope: record.accountScope)
      )
        == .contentMismatch(
          .byteCount(expected: record.localByteCount, actual: record.localByteCount + 1)
        )
    )
    #expect(try await loadPending(record, from: repository))
    #expect(await metadataTransport.requestCount() == 1)
    #expect(await byteStreamer.requestCount() == 0)
  }

  @Test("An expired credential sends no request and preserves pending")
  func expiredCredentialPreservesPending() async throws {
    let rootURL = temporaryRootURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let archive = Data(repeating: 0x43, count: 768)
    let record = try makeRecord(archive: archive)
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    try await installUnlockedPending(record, in: repository)
    let now = Date(timeIntervalSinceReferenceDate: 9_000_000)
    let metadataTransport = ScriptedBaiduHTTPTransport(handlers: [])
    let byteStreamer = ScriptedBaiduRemoteBackupByteStreamer(handlers: [])
    let authority = makeAuthority(
      repository: repository,
      metadataTransport: metadataTransport,
      byteStreamer: byteStreamer,
      now: { now }
    )
    let expiringCredential = try credential(
      scope: record.accountScope,
      expiresAt: now.addingTimeInterval(
        BaiduCredentialUsePolicy.minimumRequestRemainingLifetime
      )
    )

    #expect(
      await authority.reconcile(
        backupID: record.backupID,
        fsID: fsID,
        credential: expiringCredential
      ) == .failed(.verification(.credential(.unavailableForRequest)))
    )
    #expect(try await loadPending(record, from: repository))
    #expect(await metadataTransport.requestCount() == 0)
    #expect(await byteStreamer.requestCount() == 0)
  }

  @Test("Cancellation before authority entry preserves pending and sends no request")
  func cancellationBeforeEntryPreservesPending() async throws {
    let rootURL = temporaryRootURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let archive = Data(repeating: 0x44, count: 512)
    let record = try makeRecord(archive: archive)
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    try await installUnlockedPending(record, in: repository)
    let metadataTransport = ScriptedBaiduHTTPTransport(handlers: [])
    let byteStreamer = ScriptedBaiduRemoteBackupByteStreamer(handlers: [])
    let authority = makeAuthority(
      repository: repository,
      metadataTransport: metadataTransport,
      byteStreamer: byteStreamer
    )
    let credential = try credential(scope: record.accountScope)
    let task = Task {
      while !Task.isCancelled {
        await Task.yield()
      }
      return await authority.reconcile(
        backupID: record.backupID,
        fsID: self.fsID,
        credential: credential
      )
    }
    task.cancel()

    #expect(await task.value == .cancelled)
    #expect(try await loadPending(record, from: repository))
    #expect(await metadataTransport.requestCount() == 0)
    #expect(await byteStreamer.requestCount() == 0)
  }

  @Test("Cancellation during verification preserves pending and releases the claim")
  func cancellationDuringVerificationPreservesPendingAndReleasesClaim() async throws {
    let rootURL = temporaryRootURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let archive = Data(repeating: 0x48, count: 1_280)
    let record = try makeRecord(archive: archive)
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    try await installUnlockedPending(record, in: repository)
    let gate = AuthorityTestGate()
    let metadataTransport = ScriptedBaiduHTTPTransport(handlers: [
      { _ in
        await gate.wait()
        return try Self.metadataResponse(record: record, fsID: self.fsID)
      }
    ])
    let byteStreamer = ScriptedBaiduRemoteBackupByteStreamer(handlers: [
      { _, _ in
        BaiduStreamedDownloadDigest(
          byteCount: UInt64(archive.count),
          sha256: Self.sha256Hex(archive)
        )
      }
    ])
    let authority = makeAuthority(
      repository: repository,
      metadataTransport: metadataTransport,
      byteStreamer: byteStreamer
    )
    let credential = try credential(scope: record.accountScope)
    let task = Task {
      await authority.reconcile(
        backupID: record.backupID,
        fsID: self.fsID,
        credential: credential
      )
    }

    do {
      try await waitForRequestCount(1, transport: metadataTransport)
    } catch {
      await gate.open()
      task.cancel()
      _ = await task.value
      throw error
    }
    task.cancel()
    await gate.open()

    #expect(await task.value == .cancelled)
    #expect(try await loadPending(record, from: repository))
    #expect(await metadataTransport.requestCount() == 1)
    #expect(await byteStreamer.requestCount() == 0)

    let restartedRepository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let claim = try await restartedRepository.claimPending(
      accountScope: record.accountScope,
      backupID: record.backupID
    )
    guard case .claimed(let lease) = claim else {
      Issue.record("Expected cancellation to release the verification claim, got \(claim)")
      return
    }
    lease.release()
  }

  @Test("A post-proof persistence failure is reported as outcome unknown")
  func postProofPersistenceFailureIsOutcomeUnknown() async throws {
    let rootURL = temporaryRootURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let archive = Data(repeating: 0x49, count: 1_408)
    let record = try makeRecord(archive: archive)
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    try await installUnlockedPending(record, in: repository)
    let reconciliationURL = rootURL.appendingPathComponent(
      BaiduUploadReconciliationRepository.reconciliationDirectoryName,
      isDirectory: true
    )
    let gate = AuthorityTestGate()
    let metadataTransport = ScriptedBaiduHTTPTransport(handlers: [
      { _ in
        await gate.wait()
        return try Self.metadataResponse(record: record, fsID: self.fsID)
      }
    ])
    let byteStreamer = ScriptedBaiduRemoteBackupByteStreamer(handlers: [
      { _, _ in
        BaiduStreamedDownloadDigest(
          byteCount: UInt64(archive.count),
          sha256: Self.sha256Hex(archive)
        )
      }
    ])
    let authority = makeAuthority(
      repository: repository,
      metadataTransport: metadataTransport,
      byteStreamer: byteStreamer
    )
    let credential = try credential(scope: record.accountScope)
    let task = Task {
      await authority.reconcile(
        backupID: record.backupID,
        fsID: self.fsID,
        credential: credential
      )
    }

    do {
      try await waitForRequestCount(1, transport: metadataTransport)
    } catch {
      await gate.open()
      task.cancel()
      _ = await task.value
      throw error
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: reconciliationURL.path
    )
    await gate.open()

    let outcome = await task.value
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: reconciliationURL.path
    )
    #expect(outcome == .commitOutcomeUnknown)
    #expect(try await loadPending(record, from: repository))
    #expect(await metadataTransport.requestCount() == 1)
    #expect(await byteStreamer.requestCount() == 1)
  }

  @Test("A live upload lease returns in-progress before any verification request")
  func activeUploadLeaseBlocksAuthority() async throws {
    let rootURL = temporaryRootURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let archive = Data(repeating: 0x45, count: 640)
    let record = try makeRecord(archive: archive)
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let admission = try await repository.admit(record)
    let uploadLease = try #require(admission.createdLease)
    defer { uploadLease.release() }
    let metadataTransport = ScriptedBaiduHTTPTransport(handlers: [])
    let byteStreamer = ScriptedBaiduRemoteBackupByteStreamer(handlers: [])
    let authority = makeAuthority(
      repository: BaiduUploadReconciliationRepository(rootURL: rootURL),
      metadataTransport: metadataTransport,
      byteStreamer: byteStreamer
    )

    #expect(
      await authority.reconcile(
        backupID: record.backupID,
        fsID: fsID,
        credential: try credential(scope: record.accountScope)
      ) == .inProgress(ownerAttemptID: record.attemptID)
    )
    #expect(await metadataTransport.requestCount() == 0)
    #expect(await byteStreamer.requestCount() == 0)
  }

  @Test("Concurrent authorities perform at most one network proof and one commit")
  func concurrentAuthoritiesAreSingleFlightAcrossRepositories() async throws {
    let rootURL = temporaryRootURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let archive = Data(repeating: 0x46, count: 2_048)
    let record = try makeRecord(archive: archive)
    let firstRepository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let secondRepository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    try await installUnlockedPending(record, in: firstRepository)
    let gate = AuthorityTestGate()
    let metadataTransport = ScriptedBaiduHTTPTransport(handlers: [
      { _ in
        await gate.wait()
        return try Self.metadataResponse(record: record, fsID: self.fsID)
      }
    ])
    let byteStreamer = ScriptedBaiduRemoteBackupByteStreamer(handlers: [
      { _, _ in
        BaiduStreamedDownloadDigest(
          byteCount: UInt64(archive.count),
          sha256: Self.sha256Hex(archive)
        )
      }
    ])
    let firstAuthority = makeAuthority(
      repository: firstRepository,
      metadataTransport: metadataTransport,
      byteStreamer: byteStreamer
    )
    let secondAuthority = makeAuthority(
      repository: secondRepository,
      metadataTransport: metadataTransport,
      byteStreamer: byteStreamer
    )
    let credential = try credential(scope: record.accountScope)
    let firstTask = Task {
      await firstAuthority.reconcile(
        backupID: record.backupID,
        fsID: self.fsID,
        credential: credential
      )
    }

    do {
      try await waitForRequestCount(1, transport: metadataTransport)
    } catch {
      await gate.open()
      firstTask.cancel()
      _ = await firstTask.value
      throw error
    }

    #expect(
      await secondAuthority.reconcile(
        backupID: record.backupID,
        fsID: fsID,
        credential: credential
      ) == .inProgress(ownerAttemptID: record.attemptID)
    )
    await gate.open()
    guard case .reconciled(let receipt) = await firstTask.value else {
      Issue.record("Expected the lock owner to commit the only receipt")
      return
    }

    #expect(await metadataTransport.requestCount() == 1)
    #expect(await byteStreamer.requestCount() == 1)
    #expect(
      try await secondRepository.loadVerifiedReceipt(
        accountScope: record.accountScope,
        backupID: record.backupID
      ) == receipt
    )
    #expect(try await loadPending(record, from: secondRepository) == false)
  }

  @Test("A verified receipt makes a new upload coordinator return without invoking uploader")
  func verifiedReceiptShortCircuitsUploadCoordinator() async throws {
    let rootURL = temporaryRootURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let backupID = UUID()
    let archive = try makeArchive(backupID: backupID)
    let directory = try BaiduNetdiskAppDirectory(folderName: "测试应用")
    let record = try makeRecord(
      archive: archive,
      backupID: backupID,
      requestedPath: directory.backupPath(backupID: backupID)
    )
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    let credential = try credential(scope: record.accountScope)
    let receipt = try await installAndReconcileExact(
      record: record,
      archive: archive,
      fsID: fsID,
      credential: credential,
      repository: repository
    )
    let uploader = AuthorityNeverUploader()
    let coordinator = BaiduBackupUploadCoordinator(
      uploader: uploader,
      reconciliationStore: BaiduUploadReconciliationRepository(rootURL: rootURL)
    )

    #expect(
      await coordinator.upload(
        archive: archive,
        credential: credential,
        applicationDirectory: directory
      ) == .remoteContentVerified(receipt)
    )
    #expect(await uploader.invocationCount() == 0)
  }

  @Test("Authority outcomes never render the access token")
  func outcomeRedactsAccessToken() async throws {
    let rootURL = temporaryRootURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let archive = Data(repeating: 0x47, count: 896)
    let record = try makeRecord(archive: archive)
    let repository = BaiduUploadReconciliationRepository(rootURL: rootURL)
    try await installUnlockedPending(record, in: repository)
    let secret = "authority.secret-token+value%25"
    let metadataTransport = ScriptedBaiduHTTPTransport(handlers: [
      { _ in throw URLError(.notConnectedToInternet) }
    ])
    let authority = makeAuthority(
      repository: repository,
      metadataTransport: metadataTransport,
      byteStreamer: ScriptedBaiduRemoteBackupByteStreamer(handlers: [])
    )

    let outcome = await authority.reconcile(
      backupID: record.backupID,
      fsID: fsID,
      credential: try credential(scope: record.accountScope, token: secret)
    )
    #expect(outcome == .failed(.verification(.metadataTransport)))
    let rendered = String(describing: outcome) + String(reflecting: outcome)
    #expect(!rendered.contains(secret))
    #expect(!rendered.contains("access_token"))
    #expect(try await loadPending(record, from: repository))
  }

  private func installAndReconcileExact(
    record: BaiduUploadReconciliationRecord,
    archive: Data,
    fsID: UInt64,
    credential: BaiduAccountBoundCredential,
    repository: BaiduUploadReconciliationRepository
  ) async throws -> BaiduVerifiedRemoteBackupReceipt {
    try await installUnlockedPending(record, in: repository)
    let authority = makeAuthority(
      repository: repository,
      metadataTransport: ScriptedBaiduHTTPTransport(handlers: [
        { _ in try Self.metadataResponse(record: record, fsID: fsID) }
      ]),
      byteStreamer: ScriptedBaiduRemoteBackupByteStreamer(handlers: [
        { _, _ in
          BaiduStreamedDownloadDigest(
            byteCount: UInt64(archive.count),
            sha256: Self.sha256Hex(archive)
          )
        }
      ])
    )
    let outcome = await authority.reconcile(
      backupID: record.backupID,
      fsID: fsID,
      credential: credential
    )
    guard case .reconciled(let receipt) = outcome else {
      throw AuthorityTestError.unexpectedOutcome
    }
    return receipt
  }

  private func installUnlockedPending(
    _ record: BaiduUploadReconciliationRecord,
    in repository: BaiduUploadReconciliationRepository
  ) async throws {
    let admission = try await repository.admit(record)
    guard case .created(let lease) = admission else {
      throw AuthorityTestError.unexpectedAdmission
    }
    lease.release()
  }

  private func loadPending(
    _ record: BaiduUploadReconciliationRecord,
    from repository: BaiduUploadReconciliationRepository
  ) async throws -> Bool {
    try await repository.loadPending(
      accountScope: record.accountScope,
      backupID: record.backupID
    ) == record
  }

  private func makeAuthority(
    repository: BaiduUploadReconciliationRepository,
    metadataTransport: ScriptedBaiduHTTPTransport,
    byteStreamer: ScriptedBaiduRemoteBackupByteStreamer,
    now: @escaping @Sendable () -> Date = { Date() }
  ) -> BaiduRemoteBackupReconciliationAuthority {
    BaiduRemoteBackupReconciliationAuthority(
      repository: repository,
      verifier: BaiduRemoteBackupContentVerifier(
        metadataTransport: metadataTransport,
        byteStreamer: byteStreamer,
        now: now
      )
    )
  }

  private func makeRecord(
    archive: Data,
    backupID: UUID = UUID(),
    requestedPath: String? = nil
  ) throws -> BaiduUploadReconciliationRecord {
    let scope = try BaiduAccountScope(brokerBindingID: UUID())
    let directory = try BaiduNetdiskAppDirectory(folderName: "测试应用")
    return BaiduUploadReconciliationRecord(
      accountScope: scope,
      attemptID: UUID(),
      backupID: backupID,
      archiveSHA256: Self.sha256Hex(archive),
      localMD5: BaiduNetdiskBackupUploader.md5Hex(archive),
      localByteCount: UInt64(archive.count),
      requestedPath: requestedPath ?? directory.backupPath(backupID: backupID)
    )
  }

  private func credential(
    scope: BaiduAccountScope,
    token: String = "authority.test-access-token",
    expiresAt: Date = .distantFuture
  ) throws -> BaiduAccountBoundCredential {
    try BaiduAccountBoundCredential.testingOnly(
      accountScope: scope,
      accessToken: BaiduAccessToken(token),
      expiresAt: expiresAt
    )
  }

  private func makeArchive(backupID: UUID) throws -> Data {
    let library = LibraryDocument.starter()
    let drawings = Dictionary(
      uniqueKeysWithValues: library.notebooks.flatMap(\.pages).map { ($0.id, Data()) }
    )
    return try BackupArchiveCodec.encode(
      library: library,
      drawings: drawings,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      backupID: backupID,
      sourceAppVersion: "0.2.0",
      sourceBuild: "authority-test"
    )
  }

  private func temporaryRootURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "InkNotes-authority-\(UUID().uuidString)",
      isDirectory: true
    )
  }

  private func waitForRequestCount(
    _ expected: Int,
    transport: ScriptedBaiduHTTPTransport
  ) async throws {
    for _ in 0..<200 {
      if await transport.requestCount() == expected {
        return
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw AuthorityTestError.timedOut
  }

  private static func metadataResponse(
    record: BaiduUploadReconciliationRecord,
    fsID: UInt64,
    byteCount: UInt64? = nil
  ) throws -> BaiduHTTPResponse {
    let file: [String: Any] = [
      "fs_id": fsID,
      "path": record.requestedPath,
      "filename": BaiduNetdiskAppDirectory.backupFilename(backupID: record.backupID),
      "size": byteCount ?? record.localByteCount,
      "isdir": 0,
      "dlink": "https://d.pcs.baidu.com/file/authority-proof?sign=signed",
    ]
    return BaiduHTTPResponse(
      statusCode: 200,
      headers: [:],
      body: try JSONSerialization.data(
        withJSONObject: ["errno": 0, "list": [file]],
        options: [.sortedKeys]
      )
    )
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private enum AuthorityTestError: Error {
  case timedOut
  case unexpectedAdmission
  case unexpectedOutcome
  case unexpectedUpload
}

private actor AuthorityTestGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open() {
    guard !isOpen else { return }
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for continuation in pending {
      continuation.resume()
    }
  }
}

private actor AuthorityNeverUploader: BaiduBackupUploading {
  private var invocations = 0

  func upload(
    archive _: Data,
    accessToken _: BaiduAccessToken,
    applicationDirectory _: BaiduNetdiskAppDirectory,
    progress _: @escaping @Sendable (BaiduBackupUploadProgress) async throws -> Void
  ) async throws -> BaiduBackupUploadOutcome {
    invocations += 1
    throw AuthorityTestError.unexpectedUpload
  }

  func invocationCount() -> Int {
    invocations
  }
}
