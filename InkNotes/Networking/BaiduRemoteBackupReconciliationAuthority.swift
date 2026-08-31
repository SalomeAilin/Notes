import Foundation

enum BaiduRemoteBackupReconciliationFailure: Equatable, Sendable {
  case invalidFSID
  case verification(BaiduRemoteBackupContentVerificationError)
  case repository(BaiduUploadReconciliationRepositoryError)
  case invalidProof
  case verifiedReceiptConflict
  case unexpected
}

enum BaiduRemoteBackupReconciliationOutcome: Equatable, Sendable {
  case reconciled(BaiduVerifiedRemoteBackupReceipt)
  case alreadyVerified(BaiduVerifiedRemoteBackupReceipt)
  case missing
  case inProgress(ownerAttemptID: UUID)
  case contentMismatch(BaiduRemoteBackupContentMismatch)
  case cancelled
  case failed(BaiduRemoteBackupReconciliationFailure)
  case commitOutcomeUnknown
}

/// The only production path that may turn a pending Baidu upload record into a
/// durable verified receipt. The authority obtains its own exclusive claim,
/// performs full-byte verification while that claim remains live, and consumes
/// the resulting one-time proof without accepting proofs from callers.
actor BaiduRemoteBackupReconciliationAuthority {
  private let repository: BaiduUploadReconciliationRepository
  private let verifier: BaiduRemoteBackupContentVerifier

  init() {
    self.repository = BaiduUploadReconciliationRepository()
    self.verifier = BaiduRemoteBackupContentVerifier()
  }

  #if SWIFT_PACKAGE
    init(
      repository: BaiduUploadReconciliationRepository,
      verifier: BaiduRemoteBackupContentVerifier
    ) {
      self.repository = repository
      self.verifier = verifier
    }
  #endif

  func reconcile(
    backupID: UUID,
    fsID: UInt64,
    credential: BaiduAccountBoundCredential
  ) async -> BaiduRemoteBackupReconciliationOutcome {
    guard !Task.isCancelled else { return .cancelled }
    guard fsID > 0 else { return .failed(.invalidFSID) }

    let claim: BaiduUploadReconciliationClaim
    do {
      claim = try await repository.claimPending(
        accountScope: credential.accountScope,
        backupID: backupID
      )
    } catch let error as BaiduUploadReconciliationRepositoryError {
      return .failed(.repository(error))
    } catch {
      return .failed(.unexpected)
    }

    switch claim {
    case .missing:
      return .missing
    case .inProgress(let ownerAttemptID):
      return .inProgress(ownerAttemptID: ownerAttemptID)
    case .verified(let receipt):
      guard receipt.remoteFSID == fsID else {
        return .failed(.verifiedReceiptConflict)
      }
      return .alreadyVerified(receipt)
    case .claimed(let lease):
      return await reconcile(
        lease: lease,
        fsID: fsID,
        credential: credential
      )
    }
  }

  private func reconcile(
    lease: BaiduUploadReconciliationVerificationLease,
    fsID: UInt64,
    credential: BaiduAccountBoundCredential
  ) async -> BaiduRemoteBackupReconciliationOutcome {
    defer { lease.release() }

    let result: BaiduRemoteBackupContentVerificationResult
    do {
      try Task.checkCancellation()
      result = try await verifier.verify(
        record: lease.record,
        fsID: fsID,
        verificationChallenge: lease.verificationChallenge,
        credential: credential
      )
    } catch is CancellationError {
      return .cancelled
    } catch let error as BaiduRemoteBackupContentVerificationError {
      return .failed(.verification(error))
    } catch {
      return .failed(.unexpected)
    }

    guard result.accountScope == lease.record.accountScope,
      result.attemptID == lease.record.attemptID,
      result.backupID == lease.record.backupID
    else {
      return .failed(.invalidProof)
    }

    switch result.verification {
    case .contentMismatch(let mismatch):
      return .contentMismatch(mismatch)
    case .contentVerified(let proof):
      guard proof.record == lease.record,
        proof.verificationChallenge == lease.verificationChallenge,
        proof.fsID == fsID,
        proof.byteCount == lease.record.localByteCount,
        proof.sha256 == lease.record.archiveSHA256
      else {
        return .failed(.invalidProof)
      }

      do {
        try Task.checkCancellation()
      } catch {
        return .cancelled
      }

      do {
        return .reconciled(try await repository.commitVerified(lease, proof: proof))
      } catch BaiduUploadReconciliationRepositoryError.invalidProof {
        return .failed(.invalidProof)
      } catch {
        // A failure after the atomic swap starts cannot safely be classified as
        // pending or committed. The durable entry must be inspected before any
        // future retry.
        return .commitOutcomeUnknown
      }
    }
  }
}
