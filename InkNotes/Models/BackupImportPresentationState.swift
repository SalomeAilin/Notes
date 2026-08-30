struct BackupImportPresentationState: Equatable, Sendable {
  var hasQueuedImport = false
  var isLibraryLoading = false
  var isDrawingLoading = false
  var hasNamingAlert = false
  var hasDeletionDialog = false
  var hasPersistenceAlert = false

  var shouldPresentBackupTransfer: Bool {
    hasQueuedImport && !isLibraryLoading && !isDrawingLoading && !hasNamingAlert
      && !hasDeletionDialog && !hasPersistenceAlert
  }
}

enum BackupImportPresentationEvent: Equatable, Sendable {
  case appeared
  case queueChanged
  case presentationStateChanged
  case transferDismissed
}

enum BackupImportPresentationCommand: Equatable, Sendable {
  case presentBackupTransfer
}

struct BackupImportPresentationCoordinator: Equatable, Sendable {
  private(set) var hasRequestedPresentation = false

  mutating func handle(
    _ event: BackupImportPresentationEvent,
    state: BackupImportPresentationState
  ) -> BackupImportPresentationCommand? {
    if event == .transferDismissed {
      hasRequestedPresentation = false
    }

    guard state.shouldPresentBackupTransfer, !hasRequestedPresentation else { return nil }
    hasRequestedPresentation = true
    return .presentBackupTransfer
  }
}
