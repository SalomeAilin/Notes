import Foundation
import Testing

@testable import InkNotesCore

@Suite("Backup import presentation state")
struct BackupImportPresentationStateTests {
  @Test("File picker cancellation errors stay quiet without hiding other failures")
  func filePickerCancellationPolicyIsExact() {
    #expect(
      BackupFilePickerFailurePolicy.disposition(for: CancellationError()) == .cancelled
    )
    #expect(
      BackupFilePickerFailurePolicy.disposition(for: CocoaError(.userCancelled)) == .cancelled
    )
    #expect(
      BackupFilePickerFailurePolicy.disposition(
        for: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
      ) == .cancelled
    )
    #expect(
      BackupFilePickerFailurePolicy.disposition(for: CocoaError(.fileReadUnknown)) == .report
    )
    #expect(
      BackupFilePickerFailurePolicy.disposition(
        for: NSError(domain: NSURLErrorDomain, code: NSUserCancelledError)
      ) == .report
    )
    #expect(BackupFilePickerFailurePolicy.disposition(for: URLError(.cancelled)) == .report)
  }

  @Test("A queued import is required before the transfer sheet can be presented")
  func queuedImportIsRequired() {
    var state = BackupImportPresentationState()

    #expect(!state.shouldPresentBackupTransfer)
    state.hasQueuedImport = true
    #expect(state.shouldPresentBackupTransfer)
    state.hasQueuedImport = false
    #expect(!state.shouldPresentBackupTransfer)
  }

  @Test("Every loading or competing presentation state defers a queued import")
  func everyBlockerDefersPresentation() {
    let blockedStates = [
      BackupImportPresentationState(hasQueuedImport: true, isLibraryLoading: true),
      BackupImportPresentationState(hasQueuedImport: true, isDrawingLoading: true),
      BackupImportPresentationState(hasQueuedImport: true, hasNamingAlert: true),
      BackupImportPresentationState(hasQueuedImport: true, hasDeletionDialog: true),
      BackupImportPresentationState(hasQueuedImport: true, hasPersistenceAlert: true),
    ]

    for state in blockedStates {
      #expect(!state.shouldPresentBackupTransfer)
    }
  }

  @Test("The queued import becomes presentable only after every blocker clears")
  func clearingBlockersAllowsPresentation() {
    var state = BackupImportPresentationState(
      hasQueuedImport: true,
      isLibraryLoading: true,
      isDrawingLoading: true,
      hasNamingAlert: true,
      hasDeletionDialog: true,
      hasPersistenceAlert: true
    )

    state.isLibraryLoading = false
    #expect(!state.shouldPresentBackupTransfer)
    state.isDrawingLoading = false
    #expect(!state.shouldPresentBackupTransfer)
    state.hasNamingAlert = false
    #expect(!state.shouldPresentBackupTransfer)
    state.hasDeletionDialog = false
    #expect(!state.shouldPresentBackupTransfer)
    state.hasPersistenceAlert = false
    #expect(state.shouldPresentBackupTransfer)
  }

  @Test("Presentation commands are emitted once across duplicate SwiftUI events")
  func presentationCommandsAreIdempotent() {
    let readyState = BackupImportPresentationState(hasQueuedImport: true)
    var coordinator = BackupImportPresentationCoordinator()

    #expect(coordinator.handle(.appeared, state: readyState) == .presentBackupTransfer)
    #expect(coordinator.handle(.queueChanged, state: readyState) == nil)
    #expect(coordinator.handle(.presentationStateChanged, state: readyState) == nil)
    #expect(coordinator.hasRequestedPresentation)
  }

  @Test("A deferred request emits its command when the last blocker changes")
  func blockerChangeReleasesDeferredRequest() {
    var state = BackupImportPresentationState(
      hasQueuedImport: true,
      hasNamingAlert: true,
      hasPersistenceAlert: true
    )
    var coordinator = BackupImportPresentationCoordinator()

    #expect(coordinator.handle(.appeared, state: state) == nil)
    state.hasNamingAlert = false
    #expect(coordinator.handle(.presentationStateChanged, state: state) == nil)
    state.hasPersistenceAlert = false
    #expect(
      coordinator.handle(.presentationStateChanged, state: state) == .presentBackupTransfer
    )
  }

  @Test("Dismissal cannot consume or reorder a queued backup request")
  func dismissalPreservesFIFOQueue() throws {
    let first = try #require(
      BackupImportRequest(
        url: URL(fileURLWithPath: "/tmp/first.notesbackup"),
        source: .externalOpen
      )
    )
    let second = try #require(
      BackupImportRequest(
        url: URL(fileURLWithPath: "/tmp/second.notesbackup"),
        source: .fileImporter
      )
    )
    var queue = BackupImportQueue()
    queue.enqueue(first)
    queue.enqueue(second)
    let queuedState = BackupImportPresentationState(hasQueuedImport: !queue.isEmpty)
    var coordinator = BackupImportPresentationCoordinator()

    #expect(coordinator.handle(.queueChanged, state: queuedState) == .presentBackupTransfer)
    #expect(queue.requests == [first, second])
    #expect(
      coordinator.handle(.transferDismissed, state: queuedState) == .presentBackupTransfer
    )
    #expect(queue.current == first)

    queue.removeCurrent(ifMatching: first.id)
    #expect(queue.current == second)
    #expect(coordinator.handle(.queueChanged, state: queuedState) == nil)

    queue.removeCurrent(ifMatching: second.id)
    let emptyState = BackupImportPresentationState(hasQueuedImport: !queue.isEmpty)
    #expect(coordinator.handle(.transferDismissed, state: emptyState) == nil)
    #expect(!coordinator.hasRequestedPresentation)

    queue.enqueue(second)
    let nextState = BackupImportPresentationState(hasQueuedImport: !queue.isEmpty)
    #expect(coordinator.handle(.queueChanged, state: nextState) == .presentBackupTransfer)
    #expect(queue.current == second)
  }
}
