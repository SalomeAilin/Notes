import Foundation
import Testing

@testable import InkNotesCore

@Suite("InkNotes local persistence")
struct DrawingRepositoryTests {
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
