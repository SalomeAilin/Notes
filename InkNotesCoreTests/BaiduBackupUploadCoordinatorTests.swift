import CryptoKit
import Foundation
import Testing

@testable import InkNotesCore

@Suite("Baidu backup upload coordination")
struct BaiduBackupUploadCoordinatorTests {
  @Test("A caller cancelled before entry never invokes the uploader")
  func cancelledCallerDoesNotStartWorker() async throws {
    let archive = try makeArchive(backupID: UUID())
    let directory = try applicationDirectory()
    let token = try credential()
    let uploader = ScriptedCoordinatorUploader(handlers: [
      suspendingBeforeCreateHandler()
    ])
    let coordinator = makeCoordinator(uploader: uploader)

    let task = Task {
      while !Task.isCancelled {
        await Task.yield()
      }
      return await coordinator.upload(
        archive: archive,
        credential: token,
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
    let token = try credential()
    let receipt = makeReceipt(archive: archive, backupID: backupID, directory: directory)
    let remote = makeRemote(receipt: receipt)
    let uploader = ScriptedCoordinatorUploader(handlers: [
      suspendingBeforePrecreateHandler(),
      verifiedHandler(remote: remote),
    ])
    let coordinator = makeCoordinator(uploader: uploader)

    let first = Task {
      await coordinator.upload(
        archive: archive,
        credential: token,
        applicationDirectory: directory
      )
    }
    try await waitForInvocationCount(1, uploader: uploader)
    let firstSnapshot = await coordinator.snapshot()

    let concurrent = await coordinator.upload(
      archive: archive,
      credential: token,
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
      credential: token,
      applicationDirectory: directory
    )
    #expect(retry == .verifiedRemote(remote))
    #expect(await uploader.invocationCount() == 2)
  }

  @Test("The admission reservation is single-flight and cancellation removes an unsent record")
  func admissionReservationIsSingleFlightAndCancellationCleansRecord() async throws {
    let backupID = UUID()
    let archive = try makeArchive(backupID: backupID)
    let directory = try applicationDirectory()
    let token = try credential()
    let gate = CoordinatorTestGate()
    let store = CoordinatorGatedReconciliationStore(gate: gate)
    let uploader = ScriptedCoordinatorUploader(handlers: [])
    let coordinator = BaiduBackupUploadCoordinator(
      uploader: uploader,
      reconciliationStore: store
    )

    let task = Task {
      await coordinator.upload(
        archive: archive,
        credential: token,
        applicationDirectory: directory
      )
    }
    try await waitForPhase(.preparing, coordinator: coordinator)
    let operationID = try #require(await coordinator.snapshot().operationID)

    #expect(
      await coordinator.upload(
        archive: archive,
        credential: token,
        applicationDirectory: directory
      ) == .rejected(.alreadyRunning(operationID: operationID))
    )
    #expect(await uploader.invocationCount() == 0)
    #expect(await coordinator.cancel(operationID: operationID))

    await gate.open()

    #expect(await task.value == .cancelled(.explicit))
    #expect(await store.recordCount() == 0)
    #expect(await uploader.invocationCount() == 0)
    #expect(await coordinator.snapshot().phase == .idle)
  }

  @Test("A reconciliation admission failure never starts network work")
  func admissionFailureDoesNotStartUploader() async throws {
    let archive = try makeArchive(backupID: UUID())
    let uploader = ScriptedCoordinatorUploader(handlers: [])
    let coordinator = BaiduBackupUploadCoordinator(
      uploader: uploader,
      reconciliationStore: CoordinatorFailingReconciliationStore(
        error: .invalidStoreLayout
      )
    )

    #expect(
      await coordinator.upload(
        archive: archive,
        credential: try credential(),
        applicationDirectory: try applicationDirectory()
      ) == .failed(.reconciliation(.invalidStoreLayout))
    )
    #expect(await uploader.invocationCount() == 0)
    #expect(await coordinator.snapshot().phase == .idle)
  }

