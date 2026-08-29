import Foundation
import Testing

@testable import InkNotesCore

@Suite("Baidu backup upload coordination")
struct BaiduBackupUploadCoordinatorTests {
  @Test("A caller cancelled before entry never invokes the uploader")
  func cancelledCallerDoesNotStartWorker() async throws {
    let archive = try makeArchive(backupID: UUID())
    let directory = try applicationDirectory()
    let token = try accessToken()
    let uploader = ScriptedCoordinatorUploader(handlers: [
      suspendingBeforeCreateHandler()
    ])
    let coordinator = BaiduBackupUploadCoordinator(uploader: uploader)

    let task = Task {
      while !Task.isCancelled {
        await Task.yield()
      }
      return await coordinator.upload(
        archive: archive,
        accessToken: token,
        applicationDirectory: directory
      )
    }
    task.cancel()

    #expect(await task.value == .cancelled(.caller))
    #expect(await uploader.invocationCount() == 0)
    #expect(await coordinator.snapshot().phase == .idle)
  }

  @Test("A second upload is rejected before invoking the uploader")
  func singleFlightRejectsConcurrentUpload() async throws {
    let backupID = UUID(uuidString: "C1000000-0000-0000-0000-000000000001")!
    let archive = try makeArchive(backupID: backupID)
    let directory = try applicationDirectory()
    let token = try accessToken()
    let receipt = makeReceipt(archive: archive, backupID: backupID, directory: directory)
    let remote = makeRemote(receipt: receipt)
    let uploader = ScriptedCoordinatorUploader(handlers: [
      suspendingBeforeCreateHandler(),
      verifiedHandler(remote: remote),
    ])
    let coordinator = BaiduBackupUploadCoordinator(uploader: uploader)

    let first = Task {
      await coordinator.upload(
        archive: archive,
        accessToken: token,
        applicationDirectory: directory
      )
    }
    try await waitForPhase(.precreateDispatchPermitted, coordinator: coordinator)
    let firstSnapshot = await coordinator.snapshot()

    let concurrent = await coordinator.upload(
      archive: archive,
      accessToken: token,
      applicationDirectory: directory
    )
    guard case .rejected(.alreadyRunning(let operationID)) = concurrent else {
      Issue.record("Expected a single-flight rejection")
      _ = await coordinator.cancelActiveUpload()
      _ = await first.value
      return
    }
    #expect(operationID == firstSnapshot.operationID)
    #expect(await uploader.invocationCount() == 1)

    _ = await coordinator.cancelActiveUpload()
    #expect(await first.value == .cancelled(.explicit))

    let retry = await coordinator.upload(
      archive: archive,
      accessToken: token,
      applicationDirectory: directory
    )
    #expect(retry == .verifiedRemote(remote))
    #expect(await uploader.invocationCount() == 2)
  }

  @Test("Caller and background cancellation sources are preserved before create")
  func cancellationSourcesBeforeCreate() async throws {
    for source in [
      BaiduBackupUploadCancellationSource.caller,
      .background,
    ] {
      let backupID = UUID()
      let archive = try makeArchive(backupID: backupID)
      let directory = try applicationDirectory()
      let token = try accessToken()
      let uploader = ScriptedCoordinatorUploader(handlers: [
        suspendingBeforeCreateHandler()
      ])
      let coordinator = BaiduBackupUploadCoordinator(uploader: uploader)
      let task = Task {
        await coordinator.upload(
          archive: archive,
          accessToken: token,
          applicationDirectory: directory
        )
      }
      try await waitForPhase(.precreateDispatchPermitted, coordinator: coordinator)

      if source == .caller {
        task.cancel()
      } else {
        _ = await coordinator.cancelForBackgroundTransition()
      }

      #expect(await task.value == .cancelled(source))
      #expect(await coordinator.snapshot().phase == .idle)
    }
  }

  @Test("A cancellation recorded before create prevents its dispatch checkpoint")
  func cancellationWinsCreateCheckpointRace() async throws {
    let backupID = UUID(uuidString: "C1000000-0000-0000-0000-000000000002")!
    let archive = try makeArchive(backupID: backupID)
    let directory = try applicationDirectory()
    let token = try accessToken()
    let uploader = ScriptedCoordinatorUploader(handlers: [
      createCheckpointAfterCancellationHandler()
    ])
    let coordinator = BaiduBackupUploadCoordinator(uploader: uploader)
    let task = Task {
      await coordinator.upload(
        archive: archive,
        accessToken: token,
        applicationDirectory: directory
      )
    }
    try await waitForPhase(.precreateDispatchPermitted, coordinator: coordinator)

    _ = await coordinator.cancelActiveUpload()

    #expect(await task.value == .cancelled(.explicit))
    #expect(await coordinator.snapshot().phase == .idle)
  }

