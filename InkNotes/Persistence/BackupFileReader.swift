import Darwin
import Foundation

enum BackupFileReaderError: LocalizedError, Equatable, Sendable {
  case unsupportedURL
  case fileIsNotRegular
  case symbolicLink
  case fileTooLarge(maximum: Int)

  var errorDescription: String? {
    switch self {
    case .unsupportedURL:
      "请选择本机或系统“文件”中的笔记备份。"
    case .fileIsNotRegular:
      "请选择一个笔记备份文件。"
    case .symbolicLink:
      "无法安全读取所选备份，请从系统“文件”中直接选择原文件。"
    case .fileTooLarge:
      "这份备份较大，当前版本暂时无法打开。请保留文件并更新应用后再试。"
    }
  }
}

struct BackupFileReader: Sendable {
  static let maximumByteCount = BackupArchiveLimits.maximumArchiveByteCount
  static let defaultChunkByteCount = 1024 * 1024

  private let maximumByteCount: Int
  private let chunkByteCount: Int

  init(
    maximumByteCount: Int = Self.maximumByteCount,
    chunkByteCount: Int = Self.defaultChunkByteCount
  ) {
    precondition(maximumByteCount >= 0 && maximumByteCount < Int.max)
    precondition(chunkByteCount > 0)
    self.maximumByteCount = maximumByteCount
    self.chunkByteCount = chunkByteCount
  }

  func read(from url: URL) async throws -> Data {
    guard url.isFileURL else {
      throw BackupFileReaderError.unsupportedURL
    }
    try Task.checkCancellation()
    let maximumByteCount = maximumByteCount
    let chunkByteCount = chunkByteCount
    let readTask = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let isSecurityScoped = url.startAccessingSecurityScopedResource()
      defer {
        if isSecurityScoped {
          url.stopAccessingSecurityScopedResource()
        }
      }
      return try Self.coordinatedRead(
        from: url,
        maximumByteCount: maximumByteCount,
        chunkByteCount: chunkByteCount
      )
    }
    return try await withTaskCancellationHandler {
      try await readTask.value
    } onCancel: {
      readTask.cancel()
    }
  }

  private static func coordinatedRead(
    from url: URL,
    maximumByteCount: Int,
    chunkByteCount: Int
  ) throws -> Data {
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var readResult: Result<Data, Error>?
    coordinator.coordinate(
      readingItemAt: url,
      options: .withoutChanges,
      error: &coordinationError
    ) { coordinatedURL in
      readResult = Result {
        try Task.checkCancellation()
        return try readRegularFile(
          at: coordinatedURL,
          maximumByteCount: maximumByteCount,
          chunkByteCount: chunkByteCount
        )
      }
    }

    if let readResult {
      return try readResult.get()
    }
    if let coordinationError {
      throw coordinationError
    }
    throw CocoaError(.fileReadUnknown)
  }

  private static func readRegularFile(
    at url: URL,
    maximumByteCount: Int,
    chunkByteCount: Int
  ) throws -> Data {
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    if let fileSize = values.fileSize, fileSize > maximumByteCount {
      throw BackupFileReaderError.fileTooLarge(maximum: maximumByteCount)
    }

    let handle = try openWithoutFollowingSymbolicLinks(at: url)
    defer { try? handle.close() }

    var fileStatus = stat()
    guard fstat(handle.fileDescriptor, &fileStatus) == 0,
      (fileStatus.st_mode & S_IFMT) == S_IFREG
    else {
      throw BackupFileReaderError.fileIsNotRegular
    }
    if fileStatus.st_size > maximumByteCount {
      throw BackupFileReaderError.fileTooLarge(maximum: maximumByteCount)
    }

    var data = Data()
    if let fileSize = values.fileSize, fileSize > 0 {
      data.reserveCapacity(min(fileSize, maximumByteCount))
    }

    while true {
      try Task.checkCancellation()
      let remainingByteCount = maximumByteCount - data.count
      let requestedByteCount = min(chunkByteCount, remainingByteCount + 1)
      let chunk = try handle.read(upToCount: requestedByteCount) ?? Data()
      guard !chunk.isEmpty else { break }

      let (nextByteCount, overflow) = data.count.addingReportingOverflow(chunk.count)
      guard !overflow, nextByteCount <= maximumByteCount else {
        throw BackupFileReaderError.fileTooLarge(maximum: maximumByteCount)
      }
      data.append(chunk)
    }
    return data
  }

  private static func openWithoutFollowingSymbolicLinks(at url: URL) throws -> FileHandle {
    var hasFileSystemRepresentation = false
    let fileDescriptor = url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(-1) }
      hasFileSystemRepresentation = true
      return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard hasFileSystemRepresentation else {
      throw BackupFileReaderError.unsupportedURL
    }
    guard fileDescriptor >= 0 else {
      let openError = errno
      if openError == ELOOP {
        throw BackupFileReaderError.symbolicLink
      }
      throw POSIXError(POSIXErrorCode(rawValue: openError) ?? .EIO)
    }
    return FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
  }
}

struct BackupInboxCopyCleaner: Sendable {
  private let inboxURL: URL

  init() throws {
    let documentsURL = try FileManager.default.url(
      for: .documentDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: false
    )
    inboxURL = documentsURL.appendingPathComponent("Inbox", isDirectory: true)
  }

  init(inboxURL: URL) {
    self.inboxURL = inboxURL
  }

  @discardableResult
  func removeIfInboxCopy(at url: URL) throws -> Bool {
    guard url.isFileURL else { return false }
    let candidateURL = url.standardizedFileURL
    let standardizedInboxURL = inboxURL.standardizedFileURL
    guard candidateURL.deletingLastPathComponent() == standardizedInboxURL else {
      return false
    }

    var hasFileSystemRepresentation = false
    let result = candidateURL.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(-1) }
      hasFileSystemRepresentation = true
      return Darwin.unlink(path)
    }
    guard hasFileSystemRepresentation else {
      throw BackupFileReaderError.unsupportedURL
    }
    if result == 0 || errno == ENOENT {
      return true
    }
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
