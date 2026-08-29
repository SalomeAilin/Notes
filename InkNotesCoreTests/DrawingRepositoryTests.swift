import Foundation
import Testing

@testable import InkNotesCore

@Suite("InkNotes local persistence")
struct DrawingRepositoryTests {
  @Test("Default storage resolution fails closed without Application Support")
  func defaultStorageResolutionFailsClosed() async {
    let fileManager = ApplicationSupportUnavailableFileManager()
    let isolatedTemporaryDirectory = fileManager.temporaryDirectory
    defer { try? FileManager.default.removeItem(at: isolatedTemporaryDirectory) }
    let temporaryFallback = isolatedTemporaryDirectory
      .appendingPathComponent(DrawingRepository.persistedDirectoryName, isDirectory: true)

    #expect(DrawingRepository.defaultRootURL(fileManager: fileManager) == nil)
    let repository = DrawingRepository(fileManager: fileManager)
    await #expect(throws: DrawingRepositoryError.persistenceDirectoryUnavailable) {
      _ = try await repository.loadLibrary()
    }
    await #expect(throws: DrawingRepositoryError.persistenceDirectoryUnavailable) {
      try await repository.saveLibrary(LibraryDocument.starter())
    }
    #expect(!FileManager.default.fileExists(atPath: temporaryFallback.path))
  }

  @Test("The store enters read-only protection when permanent storage is unavailable")
  @MainActor
  func storeProtectsUnavailablePermanentStorage() async throws {
    let fileManager = ApplicationSupportUnavailableFileManager()
    let isolatedTemporaryDirectory = fileManager.temporaryDirectory
    defer { try? FileManager.default.removeItem(at: isolatedTemporaryDirectory) }
    let temporaryFallback = isolatedTemporaryDirectory
      .appendingPathComponent(DrawingRepository.persistedDirectoryName, isDirectory: true)
    let repository = DrawingRepository(fileManager: fileManager)
    let store = LibraryStore(repository: repository)

    for _ in 0..<100 {
      if !store.isLoading { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(!store.isLoading)
    #expect(store.isReadOnly)
    #expect(store.persistenceError?.contains("永久存储目录") == true)
    #expect(!FileManager.default.fileExists(atPath: temporaryFallback.path))
  }

  @Test("Library metadata and drawing bytes survive a round trip")
  func roundTrip() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let repository = DrawingRepository(rootURL: rootURL)
    let library = LibraryDocument.starter()
    let pageID = try #require(library.notebooks.first?.pages.first?.id)
    let drawing = Data([0x49, 0x4E, 0x4B])

    try await repository.saveLibrary(library)
    try await repository.saveDrawing(drawing, pageID: pageID)

    let restored = try #require(try await repository.loadLibrary())
    #expect(restored.schemaVersion == library.schemaVersion)
    #expect(restored.notebooks.map(\.id) == library.notebooks.map(\.id))
    #expect(restored.notebooks.map(\.title) == library.notebooks.map(\.title))
    #expect(
      restored.notebooks.flatMap(\.pages).map(\.id) == library.notebooks.flatMap(\.pages).map(\.id))
    #expect(
      abs(restored.notebooks[0].updatedAt.timeIntervalSince(library.notebooks[0].updatedAt)) < 0.001
    )
    #expect(try await repository.loadDrawing(pageID: pageID) == drawing)
  }

  @Test("A corrupt library is reported and remains untouched")
  func corruptLibraryIsNotOverwritten() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: rootURL) }

    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let libraryURL = rootURL.appendingPathComponent("library.json")
    let original = Data("not-json".utf8)
    try original.write(to: libraryURL)

    let repository = DrawingRepository(rootURL: rootURL)
    do {
      _ = try await repository.loadLibrary()
      Issue.record("Expected corrupt JSON to throw")
    } catch {
      #expect(try Data(contentsOf: libraryURL) == original)
    }
  }
}

private final class ApplicationSupportUnavailableFileManager: FileManager, @unchecked Sendable {
  private let isolatedTemporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)

  override var temporaryDirectory: URL {
    isolatedTemporaryDirectory
  }

  override func urls(
    for directory: FileManager.SearchPathDirectory,
    in domainMask: FileManager.SearchPathDomainMask
  ) -> [URL] {
    []
  }
}
