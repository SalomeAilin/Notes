import Foundation

enum BackupImportSource: Equatable, Sendable {
  case externalOpen
  case fileImporter
}

struct BackupImportRequest: Identifiable, Equatable, Sendable {
  let id: UUID
  let url: URL
  let source: BackupImportSource

  init?(url: URL, source: BackupImportSource, id: UUID = UUID()) {
    guard url.isFileURL,
      url.pathExtension.caseInsensitiveCompare(BackupArchiveCodec.fileExtension) == .orderedSame
    else {
      return nil
    }
    self.id = id
    self.url = url
    self.source = source
  }
}

struct BackupImportQueue: Equatable, Sendable {
  private(set) var requests: [BackupImportRequest] = []

  var current: BackupImportRequest? {
    requests.first
  }

  var isEmpty: Bool {
    requests.isEmpty
  }

  mutating func enqueue(_ request: BackupImportRequest) {
    requests.append(request)
  }

  mutating func removeCurrent(ifMatching requestID: UUID) {
    guard current?.id == requestID else { return }
    requests.removeFirst()
  }
}