  @Test("A failure before precreate removes the owned record and permits a safe retry")
  func failureBeforePrecreateCanRetry() async throws {
    let backupID = UUID()
    let archive = try makeArchive(backupID: backupID)
    let directory = try applicationDirectory()
    let receipt = makeReceipt(archive: archive, backupID: backupID, directory: directory)
    let remote = makeRemote(receipt: receipt)
    let error = BaiduNetdiskUploadError.transport(.precreate)
    let uploader = ScriptedCoordinatorUploader(handlers: [
      failureBeforePrecreateHandler(error: error),
      verifiedHandler(remote: remote),
    ])
    let store = CoordinatorInMemoryReconciliationStore()
    let coordinator = BaiduBackupUploadCoordinator(
      uploader: uploader,
      reconciliationStore: store
    )

    #expect(
      await coordinator.upload(
        archive: archive,
        credential: try credential(),
        applicationDirectory: directory
      ) == .failed(.upload(error))
    )
    #expect(await store.recordCount() == 0)
    #expect(
      await coordinator.upload(
        archive: archive,
        credential: try credential(),
        applicationDirectory: directory
      ) == .verifiedRemote(remote)
    )
    #expect(await uploader.invocationCount() == 2)
  }

  @Test("A precreate uncertainty blocks token rotation in the same account scope after restart")
  func precreateUncertaintyPersistsAcrossRestart() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    defer { try? fileManager.removeItem(at: rootURL) }
    let backupID = UUID()
    let archive = try makeArchive(backupID: backupID)
    let directory = try applicationDirectory()
    let receipt = makeReceipt(archive: archive, backupID: backupID, directory: directory)
    let firstUploader = ScriptedCoordinatorUploader(handlers: [
      failureAfterPrecreateHandler(error: .transport(.precreate))
    ])
    let firstCoordinator = BaiduBackupUploadCoordinator(
      uploader: firstUploader,
      reconciliationStore: BaiduUploadReconciliationRepository(rootURL: rootURL)
    )

    #expect(
      await firstCoordinator.upload(
        archive: archive,
        credential: try credential(),
        applicationDirectory: directory
      ) == .outcomeUnknown(receipt: receipt, reason: .responseUnavailable)
    )

    let restartedUploader = ScriptedCoordinatorUploader(handlers: [])
    let restartedCoordinator = BaiduBackupUploadCoordinator(
      uploader: restartedUploader,
      reconciliationStore: BaiduUploadReconciliationRepository(rootURL: rootURL)
    )
    #expect(
      await restartedCoordinator.upload(
        archive: archive,
        credential: try credential(tokenValue: "different-account-token"),
        applicationDirectory: directory
      ) == .rejected(.remoteVerificationRequired(backupID: backupID))
    )
    #expect(await firstUploader.invocationCount() == 1)
    #expect(await restartedUploader.invocationCount() == 0)
  }

  @Test("Two broker account scopes keep their distinct credentials isolated")
  func differentAccountScopesUploadIndependently() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    defer { try? fileManager.removeItem(at: rootURL) }
    let backupID = UUID()
    let archive = try makeArchive(backupID: backupID)
    let directory = try applicationDirectory()
    let receipt = makeReceipt(archive: archive, backupID: backupID, directory: directory)
    let remote = makeRemote(receipt: receipt)
    let uploader = ScriptedCoordinatorUploader(handlers: [
      failureAfterPrecreateHandler(error: .transport(.precreate)),
      verifiedHandler(remote: remote),
    ])
    let coordinator = BaiduBackupUploadCoordinator(
      uploader: uploader,
      reconciliationStore: BaiduUploadReconciliationRepository(rootURL: rootURL)
    )
    let firstScope = accountScope()
    let secondScope = accountScope(
      UUID(uuidString: "D1000000-0000-0000-0000-000000000002")!
    )

    #expect(
      await coordinator.upload(
        archive: archive,
        credential: try credential(tokenValue: "first-account-token", accountScope: firstScope),
        applicationDirectory: directory
      ) == .outcomeUnknown(receipt: receipt, reason: .responseUnavailable)
    )
    #expect(
      await coordinator.upload(
        archive: archive,
        credential: try credential(
          tokenValue: "second-account-token",
          accountScope: secondScope
        ),
        applicationDirectory: directory
      ) == .verifiedRemote(remote)
    )
    #expect(await uploader.invocationCount() == 2)
  }

  @Test("A legacy unscoped ledger blocks every account before network")
  func legacyLedgerNeverStartsUploader() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    defer { try? fileManager.removeItem(at: rootURL) }
    let backupID = UUID()
    let archive = try makeArchive(backupID: backupID)
    let directory = try applicationDirectory()
    let legacyURL = try writeLegacyReconciliationRecord(
      rootURL: rootURL,
      backupID: backupID,
      requestedPath: directory.backupPath(backupID: backupID)
    )
    let originalBytes = try Data(contentsOf: legacyURL)
    let uploader = ScriptedCoordinatorUploader(handlers: [])
    let coordinator = BaiduBackupUploadCoordinator(
      uploader: uploader,
      reconciliationStore: BaiduUploadReconciliationRepository(rootURL: rootURL)
    )

    #expect(
      await coordinator.upload(
        archive: archive,
        credential: try credential(),
        applicationDirectory: directory
      ) == .failed(.reconciliation(.legacyUnscopedRecordsPresent))
    )
    #expect(await uploader.invocationCount() == 0)
    #expect(try Data(contentsOf: legacyURL) == originalBytes)
  }

  @Test("A changed archive for the same backup ID fails closed before network")
  func changedArchiveIdentityIsRejectedAfterRestart() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    defer { try? fileManager.removeItem(at: rootURL) }
    let backupID = UUID()
    let originalArchive = try makeArchive(backupID: backupID)
    let changedArchive = try makeArchive(backupID: backupID, sourceBuild: "3")
    let directory = try applicationDirectory()
    let firstUploader = ScriptedCoordinatorUploader(handlers: [
      failureAfterPrecreateHandler(error: .transport(.precreate))
    ])
    let firstCoordinator = BaiduBackupUploadCoordinator(
      uploader: firstUploader,
      reconciliationStore: BaiduUploadReconciliationRepository(rootURL: rootURL)
    )
    _ = await firstCoordinator.upload(
      archive: originalArchive,
      credential: try credential(),
      applicationDirectory: directory
    )

    let restartedUploader = ScriptedCoordinatorUploader(handlers: [])
    let restartedCoordinator = BaiduBackupUploadCoordinator(
      uploader: restartedUploader,
      reconciliationStore: BaiduUploadReconciliationRepository(rootURL: rootURL)
    )
    #expect(
      await restartedCoordinator.upload(
        archive: changedArchive,
        credential: try credential(),
        applicationDirectory: directory
      ) == .rejected(.reconciliationIdentityConflict(backupID: backupID))
    )
    #expect(await restartedUploader.invocationCount() == 0)
  }

  @Test("A changed archive identity is also distinguished within the current session")
  func changedArchiveIdentityIsRejectedInSession() async throws {
    let backupID = UUID()
    let originalArchive = try makeArchive(backupID: backupID)
    let changedArchive = try makeArchive(backupID: backupID, sourceBuild: "3")
    let directory = try applicationDirectory()

    let pendingUploader = ScriptedCoordinatorUploader(handlers: [
      failureAfterPrecreateHandler(error: .transport(.precreate))
    ])
    let pendingCoordinator = makeCoordinator(uploader: pendingUploader)
    _ = await pendingCoordinator.upload(
      archive: originalArchive,
      credential: try credential(),
      applicationDirectory: directory
    )
    #expect(
      await pendingCoordinator.upload(
        archive: changedArchive,
        credential: try credential(),
        applicationDirectory: directory
      ) == .rejected(.reconciliationIdentityConflict(backupID: backupID))
    )
    #expect(await pendingUploader.invocationCount() == 1)

    let originalReceipt = makeReceipt(
      archive: originalArchive,
      backupID: backupID,
      directory: directory
    )
    let completedUploader = ScriptedCoordinatorUploader(handlers: [
      verifiedHandler(remote: makeRemote(receipt: originalReceipt))
    ])
    let completedCoordinator = makeCoordinator(uploader: completedUploader)
    _ = await completedCoordinator.upload(
      archive: originalArchive,
      credential: try credential(),
      applicationDirectory: directory
    )
    #expect(
      await completedCoordinator.upload(
        archive: changedArchive,
        credential: try credential(),
        applicationDirectory: directory
      ) == .rejected(.reconciliationIdentityConflict(backupID: backupID))
    )
    #expect(await completedUploader.invocationCount() == 1)
  }

  @Test("A cleanup failure preserves the barrier and never encourages a blind retry")
  func cleanupFailureKeepsBarrier() async throws {
    let backupID = UUID()
    let archive = try makeArchive(backupID: backupID)
    let directory = try applicationDirectory()
    let error = BaiduNetdiskUploadError.transport(.precreate)
    let uploader = ScriptedCoordinatorUploader(handlers: [
      failureBeforePrecreateHandler(error: error)
    ])
    let coordinator = BaiduBackupUploadCoordinator(
      uploader: uploader,
      reconciliationStore: CoordinatorCleanupFailingReconciliationStore()
    )

    #expect(
      await coordinator.upload(
        archive: archive,
        credential: try credential(),
        applicationDirectory: directory
      ) == .failed(.reconciliation(.persistenceFailure))
    )
    #expect(
      await coordinator.upload(
        archive: archive,
        credential: try credential(),
        applicationDirectory: directory
      ) == .rejected(.remoteVerificationRequired(backupID: backupID))
    )
    #expect(await uploader.invocationCount() == 1)
  }

  @Test("A verified upload remains an account-scoped at-most-once barrier after restart")
  func verifiedUploadBarrierPersistsAcrossRestart() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    defer { try? fileManager.removeItem(at: rootURL) }
    let backupID = UUID()
    let archive = try makeArchive(backupID: backupID)
    let directory = try applicationDirectory()
    let receipt = makeReceipt(archive: archive, backupID: backupID, directory: directory)
    let remote = makeRemote(receipt: receipt)
    let firstUploader = ScriptedCoordinatorUploader(handlers: [
      verifiedHandler(remote: remote)
    ])
    let firstCoordinator = BaiduBackupUploadCoordinator(
      uploader: firstUploader,
      reconciliationStore: BaiduUploadReconciliationRepository(rootURL: rootURL)
    )

    #expect(
      await firstCoordinator.upload(
        archive: archive,
        credential: try credential(),
        applicationDirectory: directory
      ) == .verifiedRemote(remote)
    )

    let restartedUploader = ScriptedCoordinatorUploader(handlers: [])
    let restartedCoordinator = BaiduBackupUploadCoordinator(
      uploader: restartedUploader,
      reconciliationStore: BaiduUploadReconciliationRepository(rootURL: rootURL)
    )
    #expect(
      await restartedCoordinator.upload(
        archive: archive,
        credential: try credential(),
        applicationDirectory: directory
      ) == .rejected(.remoteVerificationRequired(backupID: backupID))
    )
    #expect(await restartedUploader.invocationCount() == 0)
  }

  @Test("Invalid part progress cannot skip the first or final part")
  func invalidPartProgressFailsClosed() async throws {
    let twoChunkDrawingByteCount = BaiduNetdiskBackupUploader.chunkByteCount
    let invalidCases: [(drawingByteCount: Int, handler: ScriptedCoordinatorUploader.Handler)] = [
      (
        twoChunkDrawingByteCount,
        { _, _, _, progress in
          try await progress(.precreateDispatchPermitted)
          try await progress(.precreateUploadRequiredConfirmed)
          try await progress(.uploadPartDispatchPermitted(partIndex: 1, ordinal: 2, total: 2))
          throw CoordinatorTestError.unexpectedUpload
        }
      ),
      (
        twoChunkDrawingByteCount,
        { _, _, _, progress in
          try await progress(.precreateDispatchPermitted)
          try await progress(.precreateUploadRequiredConfirmed)
          try await progress(.uploadPartDispatchPermitted(partIndex: 0, ordinal: 1, total: 2))
          try await progress(.createDispatchPermitted)
          throw CoordinatorTestError.unexpectedUpload
        }
      ),
      (
        0,
        { _, _, _, progress in
          try await progress(.precreateDispatchPermitted)
          try await progress(.precreateUploadRequiredConfirmed)
          try await progress(.uploadPartDispatchPermitted(partIndex: 1, ordinal: 1, total: 1))
          throw CoordinatorTestError.unexpectedUpload
        }
      ),
      (
        0,
        { _, _, _, progress in
          try await progress(.precreateDispatchPermitted)
          try await progress(.precreateUploadRequiredConfirmed)
          try await progress(.uploadPartDispatchPermitted(partIndex: 0, ordinal: 1, total: 2))
          throw CoordinatorTestError.unexpectedUpload
        }
      ),
    ]

    for invalidCase in invalidCases {
      let backupID = UUID()
      let archive = try makeArchive(
        backupID: backupID,
        drawingByteCount: invalidCase.drawingByteCount
      )
      let directory = try applicationDirectory()
      let receipt = makeReceipt(archive: archive, backupID: backupID, directory: directory)
      let uploader = ScriptedCoordinatorUploader(handlers: [invalidCase.handler])
      let coordinator = makeCoordinator(uploader: uploader)

      #expect(
        await coordinator.upload(
          archive: archive,
          credential: try credential(),
          applicationDirectory: directory
        ) == .outcomeUnknown(receipt: receipt, reason: .unverifiedResponse)
      )
      #expect(
        await coordinator.upload(
          archive: archive,
          credential: try credential(),
          applicationDirectory: directory
        ) == .rejected(.remoteVerificationRequired(backupID: backupID))
      )
      #expect(await uploader.invocationCount() == 1)
    }
  }

  @Test("A duplicate part index cannot advance a two-chunk upload")
  func duplicatePartProgressFailsClosed() async throws {
    let backupID = UUID()
    let archive = try makeArchive(
      backupID: backupID,
      drawingByteCount: BaiduNetdiskBackupUploader.chunkByteCount
    )
    #expect(archive.count > BaiduNetdiskBackupUploader.chunkByteCount)
    let directory = try applicationDirectory()
    let receipt = makeReceipt(archive: archive, backupID: backupID, directory: directory)
    let uploader = ScriptedCoordinatorUploader(handlers: [
      { _, _, _, progress in
        try await progress(.precreateDispatchPermitted)
        try await progress(.precreateUploadRequiredConfirmed)
        try await progress(.uploadPartDispatchPermitted(partIndex: 0, ordinal: 1, total: 2))
        try await progress(.uploadPartDispatchPermitted(partIndex: 0, ordinal: 2, total: 2))
        throw CoordinatorTestError.unexpectedUpload
      }
    ])
    let coordinator = makeCoordinator(uploader: uploader)

    #expect(
      await coordinator.upload(
        archive: archive,
        credential: try credential(),
        applicationDirectory: directory
      ) == .outcomeUnknown(receipt: receipt, reason: .unverifiedResponse)
    )
    #expect(
      await coordinator.upload(
        archive: archive,
        credential: try credential(),
        applicationDirectory: directory
      ) == .rejected(.remoteVerificationRequired(backupID: backupID))
    )
    #expect(await uploader.invocationCount() == 1)
  }

  @Test("A server-requested subset may complete a multi-chunk archive")
  func requestedPartSubsetCanComplete() async throws {
    let backupID = UUID()
    let archive = try makeArchive(
      backupID: backupID,
      drawingByteCount: BaiduNetdiskBackupUploader.chunkByteCount
    )
    #expect(archive.count > BaiduNetdiskBackupUploader.chunkByteCount)
    let directory = try applicationDirectory()
    let receipt = makeReceipt(archive: archive, backupID: backupID, directory: directory)
    let remote = makeRemote(receipt: receipt)
    let uploader = ScriptedCoordinatorUploader(handlers: [
      { _, _, _, progress in
        try await progress(.precreateDispatchPermitted)
        try await progress(.precreateUploadRequiredConfirmed)
        try await progress(.uploadPartDispatchPermitted(partIndex: 1, ordinal: 1, total: 1))
        try await progress(.createDispatchPermitted)
        return .uploaded(remote)
      }
    ])
    let coordinator = makeCoordinator(uploader: uploader)

    #expect(
      await coordinator.upload(
        archive: archive,
        credential: try credential(),
        applicationDirectory: directory
      ) == .verifiedRemote(remote)
    )
    #expect(await uploader.invocationCount() == 1)
  }

  @Test("A success returned without dispatch checkpoints is never trusted")
  func uncheckedSuccessRequiresVerification() async throws {
    let backupID = UUID()
    let archive = try makeArchive(backupID: backupID)
    let directory = try applicationDirectory()
    let receipt = makeReceipt(archive: archive, backupID: backupID, directory: directory)
    let remote = makeRemote(receipt: receipt)
    let uploader = ScriptedCoordinatorUploader(handlers: [
      { _, _, _, _ in .uploaded(remote) }
    ])
    let coordinator = makeCoordinator(uploader: uploader)

    #expect(
      await coordinator.upload(
        archive: archive,
        credential: try credential(),
        applicationDirectory: directory
      ) == .outcomeUnknown(receipt: receipt, reason: .unverifiedResponse)
    )
    #expect(
      await coordinator.upload(
        archive: archive,
        credential: try credential(),
        applicationDirectory: directory
      ) == .rejected(.remoteVerificationRequired(backupID: backupID))
    )
    #expect(await uploader.invocationCount() == 1)
  }

  @Test("Caller and background cancellation after precreate require remote verification")
  func cancellationSourcesAfterPrecreateRequireVerification() async throws {
    for source in [
      BaiduBackupUploadCancellationSource.caller,
      .background,
    ] {
      let backupID = UUID()
      let archive = try makeArchive(backupID: backupID)
      let directory = try applicationDirectory()
      let token = try credential()
      let receipt = makeReceipt(archive: archive, backupID: backupID, directory: directory)
      let uploader = ScriptedCoordinatorUploader(handlers: [
        suspendingBeforeCreateHandler()
      ])
      let coordinator = makeCoordinator(uploader: uploader)
      let task = Task {
        await coordinator.upload(
          archive: archive,
          credential: token,
          applicationDirectory: directory
        )
      }
      try await waitForPhase(.precreateUploadRequiredConfirmed, coordinator: coordinator)

      if source == .caller {
        task.cancel()
      } else {
        _ = await coordinator.cancelForBackgroundTransition()
      }

      #expect(
        await task.value
          == .outcomeUnknown(receipt: receipt, reason: .cancelled(source))
      )
      #expect(
        await coordinator.upload(
          archive: archive,
          credential: token,
          applicationDirectory: directory
        ) == .rejected(.remoteVerificationRequired(backupID: backupID))
      )
      #expect(await coordinator.snapshot().phase == .idle)
    }
  }

  @Test("A cancellation recorded before create prevents its dispatch checkpoint")
  func cancellationWinsCreateCheckpointRace() async throws {
    let backupID = UUID(uuidString: "C1000000-0000-0000-0000-000000000002")!
    let archive = try makeArchive(backupID: backupID)
    let directory = try applicationDirectory()
    let token = try credential()
    let receipt = makeReceipt(archive: archive, backupID: backupID, directory: directory)
    let uploader = ScriptedCoordinatorUploader(handlers: [
      createCheckpointAfterCancellationHandler()
    ])
    let coordinator = makeCoordinator(uploader: uploader)
    let task = Task {
      await coordinator.upload(
        archive: archive,
        credential: token,
        applicationDirectory: directory
      )
    }
    try await waitForPhase(
      .uploadPartDispatchPermitted(partIndex: 0, ordinal: 1, total: 1),
      coordinator: coordinator
    )

    _ = await coordinator.cancelActiveUpload()

    #expect(
      await task.value
        == .outcomeUnknown(receipt: receipt, reason: .cancelled(.explicit))
    )
    #expect(await coordinator.snapshot().phase == .idle)
  }

  @Test("A cancellation after create is an unknown remote outcome and blocks retry")
  func cancellationAfterCreateRequiresVerification() async throws {
    let backupID = UUID(uuidString: "C1000000-0000-0000-0000-000000000003")!
    let archive = try makeArchive(backupID: backupID)
    let directory = try applicationDirectory()
    let token = try credential()
    let receipt = makeReceipt(archive: archive, backupID: backupID, directory: directory)
    let uploader = ScriptedCoordinatorUploader(handlers: [
      suspendingAfterCreateHandler()
    ])
    let coordinator = makeCoordinator(uploader: uploader)
    let task = Task {
      await coordinator.upload(
        archive: archive,
        credential: token,
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
        credential: token,
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
    let token = try credential()
    let receipt = makeReceipt(archive: archive, backupID: backupID, directory: directory)
    let remote = makeRemote(receipt: receipt)
    let gate = CoordinatorTestGate()
    let uploader = ScriptedCoordinatorUploader(handlers: [
      validatedSuccessAfterGateHandler(remote: remote, gate: gate)
    ])
    let coordinator = makeCoordinator(uploader: uploader)
    let task = Task {
      await coordinator.upload(
        archive: archive,
        credential: token,
        applicationDirectory: directory
      )
    }
    try await waitForPhase(.createDispatchPermitted, coordinator: coordinator)
    let operationID = try #require(await coordinator.snapshot().operationID)

    #expect(await coordinator.cancel(operationID: operationID))
    #expect(
      await coordinator.upload(
        archive: archive,
        credential: token,
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
    let token = try credential()
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
      let coordinator = makeCoordinator(uploader: uploader)

      let outcome = await coordinator.upload(
        archive: archive,
        credential: token,
        applicationDirectory: directory
      )

      #expect(outcome == .outcomeUnknown(receipt: receipt, reason: reason))
      #expect(
        await coordinator.upload(
          archive: archive,
          credential: token,
          applicationDirectory: directory
        )
          == .rejected(.remoteVerificationRequired(backupID: backupID))
      )
      #expect(await uploader.invocationCount() == 1)
    }
  }

  @Test("An explicit create API rejection remains conservatively blocked")
  func explicitCreateRejectionRequiresVerification() async throws {
    let backupID = UUID(uuidString: "C1000000-0000-0000-0000-000000000004")!
    let archive = try makeArchive(backupID: backupID)
    let directory = try applicationDirectory()
    let token = try credential()
    let receipt = makeReceipt(archive: archive, backupID: backupID, directory: directory)
    let error = BaiduNetdiskUploadError.api(stage: .create, code: 31061)
    let uploader = ScriptedCoordinatorUploader(handlers: [
      failureAfterCreateHandler(error: error),
      failureAfterCreateHandler(error: error),
    ])
    let coordinator = makeCoordinator(uploader: uploader)

    #expect(
      await coordinator.upload(
        archive: archive,
        credential: token,
        applicationDirectory: directory
      ) == .outcomeUnknown(receipt: receipt, reason: .unverifiedResponse)
    )
    #expect(
      await coordinator.upload(
        archive: archive,
        credential: token,
        applicationDirectory: directory
      ) == .rejected(.remoteVerificationRequired(backupID: backupID))
    )
    #expect(await uploader.invocationCount() == 1)
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
    let rapidCoordinator = makeCoordinator(uploader: rapidUploader)
    let expectedRapidReceipt = BaiduRapidUploadReceipt(
      backupID: rapidReceipt.backupID,
      requestedPath: rapidReceipt.requestedPath,
      localByteCount: rapidReceipt.localByteCount,
      localMD5: rapidReceipt.localMD5
    )

    #expect(
      await rapidCoordinator.upload(
        archive: rapidArchive,
        credential: try credential(),
        applicationDirectory: directory
      ) == .needsRemoteVerification(expectedRapidReceipt)
    )
    #expect(
      await rapidCoordinator.upload(
        archive: rapidArchive,
        credential: try credential(),
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
    let verifiedCoordinator = makeCoordinator(uploader: verifiedUploader)

    #expect(
      await verifiedCoordinator.upload(
        archive: verifiedArchive,
        credential: try credential(),
        applicationDirectory: directory
      ) == .verifiedRemote(remote)
    )
    #expect(
      await verifiedCoordinator.upload(
        archive: verifiedArchive,
        credential: try credential(),
        applicationDirectory: directory
      ) == .rejected(.alreadyCompletedThisSession(backupID: verifiedBackupID))
    )
  }

  @Test("A late cancellation for an old operation cannot cancel the next upload")
  func oldOperationIDCannotCancelNewUpload() async throws {
    let firstBackupID = UUID()
    let secondBackupID = UUID()
    let firstArchive = try makeArchive(backupID: firstBackupID)
    let secondArchive = try makeArchive(backupID: secondBackupID)
    let directory = try applicationDirectory()
    let token = try credential()
    let firstReceipt = makeReceipt(
      archive: firstArchive,
      backupID: firstBackupID,
      directory: directory
    )
    let secondReceipt = makeReceipt(
      archive: secondArchive,
      backupID: secondBackupID,
      directory: directory
    )
    let uploader = ScriptedCoordinatorUploader(handlers: [
      suspendingBeforeCreateHandler(),
      suspendingBeforeCreateHandler(),
    ])
    let coordinator = makeCoordinator(uploader: uploader)

    let first = Task {
      await coordinator.upload(
        archive: firstArchive,
        credential: token,
        applicationDirectory: directory
      )
    }
    try await waitForPhase(.precreateUploadRequiredConfirmed, coordinator: coordinator)
    let oldOperationID = try #require(await coordinator.snapshot().operationID)
    _ = await coordinator.cancelActiveUpload()
    #expect(
      await first.value
        == .outcomeUnknown(receipt: firstReceipt, reason: .cancelled(.explicit))
    )

    let second = Task {
      await coordinator.upload(
        archive: secondArchive,
        credential: token,
        applicationDirectory: directory
      )
    }
    try await waitForPhase(.precreateUploadRequiredConfirmed, coordinator: coordinator)
    let newOperationID = try #require(await coordinator.snapshot().operationID)
    #expect(newOperationID != oldOperationID)

    #expect(await coordinator.cancel(operationID: oldOperationID) == false)
    #expect(await coordinator.snapshot().cancellationSource == nil)

    #expect(await coordinator.cancel(operationID: newOperationID))
    #expect(
      await second.value
        == .outcomeUnknown(receipt: secondReceipt, reason: .cancelled(.explicit))
    )
  }

  @Test("Progress snapshots are monotonic and contain no credentials or remote metadata")
  func progressSnapshotsAreSafeAndMonotonic() async throws {
    let backupID = UUID(uuidString: "C1000000-0000-0000-0000-000000000007")!
    let archive = try makeArchive(
      backupID: backupID,
      drawingByteCount: BaiduNetdiskBackupUploader.chunkByteCount
    )
    #expect(archive.count > BaiduNetdiskBackupUploader.chunkByteCount)
    let directory = try applicationDirectory()
    let receipt = makeReceipt(archive: archive, backupID: backupID, directory: directory)
    let remote = makeRemote(receipt: receipt)
    let uploader = ScriptedCoordinatorUploader(handlers: [
      verifiedTwoPartHandler(remote: remote)
    ])
    let coordinator = makeCoordinator(uploader: uploader)
    let stream = await coordinator.progressSnapshots()
    let secret = "snapshot-secret-token"
    let token = try credential(tokenValue: secret)

    let task = Task {
      await coordinator.upload(
        archive: archive,
        credential: token,
        applicationDirectory: directory
      )
    }

    let snapshots = try await collectSnapshots(from: stream, count: 8)

    #expect(await task.value == .verifiedRemote(remote))
    #expect(
      snapshots.map(\.phase)
        == [
          .idle,
          .preparing,
          .precreateDispatchPermitted,
          .precreateUploadRequiredConfirmed,
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

  private func credential(
    tokenValue: String = "coordinator.test-access-token",
    accountScope: BaiduAccountScope? = nil
  ) throws -> BaiduAccountBoundCredential {
    BaiduAccountBoundCredential.testingOnly(
      accountScope: accountScope ?? self.accountScope(),
      accessToken: try BaiduAccessToken(tokenValue)
    )
  }

  private func accountScope(
    _ bindingID: UUID = UUID(uuidString: "D1000000-0000-0000-0000-000000000001")!
  ) -> BaiduAccountScope {
    try! BaiduAccountScope(brokerBindingID: bindingID)
  }

  private func makeCoordinator(
    uploader: any BaiduBackupUploading
  ) -> BaiduBackupUploadCoordinator {
    BaiduBackupUploadCoordinator(
      uploader: uploader,
      reconciliationStore: CoordinatorInMemoryReconciliationStore()
    )
  }

  private func applicationDirectory() throws -> BaiduNetdiskAppDirectory {
    try BaiduNetdiskAppDirectory(folderName: "测试应用")
  }

  private func writeLegacyReconciliationRecord(
    rootURL: URL,
    backupID: UUID,
    requestedPath: String
  ) throws -> URL {
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
    let recordURL = directoryURL.appendingPathComponent(
      "\(backupID.uuidString.lowercased()).json"
    )
    let data = try JSONSerialization.data(
      withJSONObject: [
        "schemaVersion": 1,
        "attemptID": UUID().uuidString,
        "backupID": backupID.uuidString,
        "archiveSHA256": String(repeating: "a", count: 64),
        "localMD5": String(repeating: "b", count: 32),
        "localByteCount": 4_096,
        "requestedPath": requestedPath,
      ],
      options: [.prettyPrinted, .sortedKeys]
    )
    try data.write(to: recordURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: recordURL.path
    )
    return recordURL
  }

  private func makeArchive(
    backupID: UUID,
    sourceBuild: String = "2",
    drawingByteCount: Int = 0
  ) throws -> Data {
    let library = LibraryDocument.starter()
    var drawings = Dictionary(
      uniqueKeysWithValues: library.notebooks.flatMap(\.pages).map { ($0.id, Data()) }
    )
    if drawingByteCount > 0,
      let firstPageID = library.notebooks.first?.pages.first?.id
    {
      drawings[firstPageID] = Data(repeating: 0x42, count: drawingByteCount)
    }
    return try BackupArchiveCodec.encode(
      library: library,
      drawings: drawings,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      backupID: backupID,
      sourceAppVersion: "0.2.0",
      sourceBuild: sourceBuild
    )
  }

  private func makeReceipt(
    archive: Data,
    backupID: UUID,
    directory: BaiduNetdiskAppDirectory
  ) -> BaiduBackupUploadAttemptReceipt {
    BaiduBackupUploadAttemptReceipt(
      backupID: backupID,
      archiveSHA256: SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined(),
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

  private func waitForInvocationCount(
    _ expected: Int,
    uploader: ScriptedCoordinatorUploader
  ) async throws {
    for _ in 0..<200 {
      if await uploader.invocationCount() == expected {
        return
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw CoordinatorTestError.timedOut
  }

  private func collectSnapshots(
    from stream: AsyncStream<BaiduBackupUploadCoordinatorSnapshot>,
    count: Int
  ) async throws -> [BaiduBackupUploadCoordinatorSnapshot] {
    try await withThrowingTaskGroup(
      of: [BaiduBackupUploadCoordinatorSnapshot].self
    ) { group in
      group.addTask {
        var snapshots: [BaiduBackupUploadCoordinatorSnapshot] = []
        for await snapshot in stream {
          snapshots.append(snapshot)
          if snapshots.count == count {
            return snapshots
          }
        }
        throw CoordinatorTestError.timedOut
      }
      group.addTask {
        try await Task.sleep(for: .seconds(1))
        throw CoordinatorTestError.timedOut
      }

      guard let snapshots = try await group.next() else {
        throw CoordinatorTestError.timedOut
      }
      group.cancelAll()
      return snapshots
    }
  }

  private func suspendingBeforePrecreateHandler() -> ScriptedCoordinatorUploader.Handler {
    { _, _, _, _ in
      try await Task.sleep(for: .seconds(60))
      throw CoordinatorTestError.timedOut
    }
  }

  private func failureBeforePrecreateHandler(
    error: BaiduNetdiskUploadError
  ) -> ScriptedCoordinatorUploader.Handler {
    { _, _, _, _ in
      throw error
    }
  }

  private func failureAfterPrecreateHandler(
    error: BaiduNetdiskUploadError
  ) -> ScriptedCoordinatorUploader.Handler {
    { _, _, _, progress in
      try await progress(.precreateDispatchPermitted)
      throw error
    }
  }

  private func suspendingBeforeCreateHandler() -> ScriptedCoordinatorUploader.Handler {
    { _, _, _, progress in
      try await progress(.precreateDispatchPermitted)
      try await progress(.precreateUploadRequiredConfirmed)
      try await Task.sleep(for: .seconds(60))
      throw CoordinatorTestError.timedOut
    }
  }

  private func createCheckpointAfterCancellationHandler()
    -> ScriptedCoordinatorUploader.Handler
  {
    { _, _, _, progress in
      try await progress(.precreateDispatchPermitted)
      try await progress(.precreateUploadRequiredConfirmed)
      try await progress(.uploadPartDispatchPermitted(partIndex: 0, ordinal: 1, total: 1))
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
      try await progress(.precreateUploadRequiredConfirmed)
      try await progress(.uploadPartDispatchPermitted(partIndex: 0, ordinal: 1, total: 1))
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
      try await progress(.precreateUploadRequiredConfirmed)
      try await progress(.uploadPartDispatchPermitted(partIndex: 0, ordinal: 1, total: 1))
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
      try await progress(.precreateUploadRequiredConfirmed)
      try await progress(.uploadPartDispatchPermitted(partIndex: 0, ordinal: 1, total: 1))
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
      try await progress(.precreateUploadRequiredConfirmed)
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
      try await progress(.precreateUploadRequiredConfirmed)
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

private struct CoordinatorReconciliationKey: Hashable {
  let accountScope: BaiduAccountScope
  let backupID: UUID

  init(_ record: BaiduUploadReconciliationRecord) {
    accountScope = record.accountScope
    backupID = record.backupID
  }
}

private actor CoordinatorInMemoryReconciliationStore: BaiduUploadReconciliationStoring {
  private var records: [CoordinatorReconciliationKey: BaiduUploadReconciliationRecord] = [:]

  func admit(
    _ record: BaiduUploadReconciliationRecord
  ) -> BaiduUploadReconciliationAdmission {
    let key = CoordinatorReconciliationKey(record)
    guard let existing = records[key] else {
      records[key] = record
      return .created
    }
    return hasSameUploadIdentity(existing, record) ? .existing : .identityConflict
  }

  func removeOwned(_ record: BaiduUploadReconciliationRecord) throws -> Bool {
    let key = CoordinatorReconciliationKey(record)
    guard let existing = records[key] else { return false }
    guard existing == record else {
      throw BaiduUploadReconciliationRepositoryError.identityConflict
    }
    records.removeValue(forKey: key)
    return true
  }

  func recordCount() -> Int {
    records.count
  }

  private func hasSameUploadIdentity(
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
}

private actor CoordinatorGatedReconciliationStore: BaiduUploadReconciliationStoring {
  private let gate: CoordinatorTestGate
  private var records: [CoordinatorReconciliationKey: BaiduUploadReconciliationRecord] = [:]

  init(gate: CoordinatorTestGate) {
    self.gate = gate
  }

  func admit(
    _ record: BaiduUploadReconciliationRecord
  ) async -> BaiduUploadReconciliationAdmission {
    await gate.wait()
    let key = CoordinatorReconciliationKey(record)
    guard let existing = records[key] else {
      records[key] = record
      return .created
    }
    return existing == record ? .existing : .identityConflict
  }

  func removeOwned(_ record: BaiduUploadReconciliationRecord) throws -> Bool {
    let key = CoordinatorReconciliationKey(record)
    guard let existing = records[key] else { return false }
    guard existing == record else {
      throw BaiduUploadReconciliationRepositoryError.identityConflict
    }
    records.removeValue(forKey: key)
    return true
  }

  func recordCount() -> Int {
    records.count
  }
}

private struct CoordinatorFailingReconciliationStore: BaiduUploadReconciliationStoring {
  let error: BaiduUploadReconciliationRepositoryError

  func admit(
    _ record: BaiduUploadReconciliationRecord
  ) async throws -> BaiduUploadReconciliationAdmission {
    throw error
  }

  func removeOwned(_ record: BaiduUploadReconciliationRecord) async throws -> Bool {
    throw error
  }
}

private actor CoordinatorCleanupFailingReconciliationStore:
  BaiduUploadReconciliationStoring
{
  private var record: BaiduUploadReconciliationRecord?

  func admit(
    _ requested: BaiduUploadReconciliationRecord
  ) -> BaiduUploadReconciliationAdmission {
    guard let existing = record else {
      record = requested
      return .created
    }
    let hasSameIdentity =
      existing.accountScope == requested.accountScope
      && existing.backupID == requested.backupID
      && existing.archiveSHA256 == requested.archiveSHA256
      && existing.localMD5 == requested.localMD5
      && existing.localByteCount == requested.localByteCount
      && existing.requestedPath == requested.requestedPath
    return hasSameIdentity ? .existing : .identityConflict
  }

  func removeOwned(_ record: BaiduUploadReconciliationRecord) throws -> Bool {
    throw BaiduUploadReconciliationRepositoryError.persistenceFailure
  }
}
