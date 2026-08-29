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
  case upload(BaiduNetdiskUploadError)
  case unexpected
}

enum BaiduBackupUploadRejection: Equatable, Sendable {
  case alreadyRunning(operationID: UUID)
  case remoteVerificationRequired(backupID: UUID)
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
  private enum WorkerResult: Sendable {
    case success(BaiduBackupUploadOutcome)
    case cancelled
    case uploadFailure(BaiduNetdiskUploadError)
    case unexpectedFailure
  }

  private struct ActiveUpload {
    let operationID: UUID
    let backupID: UUID
    let receipt: BaiduBackupUploadAttemptReceipt
    var phase: BaiduBackupUploadCoordinatorPhase
    var cancellationSource: BaiduBackupUploadCancellationSource?
    let worker: Task<WorkerResult, Never>
  }

  private let uploader: any BaiduBackupUploading
  private var active: ActiveUpload?
  private var backupsAwaitingRemoteVerification = Set<UUID>()
  private var completedBackups = Set<UUID>()
  private var snapshotContinuations:
    [UUID: AsyncStream<BaiduBackupUploadCoordinatorSnapshot>.Continuation] = [:]

  init(uploader: any BaiduBackupUploading = BaiduNetdiskBackupUploader()) {
    self.uploader = uploader
  }

  func upload(
    archive: Data,
    accessToken: BaiduAccessToken,
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
    if backupsAwaitingRemoteVerification.contains(receipt.backupID) {
      return .rejected(.remoteVerificationRequired(backupID: receipt.backupID))
    }
    if completedBackups.contains(receipt.backupID) {
      return .rejected(.alreadyCompletedThisSession(backupID: receipt.backupID))
    }

    let operationID = UUID()
    let uploader = self.uploader
    let worker: Task<WorkerResult, Never> = Task.detached { [self] in
      do {
        return WorkerResult.success(
          try await uploader.upload(
            archive: archive,
            accessToken: accessToken,
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

    active = ActiveUpload(
      operationID: operationID,
      backupID: receipt.backupID,
      receipt: receipt,
      phase: .preparing,
      cancellationSource: nil,
      worker: worker
    )
    publishCurrentSnapshot()

    let result = await withTaskCancellationHandler {
      await worker.value
    } onCancel: { [weak self] in
      Task.detached { [weak self] in
        await self?.requestCancellation(
          operationID: operationID,
          source: .caller
        )
      }
    }

    return finish(result, operationID: operationID)
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
    guard
      let nextPhase = nextPhase(after: active.phase, for: progress)
    else {
      throw CancellationError()
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
    ) where partIndex >= 0 && total > 0 && (1...total).contains(ordinal):
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

    case (.uploadPartDispatchPermitted, .createDispatchPermitted):
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
    active.worker.cancel()
    publishCurrentSnapshot()
    return true
  }

  private func finish(
    _ result: WorkerResult,
    operationID: UUID
  ) -> BaiduBackupUploadTerminalOutcome {
    guard let active, active.operationID == operationID else {
      return .failed(.unexpected)
    }

    let terminal: BaiduBackupUploadTerminalOutcome
    switch result {
    case .success(.uploaded(let remoteBackup)):
      if remoteBackupMatchesReceipt(remoteBackup, receipt: active.receipt) {
        completedBackups.insert(active.backupID)
        terminal = .verifiedRemote(remoteBackup)
      } else {
        backupsAwaitingRemoteVerification.insert(active.backupID)
        terminal = .outcomeUnknown(
          receipt: active.receipt,
          reason: .unverifiedResponse
        )
      }

    case .success(.rapidUpload):
      backupsAwaitingRemoteVerification.insert(active.backupID)
      terminal = .needsRemoteVerification(
        BaiduRapidUploadReceipt(
          backupID: active.receipt.backupID,
          requestedPath: active.receipt.requestedPath,
          localByteCount: active.receipt.localByteCount,
          localMD5: active.receipt.localMD5
        )
      )

    case .cancelled:
      let source = active.cancellationSource ?? .upstream
      if active.phase == .createDispatchPermitted {
        backupsAwaitingRemoteVerification.insert(active.backupID)
        terminal = .outcomeUnknown(
          receipt: active.receipt,
          reason: .cancelled(source)
        )
      } else {
        terminal = .cancelled(source)
      }

    case .uploadFailure(let error):
      if active.phase == .createDispatchPermitted,
        !isDefiniteCreateRejection(error)
      {
        backupsAwaitingRemoteVerification.insert(active.backupID)
        terminal = .outcomeUnknown(
          receipt: active.receipt,
          reason: unknownReason(for: error)
        )
      } else {
        terminal = .failed(.upload(error))
      }

    case .unexpectedFailure:
      if active.phase == .createDispatchPermitted {
        backupsAwaitingRemoteVerification.insert(active.backupID)
        terminal = .outcomeUnknown(
          receipt: active.receipt,
          reason: .unverifiedResponse
        )
      } else {
        terminal = .failed(.unexpected)
      }
    }

    self.active = nil
    publishCurrentSnapshot()
    return terminal
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

  private func isDefiniteCreateRejection(_ error: BaiduNetdiskUploadError) -> Bool {
    if case .api(stage: .create, code: _) = error {
      return true
    }
    return false
  }

  private func unknownReason(
    for error: BaiduNetdiskUploadError
  ) -> BaiduBackupUploadUnknownReason {
    switch error {
    case .transport(.create),
      .invalidHTTPResponse(.create),
      .httpStatus(stage: .create, statusCode: _),
      .responseTooLarge(stage: .create, maximum: _):
      return .responseUnavailable
    default:
      return .unverifiedResponse
    }
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
