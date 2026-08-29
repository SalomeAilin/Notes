import CryptoKit
import Foundation
import PencilKit
import Testing

@testable import InkNotesCore

@Suite("InkNotes compatibility contract")
struct CompatibilityContractTests {
  private let expectedBundleIdentifier = "com.salomeailin.InkNotes"
  private let backupID = UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!
  private let notebookID = UUID(uuidString: "B2000000-0000-0000-0000-000000000001")!
  private let blankPageID = UUID(uuidString: "C3000000-0000-0000-0000-000000000001")!
  private let ruledPageID = UUID(uuidString: "C3000000-0000-0000-0000-000000000002")!
  private let gridPageID = UUID(uuidString: "C3000000-0000-0000-0000-000000000003")!

  @Test("Persisted identities remain independent from the display name")
  func persistedIdentityConstantsRemainStable() {
    #expect(DrawingRepository.persistedDirectoryName == "InkNotes")
    #expect(DrawingRepository.libraryFilename == "library.json")
    #expect(DrawingRepository.drawingsDirectoryName == "Drawings")
    #expect(DrawingRepository.drawingFileExtension == "drawing")
    #expect(DrawingRepository.defaultRootURL().lastPathComponent == "InkNotes")

    #expect(BackupArchiveCodec.uniformTypeIdentifier == "com.salomeailin.notes.backup")
    #expect(BackupArchiveCodec.fileExtension == "notesbackup")
    #expect(BackupArchiveCodec.mimeType == "application/vnd.salomeailin.notes-backup")
    #expect(BackupArchiveCodec.magic == Data([0x49, 0x4E, 0x4B, 0x4E, 0x4F, 0x54, 0x45, 0x00]))
    #expect(BackupArchiveCodec.formatVersion == 1)
    #expect(BackupArchiveCodec.headerByteCount == 56)
    #expect(LibraryDocument.currentSchemaVersion == 1)
  }

