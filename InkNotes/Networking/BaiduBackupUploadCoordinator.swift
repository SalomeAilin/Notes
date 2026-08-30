import CryptoKit
import Foundation

enum BaiduBackupUploadCoordinatorPhase: Equatable, Sendable {
  case idle
  case preparing
  case precreateDispatchPermitted
  case precreateUploadRequiredConfirmed
  case uploadPartDispatchPermitted(partIndex: Int, ordinal: Int, total: Int)
  case createDispatchPermitted
}

enum BaiduBackupUploadCancellationSource: Equatable, Sendable {
  case caller
  case explicit
  case background
  case upstream
}

struct BaiduBackupUploadCoordinatorSnapshot: Equatable, Sendable {
  let operationID: UUID?
  let phase: BaiduBackupUploadCoordinatorPhase
  let cancellationSource: BaiduBackupUploadCancellationSource?
}

struct BaiduBackupUploadAttemptReceipt: Equatable, Sendable {
  let backupID: UUID
  let archiveSHA256: String
  let requestedPath: String
  let localByteCount: UInt64
  let localMD5: String
}

enum BaiduBackupUploadUnknownReason: Equatable, Sendable {
  case cancelled(BaiduBackupUploadCancellationSource)
  case responseUnavailable
  case unverifiedResponse
}

enum BaiduBackupUploadCoordinatorFailure: Equatable, Sendable {
  case invalidBackup(BackupArchiveError)
  case reconciliation(BaiduUploadReconciliationRepositoryError)
  case upload(BaiduNetdiskUploadError)
  case unexpected
}

enum BaiduBackupUploadRejection: Equatable, Sendable {
  case alreadyRunning(operationID: UUID)
  case remoteVerificationRequired(backupID: UUID)
  case reconciliationIdentityConflict(backupID: UUID)
  case alreadyCompletedThisSession(backupID: UUID)
}

enum BaiduBackupUploadTerminalOutcome: Equatable, Sendable {
  case verifiedRemote(BaiduRemoteBackup)
  case needsRemoteVerification(BaiduRapidUploadReceipt)
  case outcomeUnknown(
    receipt: BaiduBackupUploadAttemptReceipt,
    reason: BaiduBackupUploadUnknownReason
  )
  case cancelled(BaiduBackupUploadCancellationSource)
  case failed(BaiduBackupUploadCoordinatorFailure)
  case rejected(BaiduBackupUploadRejection)
}