  @Test("A cancellation after create is an unknown remote outcome and blocks retry")
  func cancellationAfterCreateRequiresVerification() async throws {
    let backupID = UUID(uuidString: "C1000000-0000-0000-0000-000000000003")!
    let archive = try makeArchive(backupID: backupID)
    let directory = try applicationDirectory()
    let token = try accessToken()
    let receipt = makeReceipt(archive: archive, backupID: backupID, directory: directory)
    let uploader = ScriptedCoordinatorUploader(handlers: [
      suspendingAfterCreateHandler()
    ])
    let coordinator = BaiduBackupUploadCoordinator(uploader: uploader)
    let task = Task {
      await coordinator.upload(
        archive: archive,
        accessToken: token,
        applicationDirectory: directory
      )
    }
    try await waitForPhase(.createDispatchPermitted, coordinator: coordinator)

    _ = await coordinator.cancelActiveUpload()

    #expect(
      await task.value
        == .outcomeUnknown(receipt: receipt, reason: .cancelled(.explicit))
    )
    #expect(
      await coordinator.upload(
        archive: archive,
        accessToken: token,
        applicationDirectory: directory
      )
        == .rejected(.remoteVerificationRequired(backupID: backupID))
    )
    #expect(await uploader.invocationCount() == 1)
  }

  @Test("A validated success wins over late cancellation and keeps the slot busy until finish")
  func validatedSuccessWinsLateCancellation() async throws {
    let backupID = UUID(uuidString: "C1000000-0000-0000-0000-000000000008")!
    let archive = try makeArchive(backupID: backupID)
    let directory = try applicationDirectory()
    let token = try accessToken()
    let receipt = makeReceipt(archive: archive, backupID: backupID, directory: directory)
    let remote = makeRemote(receipt: receipt)
    let gate = CoordinatorTestGate()
    let uploader = ScriptedCoordinatorUploader(handlers: [
      validatedSuccessAfterGateHandler(remote: remote, gate: gate)
    ])
    let coordinator = BaiduBackupUploadCoordinator(uploader: uploader)
    let task = Task {
      await coordinator.upload(
        archive: archive,
        accessToken: token,
        applicationDirectory: directory
      )
    }
    try await waitForPhase(.createDispatchPermitted, coordinator: coordinator)
    let operationID = try #require(await coordinator.snapshot().operationID)

    #expect(await coordinator.cancel(operationID: operationID))
    #expect(
      await coordinator.upload(
        archive: archive,
        accessToken: token,
        applicationDirectory: directory
      ) == .rejected(.alreadyRunning(operationID: operationID))
    )

    await gate.open()

    #expect(await task.value == .verifiedRemote(remote))
    #expect(await coordinator.snapshot().phase == .idle)
    #expect(await uploader.invocationCount() == 1)
  }

  @Test("Post-create response failures stay unknown and never auto-retry")
  func createResponseFailuresRequireVerification() async throws {
    let token = try accessToken()
    let cases: [(BaiduNetdiskUploadError, BaiduBackupUploadUnknownReason)] = [
      (.transport(.create), .responseUnavailable),
      (.malformedResponse(.create), .unverifiedResponse),
      (.committedDigestMismatch, .unverifiedResponse),
    ]

    for (error, reason) in cases {
      let backupID = UUID()
      let archive = try makeArchive(backupID: backupID)
      let directory = try applicationDirectory()
      let receipt = makeReceipt(archive: archive, backupID: backupID, directory: directory)
      let uploader = ScriptedCoordinatorUploader(handlers: [
        failureAfterCreateHandler(error: error)
      ])
      let coordinator = BaiduBackupUploadCoordinator(uploader: uploader)

      let outcome = await coordinator.upload(
        archive: archive,
        accessToken: token,
        applicationDirectory: directory
      )

      #expect(outcome == .outcomeUnknown(receipt: receipt, reason: reason))
      #expect(
        await coordinator.upload(
          archive: archive,
          accessToken: token,
          applicationDirectory: directory
        )
          == .rejected(.remoteVerificationRequired(backupID: backupID))
      )
      #expect(await uploader.invocationCount() == 1)
    }
  }

  @Test("An explicit create API rejection remains retryable")
  func explicitCreateRejectionCanRetry() async throws {
    let backupID = UUID(uuidString: "C1000000-0000-0000-0000-000000000004")!
    let archive = try makeArchive(backupID: backupID)
    let directory = try applicationDirectory()
    let token = try accessToken()
    let error = BaiduNetdiskUploadError.api(stage: .create, code: 31061)
    let uploader = ScriptedCoordinatorUploader(handlers: [
      failureAfterCreateHandler(error: error),
      failureAfterCreateHandler(error: error),
    ])
    let coordinator = BaiduBackupUploadCoordinator(uploader: uploader)

    for _ in 0..<2 {
      #expect(
        await coordinator.upload(
          archive: archive,
          accessToken: token,
          applicationDirectory: directory
        )
          == .failed(.upload(error))
      )
    }
    #expect(await uploader.invocationCount() == 2)
  }

  @Test("Rapid upload needs verification while a matched create is verified")
  func successOutcomesInstallSessionBarriers() async throws {
    let directory = try applicationDirectory()

    let rapidBackupID = UUID(uuidString: "C1000000-0000-0000-0000-000000000005")!
    let rapidArchive = try makeArchive(backupID: rapidBackupID)
    let rapidReceipt = makeReceipt(
      archive: rapidArchive,
      backupID: rapidBackupID,
      directory: directory
    )
    let rapidUploader = ScriptedCoordinatorUploader(handlers: [
      rapidHandler(receipt: rapidReceipt)
    ])
    let rapidCoordinator = BaiduBackupUploadCoordinator(uploader: rapidUploader)
    let expectedRapidReceipt = BaiduRapidUploadReceipt(
      backupID: rapidReceipt.backupID,
      requestedPath: rapidReceipt.requestedPath,
      localByteCount: rapidReceipt.localByteCount,
      localMD5: rapidReceipt.localMD5
    )

    #expect(
      await rapidCoordinator.upload(
        archive: rapidArchive,
        accessToken: try accessToken(),
        applicationDirectory: directory
      ) == .needsRemoteVerification(expectedRapidReceipt)
    )
    #expect(
      await rapidCoordinator.upload(
        archive: rapidArchive,
        accessToken: try accessToken(),
        applicationDirectory: directory
      ) == .rejected(.remoteVerificationRequired(backupID: rapidBackupID))
    )

    let verifiedBackupID = UUID(uuidString: "C1000000-0000-0000-0000-000000000006")!
    let verifiedArchive = try makeArchive(backupID: verifiedBackupID)
    let verifiedReceipt = makeReceipt(
      archive: verifiedArchive,
      backupID: verifiedBackupID,
      directory: directory
    )
    let remote = makeRemote(receipt: verifiedReceipt)
    let verifiedUploader = ScriptedCoordinatorUploader(handlers: [
      verifiedHandler(remote: remote)
    ])
    let verifiedCoordinator = BaiduBackupUploadCoordinator(uploader: verifiedUploader)

    #expect(
      await verifiedCoordinator.upload(
        archive: verifiedArchive,
        accessToken: try accessToken(),
        applicationDirectory: directory
      ) == .verifiedRemote(remote)
    )
    #expect(
      await verifiedCoordinator.upload(
        archive: verifiedArchive,
        accessToken: try accessToken(),
        applicationDirectory: directory
      ) == .rejected(.alreadyCompletedThisSession(backupID: verifiedBackupID))
    )
  }

  @Test("A late cancellation for an old operation cannot cancel the next upload")
  func oldOperationIDCannotCancelNewUpload() async throws {
    let firstArchive = try makeArchive(backupID: UUID())
    let secondArchive = try makeArchive(backupID: UUID())
    let directory = try applicationDirectory()
    let token = try accessToken()
    let uploader = ScriptedCoordinatorUploader(handlers: [
      suspendingBeforeCreateHandler(),
      suspendingBeforeCreateHandler(),
    ])
    let coordinator = BaiduBackupUploadCoordinator(uploader: uploader)

    let first = Task {
      await coordinator.upload(
        archive: firstArchive,
        accessToken: token,
        applicationDirectory: directory
      )
    }
    try await waitForPhase(.precreateDispatchPermitted, coordinator: coordinator)
    let oldOperationID = try #require(await coordinator.snapshot().operationID)
    _ = await coordinator.cancelActiveUpload()
    #expect(await first.value == .cancelled(.explicit))

    let second = Task {
      await coordinator.upload(
        archive: secondArchive,
        accessToken: token,
        applicationDirectory: directory
      )
    }
    try await waitForPhase(.precreateDispatchPermitted, coordinator: coordinator)
    let newOperationID = try #require(await coordinator.snapshot().operationID)
    #expect(newOperationID != oldOperationID)

    #expect(await coordinator.cancel(operationID: oldOperationID) == false)
    #expect(await coordinator.snapshot().cancellationSource == nil)

    #expect(await coordinator.cancel(operationID: newOperationID))
    #expect(await second.value == .cancelled(.explicit))
  }

  @Test("Progress snapshots are monotonic and contain no credentials or remote metadata")
  func progressSnapshotsAreSafeAndMonotonic() async throws {
    let backupID = UUID(uuidString: "C1000000-0000-0000-0000-000000000007")!
    let archive = try makeArchive(backupID: backupID)
    let directory = try applicationDirectory()
    let receipt = makeReceipt(archive: archive, backupID: backupID, directory: directory)
    let remote = makeRemote(receipt: receipt)
    let uploader = ScriptedCoordinatorUploader(handlers: [
      verifiedTwoPartHandler(remote: remote)
    ])
    let coordinator = BaiduBackupUploadCoordinator(uploader: uploader)
    let stream = await coordinator.progressSnapshots()
    var iterator = stream.makeAsyncIterator()
    let secret = "snapshot-secret-token"
    let token = try BaiduAccessToken(secret)

    let task = Task {
      await coordinator.upload(
        archive: archive,
        accessToken: token,
        applicationDirectory: directory
      )
    }

    var snapshots: [BaiduBackupUploadCoordinatorSnapshot] = []
    for _ in 0..<7 {
      if let snapshot = await iterator.next() {
        snapshots.append(snapshot)
      }
    }

    #expect(await task.value == .verifiedRemote(remote))
    #expect(
      snapshots.map(\.phase)
        == [
          .idle,
          .preparing,
          .precreateDispatchPermitted,
          .uploadPartDispatchPermitted(partIndex: 0, ordinal: 1, total: 2),
          .uploadPartDispatchPermitted(partIndex: 1, ordinal: 2, total: 2),
          .createDispatchPermitted,
          .idle,
        ]
    )
    let activeOperationIDs = Set(snapshots.compactMap(\.operationID))
    #expect(activeOperationIDs.count == 1)
    let rendered = String(reflecting: snapshots)
    #expect(!rendered.contains(secret))
    #expect(!rendered.contains(receipt.requestedPath))
    #expect(!rendered.contains(receipt.localMD5))
  }

  private func accessToken() throws -> BaiduAccessToken {
    try BaiduAccessToken("coordinator.test-access-token")
  }

  private func applicationDirectory() throws -> BaiduNetdiskAppDirectory {
    try BaiduNetdiskAppDirectory(folderName: "测试应用")
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
      sourceBuild: "2"
    )
  }

  private func makeReceipt(
    archive: Data,
    backupID: UUID,
    directory: BaiduNetdiskAppDirectory
  ) -> BaiduBackupUploadAttemptReceipt {
    BaiduBackupUploadAttemptReceipt(
      backupID: backupID,
      requestedPath: directory.backupPath(backupID: backupID),
      localByteCount: UInt64(archive.count),
      localMD5: BaiduNetdiskBackupUploader.md5Hex(archive)
    )
  }

  private func makeRemote(
    receipt: BaiduBackupUploadAttemptReceipt
  ) -> BaiduRemoteBackup {
    BaiduRemoteBackup(
      backupID: receipt.backupID,
      fsID: 123_456,
      path: receipt.requestedPath,
      byteCount: receipt.localByteCount,
      md5: receipt.localMD5
    )
  }

  private func waitForPhase(
    _ expected: BaiduBackupUploadCoordinatorPhase,
    coordinator: BaiduBackupUploadCoordinator
  ) async throws {
    for _ in 0..<200 {
      let snapshot = await coordinator.snapshot()
      if snapshot.phase == expected {
        return
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw CoordinatorTestError.timedOut
  }

  private func suspendingBeforeCreateHandler() -> ScriptedCoordinatorUploader.Handler {
    { _, _, _, progress in
      try await progress(.precreateDispatchPermitted)
      try await Task.sleep(for: .seconds(60))
      throw CoordinatorTestError.timedOut
    }
  }

  private func createCheckpointAfterCancellationHandler()
    -> ScriptedCoordinatorUploader.Handler
  {
    { _, _, _, progress in
      try await progress(.precreateDispatchPermitted)
      do {
        try await Task.sleep(for: .seconds(60))
      } catch is CancellationError {
        // Deliberately continue to verify the actor checkpoint linearizes cancellation.
      }
      try await progress(.createDispatchPermitted)
      throw CoordinatorTestError.unexpectedUpload
    }
  }

  private func suspendingAfterCreateHandler() -> ScriptedCoordinatorUploader.Handler {
    { _, _, _, progress in
      try await progress(.precreateDispatchPermitted)
      try await progress(.createDispatchPermitted)
      try await Task.sleep(for: .seconds(60))
      throw CoordinatorTestError.timedOut
    }
  }

  private func failureAfterCreateHandler(
    error: BaiduNetdiskUploadError
  ) -> ScriptedCoordinatorUploader.Handler {
    { _, _, _, progress in
      try await progress(.precreateDispatchPermitted)
      try await progress(.createDispatchPermitted)
      throw error
    }
  }

  private func validatedSuccessAfterGateHandler(
    remote: BaiduRemoteBackup,
    gate: CoordinatorTestGate
  ) -> ScriptedCoordinatorUploader.Handler {
    { _, _, _, progress in
      try await progress(.precreateDispatchPermitted)
      try await progress(.createDispatchPermitted)
      await gate.wait()
      return .uploaded(remote)
    }
  }

  private func rapidHandler(
    receipt: BaiduBackupUploadAttemptReceipt
  ) -> ScriptedCoordinatorUploader.Handler {
    { _, _, _, progress in
      try await progress(.precreateDispatchPermitted)
      return .rapidUpload(
        BaiduRapidUploadReceipt(
          backupID: receipt.backupID,
          requestedPath: receipt.requestedPath,
          localByteCount: receipt.localByteCount,
          localMD5: receipt.localMD5
        )
      )
    }
  }

  private func verifiedHandler(
    remote: BaiduRemoteBackup
  ) -> ScriptedCoordinatorUploader.Handler {
    { _, _, _, progress in
      try await progress(.precreateDispatchPermitted)
      try await progress(.uploadPartDispatchPermitted(partIndex: 0, ordinal: 1, total: 1))
      try await progress(.createDispatchPermitted)
      return .uploaded(remote)
    }
  }

  private func verifiedTwoPartHandler(
    remote: BaiduRemoteBackup
  ) -> ScriptedCoordinatorUploader.Handler {
    { _, _, _, progress in
      try await progress(.precreateDispatchPermitted)
      try await progress(.uploadPartDispatchPermitted(partIndex: 0, ordinal: 1, total: 2))
      try await progress(.uploadPartDispatchPermitted(partIndex: 1, ordinal: 2, total: 2))
      try await progress(.createDispatchPermitted)
      return .uploaded(remote)
    }
  }
}

private enum CoordinatorTestError: Error {
  case timedOut
  case unexpectedUpload
}

private actor CoordinatorTestGate {
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

private actor ScriptedCoordinatorUploader: BaiduBackupUploading {
  typealias ProgressHandler =
    @Sendable (BaiduBackupUploadProgress) async throws -> Void
  typealias Handler =
    @Sendable (
      Data,
      BaiduAccessToken,
      BaiduNetdiskAppDirectory,
      ProgressHandler
    ) async throws -> BaiduBackupUploadOutcome

  private var handlers: [Handler]
  private var uploads = 0

  init(handlers: [Handler]) {
    self.handlers = handlers
  }

  func upload(
    archive: Data,
    accessToken: BaiduAccessToken,
    applicationDirectory: BaiduNetdiskAppDirectory,
    progress: @escaping ProgressHandler
  ) async throws -> BaiduBackupUploadOutcome {
    uploads += 1
    guard !handlers.isEmpty else {
      throw CoordinatorTestError.unexpectedUpload
    }
    let handler = handlers.removeFirst()
    return try await handler(archive, accessToken, applicationDirectory, progress)
  }

  func invocationCount() -> Int {
    uploads
  }
}