  @Test("Repository writes the historical directory and filename layout")
  func historicalPersistenceLayoutRemainsStable() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: rootURL) }

    let pageID = UUID(uuidString: "ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB")!
    let page = NotePage(
      id: pageID,
      title: "兼容性路径",
      createdAt: Date(timeIntervalSince1970: 1_690_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_690_000_100)
    )
    let notebook = Notebook(
      id: notebookID,
      title: "兼容性测试",
      pages: [page],
      createdAt: page.createdAt,
      updatedAt: page.updatedAt
    )
    let repository = DrawingRepository(rootURL: rootURL)

    try await repository.saveLibrary(LibraryDocument(notebooks: [notebook]))
    try await repository.saveDrawing(Data([0x49, 0x4E, 0x4B]), pageID: pageID)

    let libraryURL = rootURL.appendingPathComponent("library.json", isDirectory: false)
    let drawingURL =
      rootURL
      .appendingPathComponent("Drawings", isDirectory: true)
      .appendingPathComponent("ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB.drawing")
    #expect(fileManager.fileExists(atPath: libraryURL.path))
    #expect(fileManager.fileExists(atPath: drawingURL.path))
  }

  @Test("Project metadata retains app and backup file identities")
  func projectMetadataRemainsCompatible() throws {
    let repositoryRoot = repositoryRootURL()
    let plistURL = repositoryRoot.appendingPathComponent("InkNotes/Info.plist")
    let plistData = try Data(contentsOf: plistURL)
    let plist = try #require(
      try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
        as? [String: Any]
    )
    let declarations = try #require(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
    let declaration = try #require(declarations.first)
    let tags = try #require(declaration["UTTypeTagSpecification"] as? [String: Any])
    let extensions = try #require(tags["public.filename-extension"] as? [String])

    #expect(declaration["UTTypeIdentifier"] as? String == BackupArchiveCodec.uniformTypeIdentifier)
    #expect(extensions == [BackupArchiveCodec.fileExtension])
    #expect(tags["public.mime-type"] as? String == BackupArchiveCodec.mimeType)

    let projectURL = repositoryRoot.appendingPathComponent("InkNotes.xcodeproj/project.pbxproj")
    let projectText = try String(contentsOf: projectURL, encoding: .utf8)
    let expectedSetting = "PRODUCT_BUNDLE_IDENTIFIER = \(expectedBundleIdentifier);"
    #expect(projectText.components(separatedBy: expectedSetting).count - 1 == 2)
  }

  @Test("The committed v1 archive remains byte-for-byte readable and writable")
  func goldenVersionOneArchiveRemainsCompatible() throws {
    let archiveURL = try fixtureURL(
      named: "reference-v1",
      extension: "notesbackup"
    )
    let drawingURL = try fixtureURL(
      named: "serialized-empty-v1",
      extension: "pkdrawing"
    )
    let archive = try Data(contentsOf: archiveURL)
    let serializedDrawing = try Data(contentsOf: drawingURL)

    #expect(archive.count == 1_283)
    #expect(
      sha256Hex(archive) == "b42c7ce5a106f8b7825ecc2f8c080f9b2bf2e27ede091f9b6e80ed5292e36911")
    #expect(serializedDrawing.count == 42)
    #expect(
      sha256Hex(serializedDrawing)
        == "6d071041f843471f3a763b2f7051c12544d43228d5eab4716b917c92df408a08")
    #expect(Array(archive[0..<8]) == [0x49, 0x4E, 0x4B, 0x4E, 0x4F, 0x54, 0x45, 0x00])
    #expect(readUInt16(archive, at: 8) == 1)
    #expect(readUInt16(archive, at: 10) == 0)
    #expect(readUInt32(archive, at: 12) == 1_185)
    #expect(readUInt64(archive, at: 16) == 42)
    _ = try PKDrawing(data: serializedDrawing)

    let expectedLibrary = makeGoldenLibrary()
    let expectedDrawings = [
      blankPageID: Data(),
      ruledPageID: serializedDrawing,
      gridPageID: Data(),
    ]
    let decoded = try BackupArchiveCodec.decode(archive)
    #expect(decoded.backupID == backupID)
    #expect(decoded.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(decoded.sourceAppVersion == "0.2.0")
    #expect(decoded.sourceBuild == "2")
    #expect(decoded.library == expectedLibrary)
    #expect(decoded.drawings == expectedDrawings)

    let reencoded = try BackupArchiveCodec.encode(
      library: expectedLibrary,
      drawings: expectedDrawings,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      backupID: backupID,
      sourceAppVersion: "0.2.0",
      sourceBuild: "2"
    )
    #expect(reencoded == archive)
  }

  private func makeGoldenLibrary() -> LibraryDocument {
    let createdAt = Date(timeIntervalSince1970: 1_690_000_000)
    let updatedAt = Date(timeIntervalSince1970: 1_690_000_100)
    let pages = [
      NotePage(
        id: blankPageID,
        title: "空白页",
        background: .blank,
        createdAt: createdAt,
        updatedAt: updatedAt
      ),
      NotePage(
        id: ruledPageID,
        title: "横线页",
        background: .ruled,
        createdAt: createdAt,
        updatedAt: updatedAt
      ),
      NotePage(
        id: gridPageID,
        title: "方格页",
        background: .grid,
        createdAt: createdAt,
        updatedAt: updatedAt
      ),
    ]
    return LibraryDocument(
      notebooks: [
        Notebook(
          id: notebookID,
          title: "历史备份样本",
          pages: pages,
          createdAt: createdAt,
          updatedAt: updatedAt
        )
      ]
    )
  }

  private func fixtureURL(named name: String, extension fileExtension: String) throws -> URL {
    try #require(
      Bundle.module.url(
        forResource: name,
        withExtension: fileExtension,
        subdirectory: "Fixtures/BackupV1"
      )
    )
  }

  private func repositoryRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
    (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
  }

  private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    var value: UInt32 = 0
    for index in 0..<4 {
      value = (value << 8) | UInt32(data[offset + index])
    }
    return value
  }

  private func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for index in 0..<8 {
      value = (value << 8) | UInt64(data[offset + index])
    }
    return value
  }
}
