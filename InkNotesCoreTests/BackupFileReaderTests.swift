import Foundation
import Testing

@testable import InkNotesCore

@Suite("External backup file reader")
struct BackupFileReaderTests {
  @Test("A regular file may use the exact configured byte limit")
  func exactLimitAndOversize() async throws {
    try await withTemporaryDirectory { rootURL in
      let expected = Data((0..<128).map(UInt8.init))
      let exactURL = rootURL.appendingPathComponent("exact.notesbackup")
      try expected.write(to: exactURL, options: .atomic)

      let reader = BackupFileReader(maximumByteCount: 128, chunkByteCount: 17)
      #expect(try await reader.read(from: exactURL) == expected)

      let oversizedURL = rootURL.appendingPathComponent("oversized.notesbackup")
      try (expected + Data([0xFF])).write(to: oversizedURL, options: .atomic)
      await #expect(throws: BackupFileReaderError.fileTooLarge(maximum: 128)) {
        try await reader.read(from: oversizedURL)
      }
    }
  }

  @Test("Directories and symbolic links are rejected before reading")
  func nonRegularFiles() async throws {
    try await withTemporaryDirectory { rootURL in
      let reader = BackupFileReader(maximumByteCount: 128, chunkByteCount: 16)
      await #expect(throws: BackupFileReaderError.fileIsNotRegular) {
        try await reader.read(from: rootURL)
      }

      let targetURL = rootURL.appendingPathComponent("target.notesbackup")
      let linkURL = rootURL.appendingPathComponent("link.notesbackup")
      try Data([0x49, 0x4E, 0x4B]).write(to: targetURL)
      try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
      await #expect(throws: BackupFileReaderError.symbolicLink) {
        try await reader.read(from: linkURL)
      }
    }
  }

  @Test("Non-file URLs fail closed")
  func unsupportedURL() async throws {
    let url = try #require(URL(string: "https://example.invalid/history.notesbackup"))
    await #expect(throws: BackupFileReaderError.unsupportedURL) {
      try await BackupFileReader(maximumByteCount: 128).read(from: url)
    }
  }

  @Test("A task cancelled before file access remains cancelled")
  func preCancelledRead() async throws {
    try await withTemporaryDirectory { rootURL in
      let fileURL = rootURL.appendingPathComponent("cancelled.notesbackup")
      try Data(repeating: 0x41, count: 128).write(to: fileURL)
      let gate = BackupFileReaderStartGate()
      let reader = BackupFileReader(maximumByteCount: 128, chunkByteCount: 16)
      let task = Task {
        await gate.waitUntilOpened()
        return try await reader.read(from: fileURL)
      }

      task.cancel()
      await gate.open()

      await #expect(throws: CancellationError.self) {
        try await task.value
      }
    }
  }

  @Test("Only a direct system Inbox copy is removed after external-open reading")
  func inboxCopyCleanupBoundary() throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxURL = rootURL.appendingPathComponent("Documents/Inbox", isDirectory: true)
    try fileManager.createDirectory(at: inboxURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: rootURL) }

    let inboxCopyURL = inboxURL.appendingPathComponent("opened.notesbackup")
    let userSelectedURL = rootURL.appendingPathComponent("user-selected.notesbackup")
    let nestedURL = inboxURL.appendingPathComponent("nested/keep.notesbackup")
    let directoryURL = inboxURL.appendingPathComponent("not-a-file.notesbackup", isDirectory: true)
    try Data([0x49, 0x4E, 0x4B]).write(to: inboxCopyURL)
    try Data([0x4E, 0x4F, 0x54, 0x45]).write(to: userSelectedURL)
    try fileManager.createDirectory(
      at: nestedURL.deletingLastPathComponent(),
      withIntermediateDirectories: false
    )
    try Data([0x4B, 0x45, 0x45, 0x50]).write(to: nestedURL)
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: false)
    let cleaner = BackupInboxCopyCleaner(inboxURL: inboxURL)

    #expect(try cleaner.removeIfInboxCopy(at: userSelectedURL) == false)
    #expect(fileManager.fileExists(atPath: userSelectedURL.path))
    #expect(try cleaner.removeIfInboxCopy(at: nestedURL) == false)
    #expect(fileManager.fileExists(atPath: nestedURL.path))
    #expect(try cleaner.removeIfInboxCopy(at: inboxCopyURL))
    #expect(!fileManager.fileExists(atPath: inboxCopyURL.path))
    #expect(throws: POSIXError.self) {
      try cleaner.removeIfInboxCopy(at: directoryURL)
    }
    #expect(fileManager.fileExists(atPath: directoryURL.path))
  }

  private func withTemporaryDirectory<T>(
    _ operation: (URL) async throws -> T
  ) async throws -> T {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: false)
    defer { try? fileManager.removeItem(at: rootURL) }
    return try await operation(rootURL)
  }
}

private actor BackupFileReaderStartGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func waitUntilOpened() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open() {
    isOpen = true
    let pendingWaiters = waiters
    waiters.removeAll()
    for waiter in pendingWaiters {
      waiter.resume()
    }
  }
}
