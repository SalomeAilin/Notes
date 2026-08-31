import Darwin
import Foundation

enum DurableFileWriteMode: Equatable, Sendable {
  case replace
  case createExclusive
}

enum DurableFileWriteStage: Equatable, Sendable {
  case temporaryFileCreated
  case dataWritten
  case fileSynchronized
  case published
  case parentDirectorySynchronized
}

enum DurableFileWriterError: LocalizedError, Equatable {
  case destinationAlreadyExists
  case invalidStoreLayout
  case persistenceFailure
  case siblingFileLimitReached

  var errorDescription: String? {
    switch self {
    case .destinationAlreadyExists:
      "这里已有内容，原内容没有被覆盖。"
    case .invalidStoreLayout:
      "本地笔记存储异常。为保护原内容，已停止保存。"
    case .persistenceFailure:
      "这次保存没有可靠完成，请稍后重试。原内容没有被主动覆盖。"
    case .siblingFileLimitReached:
      "本地保存记录过多，暂时无法继续新增。请先导出备份。"
    }
  }
}

protocol DurableFileWriting: Sendable {
  func createDirectoryIfNeeded(
    at url: URL,
    fileManager: FileManager,
    prepareForFileWrites: Bool
  ) throws
  func write(
    _ data: Data,
    to url: URL,
    mode: DurableFileWriteMode,
    maximumExistingSiblingCount: Int?
  ) throws
  func synchronizeFileAndParentDirectory(at url: URL) throws
}

extension DurableFileWriting {
  func createDirectoryIfNeeded(at url: URL, fileManager: FileManager) throws {
    try createDirectoryIfNeeded(
      at: url,
      fileManager: fileManager,
      prepareForFileWrites: true
    )
  }

  func write(_ data: Data, to url: URL, mode: DurableFileWriteMode) throws {
    try write(
      data,
      to: url,
      mode: mode,
      maximumExistingSiblingCount: nil
    )
  }
}

private final class DurableFileWriterState: @unchecked Sendable {
  private let lock = NSLock()
  private var preparedDirectoryPaths: Set<String> = []

  func needsTemporaryFileCleanup(at directoryURL: URL) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return !preparedDirectoryPaths.contains(directoryURL.standardizedFileURL.path)
  }

  func markTemporaryFileCleanupComplete(at directoryURL: URL) {
    lock.lock()
    preparedDirectoryPaths.insert(directoryURL.standardizedFileURL.path)
    lock.unlock()
  }
}

private struct DurableDirectoryIdentity: Hashable, Sendable {
  let device: UInt64
  let inode: UInt64
}

private final class DurableDirectoryLockRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var directoryLocks: [DurableDirectoryIdentity: NSLock] = [:]

  func processLock(for identity: DurableDirectoryIdentity) -> NSLock {
    lock.lock()
    defer { lock.unlock() }
    if let existingLock = directoryLocks[identity] {
      return existingLock
    }
    let newLock = NSLock()
    directoryLocks[identity] = newLock
    return newLock
  }
}

struct POSIXDurableFileWriter: DurableFileWriting {
  static let filePermissions = 0o600
  static let directoryPermissions = 0o700
  static let lockFilename = ".inknotes-durable-write.lock"

  private static let directoryLockRegistry = DurableDirectoryLockRegistry()

  private let checkpoint: @Sendable (DurableFileWriteStage, URL) throws -> Void
  private let state: DurableFileWriterState

  init(
    checkpoint: @escaping @Sendable (DurableFileWriteStage, URL) throws -> Void = { _, _ in }
  ) {
    self.checkpoint = checkpoint
    self.state = DurableFileWriterState()
  }

