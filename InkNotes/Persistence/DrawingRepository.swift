import Darwin
import Foundation

private struct SegmentedPageLockIdentity: Hashable, Sendable {
  let device: UInt64
  let inode: UInt64
}

private final class SegmentedPageLockRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var locks: [SegmentedPageLockIdentity: NSLock] = [:]

  func processLock(for identity: SegmentedPageLockIdentity) -> NSLock {
    lock.lock()
    defer { lock.unlock() }
    if let existing = locks[identity] {
      return existing
    }
    let created = NSLock()
    locks[identity] = created
    return created
  }
}

enum DrawingRepositoryError: LocalizedError, Equatable {
  case persistenceDirectoryUnavailable
  case unsupportedSchema(found: Int)
  case drawingTooLarge(actual: Int, maximum: Int)
  case restoreTransactionTooLarge(actual: Int, maximum: Int)
  case tooManyRestoreTransactions(maximum: Int)
  case restoreTransactionAlreadyExists
  case invalidRestoreTransaction

  var errorDescription: String? {
    switch self {
    case .persistenceDirectoryUnavailable:
      "无法访问应用的永久存储目录。为避免笔记被写入可能清理的临时目录，当前已停止保存。"
    case .unsupportedSchema(let found):
      "笔记数据版本 \(found) 暂不受支持，原文件未被改写。"
    case .drawingTooLarge:
      "这页内容较多，当前版本无法一次完整打开，原笔记没有改动。"
    case .restoreTransactionTooLarge:
      "备份恢复记录异常增大，已停止导入以保护现有笔记。"
    case .tooManyRestoreTransactions(let maximum):
      "本地备份恢复记录已达到 \(maximum) 份的安全上限。"
    case .restoreTransactionAlreadyExists:
      "这份备份的恢复记录已存在，未覆盖原记录。"
    case .invalidRestoreTransaction:
      "备份恢复记录损坏，已停止导入以保护现有笔记。"
    }
  }
}