actor BaiduBackupUploadCoordinator {
  private struct ScopedBackupKey: Hashable, Sendable {
    let accountScope: BaiduAccountScope
    let backupID: UUID
  }

  private enum CheckpointError: Error {
    case invalidProgress
  }

  private enum WorkerResult: Sendable {
    case success(BaiduBackupUploadOutcome)
    case cancelled
    case uploadFailure(BaiduNetdiskUploadError)
    case unexpectedFailure
  }

  private struct ActiveUpload {
    let operationID: UUID
    let key: ScopedBackupKey
    let receipt: BaiduBackupUploadAttemptReceipt
    let record: BaiduUploadReconciliationRecord
    let archiveChunkCount: Int
    var phase: BaiduBackupUploadCoordinatorPhase
    var cancellationSource: BaiduBackupUploadCancellationSource?
    var dispatchedPartIndices: Set<Int>
    var lease: BaiduUploadReconciliationLease?
    var worker: Task<WorkerResult, Never>?
  }

  private let uploader: any BaiduBackupUploading
  private let reconciliationStore: any BaiduUploadReconciliationStoring
  private var active: ActiveUpload?
  private var backupsAwaitingRemoteVerification:
    [ScopedBackupKey: BaiduBackupUploadAttemptReceipt] = [:]
  private var completedBackups: [ScopedBackupKey: BaiduBackupUploadAttemptReceipt] = [:]
  private var snapshotContinuations:
    [UUID: AsyncStream<BaiduBackupUploadCoordinatorSnapshot>.Continuation] = [:]

  init(
    uploader: any BaiduBackupUploading = BaiduNetdiskBackupUploader(),
    reconciliationStore: any BaiduUploadReconciliationStoring =
      BaiduUploadReconciliationRepository()
  ) {
    self.uploader = uploader
    self.reconciliationStore = reconciliationStore
  }

  func upload(
    archive: Data,
    credential: BaiduAccountBoundCredential,
    applicationDirectory: BaiduNetdiskAppDirectory
  ) async -> BaiduBackupUploadTerminalOutcome {
    if Task.isCancelled {
      return .cancelled(.caller)
    }
    if let active {
      return .rejected(.alreadyRunning(operationID: active.operationID))
    }

    let receipt: BaiduBackupUploadAttemptReceipt
    do {
      let validated = try BackupArchiveCodec.decode(archive)
      receipt = BaiduBackupUploadAttemptReceipt(
        backupID: validated.backupID,
        archiveSHA256: Self.sha256Hex(archive),
        requestedPath: applicationDirectory.backupPath(backupID: validated.backupID),
        localByteCount: UInt64(archive.count),
        localMD5: BaiduNetdiskBackupUploader.md5Hex(archive)
      )
    } catch let error as BackupArchiveError {
      return .failed(.invalidBackup(error))
    } catch {
      return .failed(.invalidBackup(.invalidManifest))
    }

    if Task.isCancelled {
      return .cancelled(.caller)
    }
    let key = ScopedBackupKey(
      accountScope: credential.accountScope,
      backupID: receipt.backupID
    )
    if let pendingReceipt = backupsAwaitingRemoteVerification[key] {
      return .rejected(
        receiptHasSameUploadIdentity(pendingReceipt, receipt)
          ? .remoteVerificationRequired(backupID: receipt.backupID)
          : .reconciliationIdentityConflict(backupID: receipt.backupID)
      )
    }
    if let completedReceipt = completedBackups[key] {
      return .rejected(
        receiptHasSameUploadIdentity(completedReceipt, receipt)
          ? .alreadyCompletedThisSession(backupID: receipt.backupID)
          : .reconciliationIdentityConflict(backupID: receipt.backupID)
      )
    }

    let operationID = UUID()
    let record = BaiduUploadReconciliationRecord(
      accountScope: credential.accountScope,
      attemptID: operationID,
      backupID: receipt.backupID,
      archiveSHA256: receipt.archiveSHA256,
      localMD5: receipt.localMD5,
      localByteCount: receipt.localByteCount,
      requestedPath: receipt.requestedPath
    )

    active = ActiveUpload(
      operationID: operationID,
      key: key,
      receipt: receipt,
      record: record,
      archiveChunkCount: (archive.count + BaiduNetdiskBackupUploader.chunkByteCount - 1)
        / BaiduNetdiskBackupUploader.chunkByteCount,
      phase: .preparing,
      cancellationSource: nil,
      dispatchedPartIndices: [],
      lease: nil,
      worker: nil
    )
    publishCurrentSnapshot()

    return await withTaskCancellationHandler {
      await admitAndRun(
        archive: archive,
        credential: credential,
        applicationDirectory: applicationDirectory,
        operationID: operationID
      )
    } onCancel: { [weak self] in
      Task { [weak self] in
        await self?.requestCancellation(
          operationID: operationID,
          source: .caller
        )
      }
    }

  }

  private func admitAndRun(
    archive: Data,
    credential: BaiduAccountBoundCredential,
    applicationDirectory: BaiduNetdiskAppDirectory,
    operationID: UUID
  ) async -> BaiduBackupUploadTerminalOutcome {
    if Task.isCancelled {
      _ = requestCancellation(operationID: operationID, source: .caller)
    }
    guard let reservation = active, reservation.operationID == operationID else {
      return .failed(.unexpected)
    }
    if let cancellationSource = reservation.cancellationSource {
      return finishReservation(
        operationID: operationID,
        terminal: .cancelled(cancellationSource)
      )
    }

    let admission: BaiduUploadReconciliationAdmission
    do {
      admission = try await reconciliationStore.admit(reservation.record)
    } catch let error as BaiduUploadReconciliationRepositoryError {
      return finishReservation(
        operationID: operationID,
        terminal: .failed(.reconciliation(error))
      )
    } catch {
      return finishReservation(
        operationID: operationID,
        terminal: .failed(.reconciliation(.persistenceFailure))
      )
    }

    guard var admitted = active, admitted.operationID == operationID else {
      if case .created(let lease) = admission {
        lease.release()
      }
      return .failed(.unexpected)
    }
    switch admission {
    case .inProgress(let ownerAttemptID):
      return finishReservation(
        operationID: operationID,
        terminal: .rejected(.alreadyRunning(operationID: ownerAttemptID))
      )
    case .existing:
      backupsAwaitingRemoteVerification[admitted.key] = admitted.receipt
      return finishReservation(
        operationID: operationID,
        terminal: .rejected(
          .remoteVerificationRequired(backupID: admitted.key.backupID)
        )
      )
    case .identityConflict:
      return finishReservation(
        operationID: operationID,
        terminal: .rejected(
          .reconciliationIdentityConflict(backupID: admitted.key.backupID)
        )
      )
    case .created(let lease):
      admitted.lease = lease
      active = admitted
    }

    if Task.isCancelled {
      _ = requestCancellation(operationID: operationID, source: .caller)
    }
    guard let ready = active, ready.operationID == operationID else {
      admitted.lease?.release()
      return .failed(.unexpected)
    }
    if let cancellationSource = ready.cancellationSource {
      return await finishBeforeNetwork(
        operationID: operationID,
        terminal: .cancelled(cancellationSource)
      )
    }

    let uploader = self.uploader
    let worker: Task<WorkerResult, Never> = Task.detached { [self] in
      do {
        return WorkerResult.success(
          try await uploader.upload(
            archive: archive,
            accessToken: credential.requestAccessToken,
            applicationDirectory: applicationDirectory,
            progress: { progress in
              try await self.checkpoint(progress, operationID: operationID)
            }
          )
        )
      } catch is CancellationError {
        return .cancelled
      } catch let error as BaiduNetdiskUploadError {
        return .uploadFailure(error)
      } catch {
        return .unexpectedFailure
      }
    }

    guard var started = active, started.operationID == operationID else {
      worker.cancel()
      ready.lease?.release()
      return .failed(.unexpected)
    }
    started.worker = worker
    active = started

    let result = await worker.value
    return await finish(result, operationID: operationID)
  }

  func snapshot() -> BaiduBackupUploadCoordinatorSnapshot {
    currentSnapshot
  }

  func progressSnapshots() -> AsyncStream<BaiduBackupUploadCoordinatorSnapshot> {
    let continuationID = UUID()
    let pair = AsyncStream.makeStream(
      of: BaiduBackupUploadCoordinatorSnapshot.self,
      bufferingPolicy: .bufferingNewest(16)
    )
    snapshotContinuations[continuationID] = pair.continuation
    pair.continuation.yield(currentSnapshot)
    pair.continuation.onTermination = { [weak self] _ in
      Task { [weak self] in
        await self?.removeSnapshotContinuation(continuationID)
      }
    }
    return pair.stream
  }

  @discardableResult
  func cancelActiveUpload() -> UUID? {
    guard let operationID = active?.operationID else { return nil }
    _ = requestCancellation(operationID: operationID, source: .explicit)
    return operationID
  }

  @discardableResult
  func cancel(operationID: UUID) -> Bool {
    requestCancellation(operationID: operationID, source: .explicit)
  }

  @discardableResult
  func cancelForBackgroundTransition() -> UUID? {
    guard let operationID = active?.operationID else { return nil }
    _ = requestCancellation(operationID: operationID, source: .background)
    return operationID
  }

  @discardableResult
  func cancelForBackgroundTransition(operationID: UUID) -> Bool {
    requestCancellation(operationID: operationID, source: .background)
  }

  private var currentSnapshot: BaiduBackupUploadCoordinatorSnapshot {
    guard let active else {
      return BaiduBackupUploadCoordinatorSnapshot(
        operationID: nil,
        phase: .idle,
        cancellationSource: nil
      )
    }
    return BaiduBackupUploadCoordinatorSnapshot(
      operationID: active.operationID,
      phase: active.phase,
      cancellationSource: active.cancellationSource
    )
  }

  private func checkpoint(
    _ progress: BaiduBackupUploadProgress,
    operationID: UUID
  ) throws {
    guard var active, active.operationID == operationID else {
      throw CancellationError()
    }
    guard active.cancellationSource == nil else {
      throw CancellationError()
    }
    if case .uploadPartDispatchPermitted(let partIndex, _, let total) = progress {
      guard (0..<active.archiveChunkCount).contains(partIndex),
        total <= active.archiveChunkCount,
        !active.dispatchedPartIndices.contains(partIndex)
      else {
        throw CheckpointError.invalidProgress
      }
    }
    if case .createDispatchPermitted = progress,
      case .uploadPartDispatchPermitted(_, _, let total) = active.phase,
      active.dispatchedPartIndices.count != total
    {
      throw CheckpointError.invalidProgress
    }
    guard
      let nextPhase = nextPhase(after: active.phase, for: progress)
    else {
      throw CheckpointError.invalidProgress
    }
    if case .uploadPartDispatchPermitted(let partIndex, _, _) = progress {
      active.dispatchedPartIndices.insert(partIndex)
    }
    active.phase = nextPhase
    self.active = active
    publishCurrentSnapshot()
  }

  private func nextPhase(
    after current: BaiduBackupUploadCoordinatorPhase,
    for progress: BaiduBackupUploadProgress
  ) -> BaiduBackupUploadCoordinatorPhase? {
    switch (current, progress) {
    case (.preparing, .precreateDispatchPermitted):
      return .precreateDispatchPermitted

    case (.precreateDispatchPermitted, .precreateUploadRequiredConfirmed):
      return .precreateUploadRequiredConfirmed

    case (
      .precreateUploadRequiredConfirmed,
      .uploadPartDispatchPermitted(let partIndex, let ordinal, let total)
    ) where partIndex >= 0 && total > 0 && ordinal == 1:
      return .uploadPartDispatchPermitted(
        partIndex: partIndex,
        ordinal: ordinal,
        total: total
      )

    case (
      .uploadPartDispatchPermitted(_, let previousOrdinal, let previousTotal),
      .uploadPartDispatchPermitted(let partIndex, let ordinal, let total)
    )
    where partIndex >= 0 && total == previousTotal && ordinal == previousOrdinal + 1
      && ordinal <= total:
      return .uploadPartDispatchPermitted(
        partIndex: partIndex,
        ordinal: ordinal,
        total: total
      )

    case (
      .uploadPartDispatchPermitted(_, let previousOrdinal, let previousTotal),
      .createDispatchPermitted
    ) where previousOrdinal == previousTotal:
      return .createDispatchPermitted

    default:
      return nil
    }
  }

  private func requestCancellation(
    operationID: UUID,
    source: BaiduBackupUploadCancellationSource
  ) -> Bool {
    guard var active, active.operationID == operationID else { return false }
    if active.cancellationSource == nil {
      active.cancellationSource = source
    }
    self.active = active
    active.worker?.cancel()
    publishCurrentSnapshot()
    return true
  }

  private func finishReservation(
    operationID: UUID,
    terminal: BaiduBackupUploadTerminalOutcome
  ) -> BaiduBackupUploadTerminalOutcome {
    guard let active, active.operationID == operationID else {
      return .failed(.unexpected)
    }
    self.active = nil
    active.lease?.release()
    publishCurrentSnapshot()
    return terminal
  }

  private func finishBeforeNetwork(
    operationID: UUID,
    terminal: BaiduBackupUploadTerminalOutcome
  ) async -> BaiduBackupUploadTerminalOutcome {
    guard let active, active.operationID == operationID else {
      return .failed(.unexpected)
    }
    guard active.phase == .preparing, let lease = active.lease else {
      return finishReservation(operationID: operationID, terminal: .failed(.unexpected))
    }

    do {
      guard try await reconciliationStore.removeOwned(lease) else {
        return finishReservation(
          operationID: operationID,
          terminal: .failed(.reconciliation(.persistenceFailure))
        )
      }
    } catch let error as BaiduUploadReconciliationRepositoryError {
      return finishReservation(
        operationID: operationID,
        terminal: .failed(.reconciliation(error))
      )
    } catch {
      return finishReservation(
        operationID: operationID,
        terminal: .failed(.reconciliation(.persistenceFailure))
      )
    }

    guard let current = self.active, current.operationID == operationID,
      current.phase == .preparing
    else {
      return .failed(.unexpected)
    }
    return finishReservation(operationID: operationID, terminal: terminal)
  }

  private func finish(
    _ result: WorkerResult,
    operationID: UUID
  ) async -> BaiduBackupUploadTerminalOutcome {
    guard let active, active.operationID == operationID else {
      return .failed(.unexpected)
    }

    let terminal: BaiduBackupUploadTerminalOutcome
    switch result {
    case .success(.uploaded(let remoteBackup)):
      if active.phase == .createDispatchPermitted,
        remoteBackupMatchesReceipt(remoteBackup, receipt: active.receipt)
      {
        completedBackups[active.key] = active.receipt
        terminal = .verifiedRemote(remoteBackup)
      } else {
        backupsAwaitingRemoteVerification[active.key] = active.receipt
        terminal = .outcomeUnknown(
          receipt: active.receipt,
          reason: .unverifiedResponse
        )
      }

    case .success(.rapidUpload(let rapidReceipt)):
      if active.phase == .precreateDispatchPermitted,
        rapidReceiptMatchesReceipt(rapidReceipt, receipt: active.receipt)
      {
        backupsAwaitingRemoteVerification[active.key] = active.receipt
        terminal = .needsRemoteVerification(rapidReceipt)
      } else {
        backupsAwaitingRemoteVerification[active.key] = active.receipt
        terminal = .outcomeUnknown(
          receipt: active.receipt,
          reason: .unverifiedResponse
        )
      }

    case .cancelled:
      let source = active.cancellationSource ?? .upstream
      if active.phase == .preparing {
        return await finishBeforeNetwork(
          operationID: operationID,
          terminal: .cancelled(source)
        )
      }
      backupsAwaitingRemoteVerification[active.key] = active.receipt
      terminal = .outcomeUnknown(
        receipt: active.receipt,
        reason: .cancelled(source)
      )

    case .uploadFailure(let error):
      if active.phase == .preparing {
        return await finishBeforeNetwork(
          operationID: operationID,
          terminal: .failed(.upload(error))
        )
      }
      backupsAwaitingRemoteVerification[active.key] = active.receipt
      terminal = .outcomeUnknown(
        receipt: active.receipt,
        reason: unknownReason(for: error)
      )

    case .unexpectedFailure:
      if active.phase == .preparing {
        return await finishBeforeNetwork(
          operationID: operationID,
          terminal: .failed(.unexpected)
        )
      }
      backupsAwaitingRemoteVerification[active.key] = active.receipt
      terminal = .outcomeUnknown(
        receipt: active.receipt,
        reason: .unverifiedResponse
      )
    }

    return finishReservation(operationID: operationID, terminal: terminal)
  }

  private func remoteBackupMatchesReceipt(
    _ remoteBackup: BaiduRemoteBackup,
    receipt: BaiduBackupUploadAttemptReceipt
  ) -> Bool {
    remoteBackup.backupID == receipt.backupID
      && remoteBackup.path == receipt.requestedPath
      && remoteBackup.byteCount == receipt.localByteCount
      && remoteBackup.md5 == receipt.localMD5
  }

  private func receiptHasSameUploadIdentity(
    _ lhs: BaiduBackupUploadAttemptReceipt,
    _ rhs: BaiduBackupUploadAttemptReceipt
  ) -> Bool {
    lhs.backupID == rhs.backupID
      && lhs.archiveSHA256 == rhs.archiveSHA256
      && lhs.requestedPath == rhs.requestedPath
      && lhs.localByteCount == rhs.localByteCount
      && lhs.localMD5 == rhs.localMD5
  }

  private func rapidReceiptMatchesReceipt(
    _ rapidReceipt: BaiduRapidUploadReceipt,
    receipt: BaiduBackupUploadAttemptReceipt
  ) -> Bool {
    rapidReceipt.backupID == receipt.backupID
      && rapidReceipt.requestedPath == receipt.requestedPath
      && rapidReceipt.localByteCount == receipt.localByteCount
      && rapidReceipt.localMD5 == receipt.localMD5
  }

  private func unknownReason(
    for error: BaiduNetdiskUploadError
  ) -> BaiduBackupUploadUnknownReason {
    switch error {
    case .transport,
      .invalidHTTPResponse,
      .httpStatus,
      .responseTooLarge:
      return .responseUnavailable
    default:
      return .unverifiedResponse
    }
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func publishCurrentSnapshot() {
    let snapshot = currentSnapshot
    for continuation in snapshotContinuations.values {
      continuation.yield(snapshot)
    }
  }

  private func removeSnapshotContinuation(_ id: UUID) {
    snapshotContinuations.removeValue(forKey: id)
  }
}