  func createDirectoryIfNeeded(
    at url: URL,
    fileManager: FileManager,
    prepareForFileWrites: Bool
  ) throws {
    try withDirectoryDescriptor(at: url.deletingLastPathComponent()) { parentDescriptor in
      if let attributes = try attributesIfPresent(at: url, fileManager: fileManager) {
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
          throw DurableFileWriterError.invalidStoreLayout
        }
      } else {
        do {
          try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: Self.directoryPermissions]
          )
        } catch {
          guard
            let attributes = try attributesIfPresent(at: url, fileManager: fileManager),
            attributes[.type] as? FileAttributeType == .typeDirectory
          else {
            throw DurableFileWriterError.persistenceFailure
          }
        }
      }

      try synchronize(descriptor: parentDescriptor)
      try checkpoint(.parentDirectorySynchronized, url)
    }
    let prepareDirectory: (Int32) throws -> Void = { directoryDescriptor in
      guard Darwin.fchmod(directoryDescriptor, mode_t(Self.directoryPermissions)) == 0 else {
        throw DurableFileWriterError.persistenceFailure
      }
      var status = stat()
      guard Darwin.fstat(directoryDescriptor, &status) == 0,
        status.st_mode & mode_t(0o7777) == mode_t(Self.directoryPermissions)
      else {
        throw DurableFileWriterError.invalidStoreLayout
      }
      if prepareForFileWrites {
        try cleanTemporaryFilesIfNeeded(
          in: url,
          directoryDescriptor: directoryDescriptor
        )
      }
      try synchronize(descriptor: directoryDescriptor)
    }
    if prepareForFileWrites {
      try withLockedDirectory(at: url, operation: prepareDirectory)
    } else {
      try withDirectoryDescriptor(at: url, operation: prepareDirectory)
    }
  }

  func write(
    _ data: Data,
    to url: URL,
    mode: DurableFileWriteMode,
    maximumExistingSiblingCount: Int?
  ) throws {
    let directoryURL = url.deletingLastPathComponent()
    try withLockedDirectory(at: directoryURL) { directoryDescriptor in
      try cleanTemporaryFilesIfNeeded(
        in: directoryURL,
        directoryDescriptor: directoryDescriptor
      )

      if mode == .createExclusive, try itemExists(at: url) {
        throw DurableFileWriterError.destinationAlreadyExists
      }
      if let maximumExistingSiblingCount {
        guard mode == .createExclusive, maximumExistingSiblingCount >= 0 else {
          throw DurableFileWriterError.persistenceFailure
        }
        let existingSiblingCount: Int
        do {
          existingSiblingCount = try FileManager.default
            .contentsOfDirectory(atPath: directoryURL.path)
            .filter {
              $0 != Self.lockFilename && !Self.isManagedTemporaryFilename($0)
            }
            .count
        } catch {
          throw DurableFileWriterError.persistenceFailure
        }
        guard existingSiblingCount < maximumExistingSiblingCount else {
          throw DurableFileWriterError.siblingFileLimitReached
        }
      }

      let temporaryURL = directoryURL.appendingPathComponent(
        ".\(UUID().uuidString.lowercased()).tmp",
        isDirectory: false
      )
      let descriptor = temporaryURL.path.withCString { path in
        Darwin.open(
          path,
          O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
          mode_t(Self.filePermissions)
        )
      }
      guard descriptor >= 0 else {
        throw DurableFileWriterError.persistenceFailure
      }
      defer {
        Darwin.close(descriptor)
        temporaryURL.path.withCString { _ = Darwin.unlink($0) }
      }

      var status = stat()
      guard Darwin.fstat(descriptor, &status) == 0,
        status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
        status.st_mode & mode_t(0o7777) == mode_t(Self.filePermissions)
      else {
        throw DurableFileWriterError.invalidStoreLayout
      }
      try checkpoint(.temporaryFileCreated, url)

      if !data.isEmpty {
        try data.withUnsafeBytes { rawBuffer in
          guard let baseAddress = rawBuffer.baseAddress else {
            throw DurableFileWriterError.persistenceFailure
          }
          var writtenByteCount = 0
          while writtenByteCount < rawBuffer.count {
            let result = Darwin.write(
              descriptor,
              baseAddress.advanced(by: writtenByteCount),
              rawBuffer.count - writtenByteCount
            )
            if result == -1, errno == EINTR { continue }
            guard result > 0 else {
              throw DurableFileWriterError.persistenceFailure
            }
            writtenByteCount += result
          }
        }
      }
      try checkpoint(.dataWritten, url)

      try synchronize(descriptor: descriptor)
      try checkpoint(.fileSynchronized, url)

      let publishResult: Int32
      switch mode {
      case .replace:
        publishResult = temporaryURL.path.withCString { temporaryPath in
          url.path.withCString { destinationPath in
            Darwin.rename(temporaryPath, destinationPath)
          }
        }
      case .createExclusive:
        publishResult = temporaryURL.path.withCString { temporaryPath in
          url.path.withCString { destinationPath in
            Darwin.renamex_np(temporaryPath, destinationPath, UInt32(RENAME_EXCL))
          }
        }
      }
      guard publishResult == 0 else {
        if mode == .createExclusive, errno == EEXIST {
          throw DurableFileWriterError.destinationAlreadyExists
        }
        throw DurableFileWriterError.persistenceFailure
      }
      try checkpoint(.published, url)

      try synchronize(descriptor: directoryDescriptor)
      try checkpoint(.parentDirectorySynchronized, url)
    }
  }

  func synchronizeFileAndParentDirectory(at url: URL) throws {
    try withLockedDirectory(at: url.deletingLastPathComponent()) { directoryDescriptor in
      let descriptor = url.path.withCString { path in
        Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      }
      guard descriptor >= 0 else {
        throw DurableFileWriterError.persistenceFailure
      }
      defer { Darwin.close(descriptor) }

      var status = stat()
      guard Darwin.fstat(descriptor, &status) == 0,
        status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
      else {
        throw DurableFileWriterError.invalidStoreLayout
      }
      guard Darwin.fchmod(descriptor, mode_t(Self.filePermissions)) == 0 else {
        throw DurableFileWriterError.persistenceFailure
      }
      guard Darwin.fstat(descriptor, &status) == 0,
        status.st_mode & mode_t(0o7777) == mode_t(Self.filePermissions)
      else {
        throw DurableFileWriterError.invalidStoreLayout
      }
      try synchronize(descriptor: descriptor)
      try checkpoint(.fileSynchronized, url)

      try synchronize(descriptor: directoryDescriptor)
      try checkpoint(.parentDirectorySynchronized, url)
    }
  }

  private func withLockedDirectory<Result>(
    at url: URL,
    operation: (Int32) throws -> Result
  ) throws -> Result {
    try withDirectoryDescriptor(at: url) { directoryDescriptor in
      var status = stat()
      guard Darwin.fstat(directoryDescriptor, &status) == 0 else {
        throw DurableFileWriterError.persistenceFailure
      }

      let identity = DurableDirectoryIdentity(
        device: UInt64(bitPattern: Int64(status.st_dev)),
        inode: UInt64(status.st_ino)
      )
      let processLock = Self.directoryLockRegistry.processLock(for: identity)
      processLock.lock()
      defer { processLock.unlock() }

      let lockDescriptor = try openLockFile(in: directoryDescriptor)
      defer { Darwin.close(lockDescriptor) }

      var lockStatus = stat()
      guard Darwin.fstat(lockDescriptor, &lockStatus) == 0,
        lockStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
        lockStatus.st_mode & mode_t(0o7777) == mode_t(Self.filePermissions)
      else {
        throw DurableFileWriterError.invalidStoreLayout
      }

      var fileLock = flock()
      fileLock.l_type = Int16(F_WRLCK)
      fileLock.l_whence = Int16(SEEK_SET)
      while Darwin.fcntl(lockDescriptor, F_SETLKW, &fileLock) == -1 {
        guard errno == EINTR else {
          throw DurableFileWriterError.persistenceFailure
        }
      }
      defer {
        fileLock.l_type = Int16(F_UNLCK)
        _ = Darwin.fcntl(lockDescriptor, F_SETLK, &fileLock)
      }
      return try operation(directoryDescriptor)
    }
  }

  private func withDirectoryDescriptor<Result>(
    at url: URL,
    operation: (Int32) throws -> Result
  ) throws -> Result {
    let directoryDescriptor = url.path.withCString { path in
      Darwin.open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
    }
    guard directoryDescriptor >= 0 else {
      throw DurableFileWriterError.persistenceFailure
    }
    defer { Darwin.close(directoryDescriptor) }

    var status = stat()
    guard Darwin.fstat(directoryDescriptor, &status) == 0,
      status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    else {
      throw DurableFileWriterError.invalidStoreLayout
    }
    return try operation(directoryDescriptor)
  }

  private func openLockFile(in directoryDescriptor: Int32) throws -> Int32 {
    var remainingMissingEntryRetries = 8
    while true {
      let descriptor = Self.lockFilename.withCString { filename in
        Darwin.openat(
          directoryDescriptor,
          filename,
          O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
          mode_t(Self.filePermissions)
        )
      }
      if descriptor >= 0 {
        return descriptor
      }
      if errno == EINTR {
        continue
      }
      if errno == ENOENT, remainingMissingEntryRetries > 0 {
        remainingMissingEntryRetries -= 1
        _ = Darwin.sched_yield()
        continue
      }
      throw DurableFileWriterError.persistenceFailure
    }
  }

  private func synchronize(descriptor: Int32) throws {
    while Darwin.fsync(descriptor) != 0 {
      guard errno == EINTR else {
        throw DurableFileWriterError.persistenceFailure
      }
    }
  }

  private func cleanTemporaryFilesIfNeeded(
    in directoryURL: URL,
    directoryDescriptor: Int32
  ) throws {
    guard state.needsTemporaryFileCleanup(at: directoryURL) else { return }
    if try removeStaleTemporaryFiles(in: directoryURL) {
      try synchronize(descriptor: directoryDescriptor)
    }
    state.markTemporaryFileCleanupComplete(at: directoryURL)
  }

  private func removeStaleTemporaryFiles(in directoryURL: URL) throws -> Bool {
    let filenames: [String]
    do {
      filenames = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
    } catch {
      throw DurableFileWriterError.persistenceFailure
    }

    var removedFile = false
    for filename in filenames where Self.isManagedTemporaryFilename(filename) {
      let candidateURL = directoryURL.appendingPathComponent(filename, isDirectory: false)
      var status = stat()
      let statusResult = candidateURL.path.withCString { Darwin.lstat($0, &status) }
      if statusResult != 0, errno == ENOENT {
        continue
      }
      guard statusResult == 0,
        status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
        status.st_mode & mode_t(0o7777) == mode_t(Self.filePermissions)
      else {
        throw DurableFileWriterError.invalidStoreLayout
      }
      let result = candidateURL.path.withCString { Darwin.unlink($0) }
      guard result == 0 || errno == ENOENT else {
        throw DurableFileWriterError.persistenceFailure
      }
      removedFile = removedFile || result == 0
    }
    return removedFile
  }

  private static func isManagedTemporaryFilename(_ filename: String) -> Bool {
    if filename == ".(UUID().uuidString.lowercased()).tmp" {
      return true
    }
    guard filename.hasPrefix("."), filename.hasSuffix(".tmp") else {
      return false
    }
    let uuidString = String(filename.dropFirst().dropLast(4))
    guard let uuid = UUID(uuidString: uuidString) else {
      return false
    }
    return uuid.uuidString.lowercased() == uuidString
  }

  private func itemExists(at url: URL) throws -> Bool {
    var status = stat()
    let result = url.path.withCString { Darwin.lstat($0, &status) }
    if result == 0 { return true }
    if errno == ENOENT { return false }
    throw DurableFileWriterError.persistenceFailure
  }

  private func attributesIfPresent(
    at url: URL,
    fileManager: FileManager
  ) throws -> [FileAttributeKey: Any]? {
    do {
      return try fileManager.attributesOfItem(atPath: url.path)
    } catch let error as NSError where Self.isMissingFileError(error) {
      return nil
    } catch {
      throw DurableFileWriterError.persistenceFailure
    }
  }

  private static func isMissingFileError(_ error: NSError) -> Bool {
    (error.domain == NSCocoaErrorDomain
      && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError))
      || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
  }
}