actor DrawingRepository {
  static let persistedDirectoryName = "InkNotes"
  static let libraryFilename = "library.json"
  static let drawingsDirectoryName = "Drawings"
  static let drawingFileExtension = "drawing"
  static let segmentedDrawingsDirectoryName = "DrawingSegments"
  static let segmentBlobFileExtension = "drawing"
  static let segmentedPageLockFilename = ".inknotes-segmented-page.lock"
  static let maximumSegmentedPageEntryCount =
    (SegmentedDrawingLimits.maximumEntryCount
      + SegmentedDrawingLimits.maximumSourceChunkCount) * 2 + 2
  static let restoreTransactionsDirectoryName = "RestoreTransactions"
  static let restoreTransactionFileExtension = "json"
  static let maximumRestoreTransactionByteCount = BackupArchiveLimits.maximumManifestByteCount
  static let maximumRestoreTransactionCount = 1_000

  private let fileManager: FileManager
  private let applicationSupportURL: URL?
  private let rootURL: URL?
  private let durableFileWriter: any DurableFileWriting
  private var preparedDirectoryURLs: Set<URL> = []
  private static let segmentedPageLockRegistry = SegmentedPageLockRegistry()

  init(
    rootURL: URL,
    fileManager: FileManager = .default,
    durableFileWriter: any DurableFileWriting = POSIXDurableFileWriter()
  ) {
    self.applicationSupportURL = nil
    self.rootURL = rootURL
    self.fileManager = fileManager
    self.durableFileWriter = durableFileWriter
  }

  init(
    fileManager: FileManager = .default,
    durableFileWriter: any DurableFileWriting = POSIXDurableFileWriter()
  ) {
    let applicationSupportURL = DrawingRepository.defaultApplicationSupportURL(
      fileManager: fileManager
    )
    self.applicationSupportURL = applicationSupportURL
    self.rootURL = applicationSupportURL?.appendingPathComponent(
      DrawingRepository.persistedDirectoryName,
      isDirectory: true
    )
    self.fileManager = fileManager
    self.durableFileWriter = durableFileWriter
  }

  static func defaultRootURL(fileManager: FileManager = .default) -> URL? {
    defaultApplicationSupportURL(fileManager: fileManager)?.appendingPathComponent(
      persistedDirectoryName,
      isDirectory: true
    )
  }

  func loadLibrary() throws -> LibraryDocument? {
    let url = try libraryURL()
    guard fileManager.fileExists(atPath: url.path) else { return nil }

    let data = try Data(contentsOf: url)
    let document = try Self.makeDecoder().decode(LibraryDocument.self, from: data)
    guard document.schemaVersion == LibraryDocument.currentSchemaVersion else {
      throw DrawingRepositoryError.unsupportedSchema(found: document.schemaVersion)
    }
    try document.validatedPageIDs()
    return document
  }

  func saveLibrary(_ document: LibraryDocument) throws {
    try Task.checkCancellation()
    guard document.schemaVersion == LibraryDocument.currentSchemaVersion else {
      throw DrawingRepositoryError.unsupportedSchema(found: document.schemaVersion)
    }
    try document.validatedPageIDs()
    try prepareDirectories()
    let data = try Self.makeEncoder().encode(document)
    try durableFileWriter.write(data, to: libraryURL(), mode: .replace)
  }

  func loadDrawing(pageID: UUID) throws -> Data? {
    let url = try drawingURL(for: pageID)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    let storedData = try Data(contentsOf: url)
    guard SegmentedDrawingCodec.isSegmentedAuthority(storedData) else {
      return storedData
    }
    return try loadSegmentedDrawing(
      pageID: pageID,
      maximumByteCount: SegmentedDrawingLimits.maximumReconstructedDrawingByteCount
    )
  }

  func loadDrawing(pageID: UUID, maximumByteCount: Int) throws -> Data? {
    let url = try drawingURL(for: pageID)
    guard fileManager.fileExists(atPath: url.path) else { return nil }

    let authorityReadLimit = max(
      maximumByteCount,
      SegmentedDrawingLimits.maximumAuthorityByteCount
    )
    let storedData = try readBoundedData(at: url, maximumByteCount: authorityReadLimit) {
      DrawingRepositoryError.drawingTooLarge(actual: $0, maximum: maximumByteCount)
    }
    if SegmentedDrawingCodec.isSegmentedAuthority(storedData) {
      return try loadSegmentedDrawing(pageID: pageID, maximumByteCount: maximumByteCount)
    }
    guard storedData.count <= maximumByteCount else {
      throw DrawingRepositoryError.drawingTooLarge(
        actual: storedData.count,
        maximum: maximumByteCount
      )
    }
    return storedData
  }

  func loadDrawingRegion(
    pageID: UUID,
    verticalRange: ClosedRange<Double>,
    maximumByteCount: Int = SegmentedDrawingLimits.maximumReconstructedDrawingByteCount
  ) throws -> Data? {
    guard verticalRange.lowerBound.isFinite, verticalRange.upperBound.isFinite else {
      throw SegmentedDrawingError.invalidAuthority
    }
    let url = try drawingURL(for: pageID)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    let storedData = try Data(contentsOf: url)
    guard SegmentedDrawingCodec.isSegmentedAuthority(storedData) else {
      return try loadDrawing(pageID: pageID, maximumByteCount: maximumByteCount)
    }

    return try withSegmentedPageLock(pageID: pageID) {
      let latestAuthorityData = try Data(contentsOf: url)
      let authority = try SegmentedDrawingCodec.decodeAuthority(
        latestAuthorityData,
        expectedPageID: pageID
      )
      let visibleEntries = authority.entries.filter {
        $0.maximumY >= verticalRange.lowerBound
          && $0.minimumY <= verticalRange.upperBound
      }
      do {
        return try SegmentedDrawingCodec.reconstructDrawingData(
          entries: visibleEntries,
          maximumByteCount: maximumByteCount
        ) { entry in
          let blobURL = try segmentBlobURL(pageID: pageID, digest: entry.sha256)
          guard fileManager.fileExists(atPath: blobURL.path) else {
            throw SegmentedDrawingError.missingSegment(entry.sha256)
          }
          return try readBoundedData(
            at: blobURL,
            maximumByteCount: SegmentedDrawingLimits.maximumSegmentByteCount
          ) { _ in SegmentedDrawingError.segmentByteCountMismatch }
        }
      } catch SegmentedDrawingError.reconstructedDrawingTooLarge(let actual, _) {
        throw DrawingRepositoryError.drawingTooLarge(
          actual: actual,
          maximum: maximumByteCount
        )
      }
    }
  }

  func saveDrawing(_ data: Data, pageID: UUID) throws {
    try Task.checkCancellation()
    try prepareDirectories()
    let authorityURL = try drawingURL(for: pageID)
    if fileManager.fileExists(atPath: authorityURL.path),
      SegmentedDrawingCodec.isSegmentedAuthority(try Data(contentsOf: authorityURL))
    {
      try saveSegmentedDrawing(data, pageID: pageID)
      return
    }
    try durableFileWriter.write(data, to: drawingURL(for: pageID), mode: .replace)
  }

  func saveDrawingForEditing(_ data: Data, pageID: UUID) throws {
    let authorityURL = try drawingURL(for: pageID)
    if fileManager.fileExists(atPath: authorityURL.path),
      SegmentedDrawingCodec.isSegmentedAuthority(try Data(contentsOf: authorityURL))
    {
      try saveSegmentedDrawing(data, pageID: pageID)
      return
    }
    if try SegmentedDrawingCodec.shouldUseSegmentedStorage(drawingData: data) {
      try saveSegmentedDrawing(data, pageID: pageID)
    } else {
      try saveDrawing(data, pageID: pageID)
    }
  }

  func saveSegmentedDrawing(_ data: Data, pageID: UUID) throws {
    try Task.checkCancellation()
    let snapshot = try SegmentedDrawingCodec.makeSnapshot(
      pageID: pageID,
      drawingData: data
    )
    try prepareSegmentDirectories(pageID: pageID)
    let authorityURL = try drawingURL(for: pageID)

    try withSegmentedPageLock(pageID: pageID) {
      let existingAuthorityData =
        fileManager.fileExists(atPath: authorityURL.path)
        ? try Data(contentsOf: authorityURL)
        : nil
      let referencedDigests = try referencedSegmentDigests(
        authorityData: existingAuthorityData,
        pageID: pageID
      )
      try removeUnreferencedSegmentBlobs(
        pageID: pageID,
        keeping: referencedDigests
      )

      if let existingAuthorityData,
        SegmentedDrawingCodec.isSegmentedAuthority(existingAuthorityData)
      {
        let existingData = try reconstructSegmentedDrawing(
          authorityData: existingAuthorityData,
          pageID: pageID,
          maximumByteCount: SegmentedDrawingLimits.maximumReconstructedDrawingByteCount
        )
        if existingData == data {
          try synchronizeSegmentedDrawingPersistence(
            authorityData: existingAuthorityData,
            pageID: pageID
          )
          return
        }
      }

      for digest in snapshot.blobsBySHA256.keys.sorted() {
        try Task.checkCancellation()
        guard let blob = snapshot.blobsBySHA256[digest] else {
          throw SegmentedDrawingError.invalidAuthority
        }
        try persistSegmentBlob(blob, digest: digest, pageID: pageID)
      }

      try Task.checkCancellation()
      try durableFileWriter.write(
        snapshot.authorityData,
        to: authorityURL,
        mode: .replace
      )
    }
  }

  func removeDrawingIfPresent(pageID: UUID) throws {
    let url = try drawingURL(for: pageID)
    guard fileManager.fileExists(atPath: url.path) else { return }
    try fileManager.removeItem(at: url)
  }

  func drawingExists(pageID: UUID) throws -> Bool {
    try fileManager.fileExists(atPath: drawingURL(for: pageID).path)
  }

  func loadRestoreTransaction(backupID: UUID) throws -> BackupRestoreTransaction? {
    let url = try restoreTransactionURL(backupID: backupID)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    try durableFileWriter.synchronizeFileAndParentDirectory(at: url)

    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    if let size = (attributes[.size] as? NSNumber)?.uint64Value,
      size > UInt64(Self.maximumRestoreTransactionByteCount)
    {
      throw DrawingRepositoryError.restoreTransactionTooLarge(
        actual: size > UInt64(Int.max) ? Int.max : Int(size),
        maximum: Self.maximumRestoreTransactionByteCount
      )
    }

    let data = try Data(contentsOf: url)
    guard data.count <= Self.maximumRestoreTransactionByteCount else {
      throw DrawingRepositoryError.restoreTransactionTooLarge(
        actual: data.count,
        maximum: Self.maximumRestoreTransactionByteCount
      )
    }
    do {
      return try Self.makeDecoder().decode(BackupRestoreTransaction.self, from: data)
    } catch {
      throw DrawingRepositoryError.invalidRestoreTransaction
    }
  }

  func createRestoreTransaction(_ transaction: BackupRestoreTransaction) throws {
    let data: Data
    do {
      data = try Self.makeEncoder().encode(transaction)
    } catch {
      throw DrawingRepositoryError.invalidRestoreTransaction
    }
    guard data.count <= Self.maximumRestoreTransactionByteCount else {
      throw DrawingRepositoryError.restoreTransactionTooLarge(
        actual: data.count,
        maximum: Self.maximumRestoreTransactionByteCount
      )
    }

    try prepareRootDirectory()
    let directoryURL = try restoreTransactionsURL()
    let transactionURL = try restoreTransactionURL(backupID: transaction.backupID)
    try prepareDirectory(at: directoryURL)
    do {
      try durableFileWriter.write(
        data,
        to: transactionURL,
        mode: .createExclusive,
        maximumExistingSiblingCount: Self.maximumRestoreTransactionCount
      )
    } catch DurableFileWriterError.destinationAlreadyExists {
      throw DrawingRepositoryError.restoreTransactionAlreadyExists
    } catch DurableFileWriterError.siblingFileLimitReached {
      throw DrawingRepositoryError.tooManyRestoreTransactions(
        maximum: Self.maximumRestoreTransactionCount
      )
    }
  }

  func synchronizeLibraryPersistence() throws {
    try durableFileWriter.synchronizeFileAndParentDirectory(at: libraryURL())
  }

  func synchronizeDrawingPersistence(pageID: UUID) throws {
    let authorityURL = try drawingURL(for: pageID)
    let authorityData = try Data(contentsOf: authorityURL)
    if SegmentedDrawingCodec.isSegmentedAuthority(authorityData) {
      try withSegmentedPageLock(pageID: pageID) {
        let latestAuthorityData = try Data(contentsOf: authorityURL)
        try synchronizeSegmentedDrawingPersistence(
          authorityData: latestAuthorityData,
          pageID: pageID
        )
      }
      return
    }
    try durableFileWriter.synchronizeFileAndParentDirectory(at: authorityURL)
  }

  private func requiredRootURL() throws -> URL {
    guard let rootURL else {
      throw DrawingRepositoryError.persistenceDirectoryUnavailable
    }
    return rootURL
  }

  private func libraryURL() throws -> URL {
    try requiredRootURL().appendingPathComponent(Self.libraryFilename, isDirectory: false)
  }

  private func drawingsURL() throws -> URL {
    try requiredRootURL().appendingPathComponent(Self.drawingsDirectoryName, isDirectory: true)
  }

  private func segmentedDrawingsURL() throws -> URL {
    try requiredRootURL().appendingPathComponent(
      Self.segmentedDrawingsDirectoryName,
      isDirectory: true
    )
  }

  private func pageSegmentsURL(pageID: UUID) throws -> URL {
    try segmentedDrawingsURL().appendingPathComponent(
      pageID.uuidString.lowercased(),
      isDirectory: true
    )
  }

  private func segmentBlobURL(pageID: UUID, digest: String) throws -> URL {
    guard SegmentedDrawingCodec.isValidSHA256Hex(digest) else {
      throw SegmentedDrawingError.invalidSegmentDigest
    }
    return try pageSegmentsURL(pageID: pageID).appendingPathComponent(
      "\(digest).\(Self.segmentBlobFileExtension)",
      isDirectory: false
    )
  }

  private func restoreTransactionsURL() throws -> URL {
    try requiredRootURL().appendingPathComponent(
      Self.restoreTransactionsDirectoryName,
      isDirectory: true
    )
  }

  private func restoreTransactionURL(backupID: UUID) throws -> URL {
    try restoreTransactionsURL().appendingPathComponent(
      "\(backupID.uuidString.lowercased()).\(Self.restoreTransactionFileExtension)",
      isDirectory: false
    )
  }

  private func drawingURL(for pageID: UUID) throws -> URL {
    try drawingsURL().appendingPathComponent(
      "\(pageID.uuidString).\(Self.drawingFileExtension)",
      isDirectory: false
    )
  }

  private func prepareDirectories() throws {
    try prepareRootDirectory()
    try prepareDirectory(at: drawingsURL())
  }

  private func prepareSegmentDirectories(pageID: UUID) throws {
    try prepareDirectories()
    try prepareDirectory(at: segmentedDrawingsURL())
    try prepareDirectory(at: pageSegmentsURL(pageID: pageID))
  }

  private func referencedSegmentDigests(
    authorityData: Data?,
    pageID: UUID
  ) throws -> Set<String> {
    guard let authorityData,
      SegmentedDrawingCodec.isSegmentedAuthority(authorityData)
    else {
      return []
    }
    let authority = try SegmentedDrawingCodec.decodeAuthority(
      authorityData,
      expectedPageID: pageID
    )
    return Set(authority.entries.map(\.sha256) + authority.sourceChunks.map(\.sha256))
  }

  private func removeUnreferencedSegmentBlobs(
    pageID: UUID,
    keeping referencedDigests: Set<String>
  ) throws {
    let directoryURL = try pageSegmentsURL(pageID: pageID)
    let directoryDescriptor = directoryURL.path.withCString { path in
      Darwin.open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
    }
    guard directoryDescriptor >= 0 else {
      throw DurableFileWriterError.persistenceFailure
    }
    defer { Darwin.close(directoryDescriptor) }

    let names: [String]
    do {
      names = try fileManager.contentsOfDirectory(atPath: directoryURL.path)
    } catch {
      throw DurableFileWriterError.persistenceFailure
    }
    guard names.count <= Self.maximumSegmentedPageEntryCount else {
      throw DurableFileWriterError.invalidStoreLayout
    }

    var removedAnyBlob = false
    for name in names.sorted() {
      try Task.checkCancellation()
      if name == POSIXDurableFileWriter.lockFilename
        || name == Self.segmentedPageLockFilename
      {
        continue
      }
      guard let digest = Self.segmentDigest(fromCanonicalFilename: name) else {
        throw DurableFileWriterError.invalidStoreLayout
      }
      var status = stat()
      let statusResult = name.withCString { filename in
        Darwin.fstatat(directoryDescriptor, filename, &status, AT_SYMLINK_NOFOLLOW)
      }
      guard statusResult == 0,
        status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
        status.st_mode & mode_t(0o7777) == mode_t(POSIXDurableFileWriter.filePermissions)
      else {
        throw DurableFileWriterError.invalidStoreLayout
      }
      guard !referencedDigests.contains(digest) else { continue }
      let unlinkResult = name.withCString { filename in
        Darwin.unlinkat(directoryDescriptor, filename, 0)
      }
      guard unlinkResult == 0 else {
        throw DurableFileWriterError.persistenceFailure
      }
      removedAnyBlob = true
    }

    if removedAnyBlob {
      try synchronizeDescriptor(directoryDescriptor)
    }
  }

  private func loadSegmentedDrawing(
    pageID: UUID,
    maximumByteCount: Int
  ) throws -> Data {
    try withSegmentedPageLock(pageID: pageID) {
      let authorityData = try Data(contentsOf: drawingURL(for: pageID))
      return try reconstructSegmentedDrawing(
        authorityData: authorityData,
        pageID: pageID,
        maximumByteCount: maximumByteCount
      )
    }
  }

  private func synchronizeSegmentedDrawingPersistence(
    authorityData: Data,
    pageID: UUID
  ) throws {
    let authority = try SegmentedDrawingCodec.decodeAuthority(
      authorityData,
      expectedPageID: pageID
    )
    let digests = Set(authority.entries.map(\.sha256) + authority.sourceChunks.map(\.sha256))
    for digest in digests.sorted() {
      try durableFileWriter.synchronizeFileAndParentDirectory(
        at: segmentBlobURL(pageID: pageID, digest: digest)
      )
    }
    try durableFileWriter.synchronizeFileAndParentDirectory(at: drawingURL(for: pageID))
  }

  private func withSegmentedPageLock<Result>(
    pageID: UUID,
    operation: () throws -> Result
  ) throws -> Result {
    let directoryURL = try pageSegmentsURL(pageID: pageID)
    let directoryDescriptor = directoryURL.path.withCString { path in
      Darwin.open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
    }
    guard directoryDescriptor >= 0 else {
      throw DurableFileWriterError.persistenceFailure
    }
    defer { Darwin.close(directoryDescriptor) }

    var directoryStatus = stat()
    guard Darwin.fstat(directoryDescriptor, &directoryStatus) == 0,
      directoryStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    else {
      throw DurableFileWriterError.invalidStoreLayout
    }
    let identity = SegmentedPageLockIdentity(
      device: UInt64(bitPattern: Int64(directoryStatus.st_dev)),
      inode: UInt64(directoryStatus.st_ino)
    )
    let processLock = Self.segmentedPageLockRegistry.processLock(for: identity)
    processLock.lock()
    defer { processLock.unlock() }

    let lockDescriptor = Self.segmentedPageLockFilename.withCString { filename in
      Darwin.openat(
        directoryDescriptor,
        filename,
        O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
        mode_t(POSIXDurableFileWriter.filePermissions)
      )
    }
    guard lockDescriptor >= 0 else {
      throw DurableFileWriterError.persistenceFailure
    }
    defer { Darwin.close(lockDescriptor) }
    guard Darwin.fchmod(lockDescriptor, mode_t(POSIXDurableFileWriter.filePermissions)) == 0 else {
      throw DurableFileWriterError.persistenceFailure
    }
    var lockStatus = stat()
    guard Darwin.fstat(lockDescriptor, &lockStatus) == 0,
      lockStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      lockStatus.st_mode & mode_t(0o7777) == mode_t(POSIXDurableFileWriter.filePermissions)
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
    return try operation()
  }

  private func synchronizeDescriptor(_ descriptor: Int32) throws {
    while Darwin.fsync(descriptor) == -1 {
      guard errno == EINTR else {
        throw DurableFileWriterError.persistenceFailure
      }
    }
  }

  private static func segmentDigest(fromCanonicalFilename filename: String) -> String? {
    let suffix = ".\(segmentBlobFileExtension)"
    guard filename.hasSuffix(suffix) else { return nil }
    let digest = String(filename.dropLast(suffix.count))
    return SegmentedDrawingCodec.isValidSHA256Hex(digest) ? digest : nil
  }

  private func persistSegmentBlob(_ data: Data, digest: String, pageID: UUID) throws {
    let url = try segmentBlobURL(pageID: pageID, digest: digest)
    if fileManager.fileExists(atPath: url.path) {
      try verifyExistingSegment(data, at: url)
      return
    }

    do {
      try durableFileWriter.write(data, to: url, mode: .createExclusive)
    } catch DurableFileWriterError.destinationAlreadyExists {
      try verifyExistingSegment(data, at: url)
    }
  }

  private func verifyExistingSegment(_ expectedData: Data, at url: URL) throws {
    let existingData = try readBoundedData(
      at: url,
      maximumByteCount: SegmentedDrawingLimits.maximumSegmentByteCount
    ) { _ in SegmentedDrawingError.segmentByteCountMismatch }
    guard existingData == expectedData else {
      throw SegmentedDrawingError.segmentChecksumMismatch
    }
    try durableFileWriter.synchronizeFileAndParentDirectory(at: url)
  }

  private func reconstructSegmentedDrawing(
    authorityData: Data,
    pageID: UUID,
    maximumByteCount: Int
  ) throws -> Data {
    let authority = try SegmentedDrawingCodec.decodeAuthority(
      authorityData,
      expectedPageID: pageID
    )
    do {
      return try SegmentedDrawingCodec.reconstructSourceDrawingData(
        authority: authority,
        maximumByteCount: maximumByteCount
      ) { chunk in
        let url = try segmentBlobURL(pageID: pageID, digest: chunk.sha256)
        guard fileManager.fileExists(atPath: url.path) else {
          throw SegmentedDrawingError.missingSegment(chunk.sha256)
        }
        return try readBoundedData(
          at: url,
          maximumByteCount: SegmentedDrawingLimits.maximumSegmentByteCount
        ) { _ in SegmentedDrawingError.segmentByteCountMismatch }
      }
    } catch SegmentedDrawingError.reconstructedDrawingTooLarge(let actual, _) {
      throw DrawingRepositoryError.drawingTooLarge(
        actual: actual,
        maximum: maximumByteCount
      )
    }
  }

  private func readBoundedData(
    at url: URL,
    maximumByteCount: Int,
    tooLargeError: (Int) -> any Error
  ) throws -> Data {
    guard maximumByteCount >= 0 else {
      throw tooLargeError(0)
    }
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    if let size = (attributes[.size] as? NSNumber)?.uint64Value,
      size > UInt64(maximumByteCount)
    {
      throw tooLargeError(size > UInt64(Int.max) ? Int.max : Int(size))
    }

    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var data = Data()
    data.reserveCapacity(min((attributes[.size] as? NSNumber)?.intValue ?? 0, maximumByteCount))

    let chunkByteCount = 1024 * 1024
    while true {
      try Task.checkCancellation()
      let remainingByteCount = maximumByteCount - data.count
      let requestedByteCount = min(chunkByteCount, remainingByteCount + 1)
      let chunk = try handle.read(upToCount: requestedByteCount) ?? Data()
      guard !chunk.isEmpty else { break }

      let (nextByteCount, overflow) = data.count.addingReportingOverflow(chunk.count)
      guard !overflow, nextByteCount <= maximumByteCount else {
        throw tooLargeError(overflow ? Int.max : nextByteCount)
      }
      data.append(chunk)
    }
    return data
  }

  private func prepareRootDirectory() throws {
    if let applicationSupportURL {
      try prepareDirectory(
        at: applicationSupportURL,
        prepareForFileWrites: false
      )
    }
    try prepareDirectory(at: requiredRootURL())
  }

  private func prepareDirectory(
    at url: URL,
    prepareForFileWrites: Bool = true
  ) throws {
    let standardizedURL = url.standardizedFileURL
    guard !preparedDirectoryURLs.contains(standardizedURL) else { return }
    try durableFileWriter.createDirectoryIfNeeded(
      at: url,
      fileManager: fileManager,
      prepareForFileWrites: prepareForFileWrites
    )
    preparedDirectoryURLs.insert(standardizedURL)
  }

  private static func defaultApplicationSupportURL(fileManager: FileManager) -> URL? {
    try? fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return decoder
  }
}
