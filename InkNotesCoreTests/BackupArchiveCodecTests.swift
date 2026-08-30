import CryptoKit
import Foundation
import Testing

@testable import InkNotesCore

@Suite("InkNotes backup archive codec")
struct BackupArchiveCodecTests {
  @Test("A backup round trip preserves metadata and every drawing")
  func roundTrip() throws {
    let fixture = makeFixture()
    let backupID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

    let archive = try BackupArchiveCodec.encode(
      library: fixture.library,
      drawings: fixture.drawings,
      createdAt: createdAt,
      backupID: backupID,
      sourceAppVersion: "0.2.0",
      sourceBuild: "2"
    )
    let decoded = try BackupArchiveCodec.decode(archive)

    #expect(decoded.backupID == backupID)
    #expect(decoded.createdAt == createdAt)
    #expect(decoded.sourceAppVersion == "0.2.0")
    #expect(decoded.sourceBuild == "2")
    #expect(decoded.library == fixture.library)
    #expect(decoded.drawings == fixture.drawings)
    #expect(archive.count <= BackupArchiveLimits.maximumArchiveByteCount)
  }

  @Test("Encoding is deterministic when caller-provided metadata is fixed")
  func deterministicEncoding() throws {
    let fixture = makeFixture()
    let backupID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    let createdAt = Date(timeIntervalSince1970: 1_700_000_123.456)

    let first = try BackupArchiveCodec.encode(
      library: fixture.library,
      drawings: fixture.drawings,
      createdAt: createdAt,
      backupID: backupID
    )
    let second = try BackupArchiveCodec.encode(
      library: fixture.library,
      drawings: fixture.drawings,
      createdAt: createdAt,
      backupID: backupID
    )

    #expect(first == second)
  }

  @Test("Any payload tampering fails the archive checksum before import")
  func tamperedPayloadIsRejected() throws {
    let fixture = makeFixture()
    var archive = try BackupArchiveCodec.encode(
      library: fixture.library,
      drawings: fixture.drawings,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    archive[archive.count - 1] ^= 0x01

    #expect(throws: BackupArchiveError.archiveChecksumMismatch) {
      try BackupArchiveCodec.decode(archive)
    }
  }

  @Test("Truncated and trailing bytes are distinguished without decoding JSON")
  func malformedArchiveLengthIsRejected() throws {
    let fixture = makeFixture()
    let archive = try BackupArchiveCodec.encode(
      library: fixture.library,
      drawings: fixture.drawings,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    var truncated = archive
    truncated.removeLast()
    #expect(throws: BackupArchiveError.truncatedArchive) {
      try BackupArchiveCodec.decode(truncated)
    }

    var withTrailingData = archive
    withTrailingData.append(0x00)
    #expect(throws: BackupArchiveError.trailingData) {
      try BackupArchiveCodec.decode(withTrailingData)
    }
  }

  @Test("Every page must have exactly one drawing payload")
  func missingDrawingIsRejected() {
    let fixture = makeFixture()
    let incomplete = [fixture.firstPageID: Data([0x01])]

    #expect(throws: BackupArchiveError.drawingIndexMismatch) {
      try BackupArchiveCodec.encode(
        library: fixture.library,
        drawings: incomplete,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
      )
    }
  }

  @Test("Unknown versions and oversized manifest declarations are rejected from the header")
  func unsupportedHeaderFieldsAreRejected() throws {
    let fixture = makeFixture()
    let archive = try BackupArchiveCodec.encode(
      library: fixture.library,
      drawings: fixture.drawings,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    var unsupportedVersion = archive
    unsupportedVersion[8] = 0x00
    unsupportedVersion[9] = 0x02
    #expect(throws: BackupArchiveError.unsupportedVersion(found: 2)) {
      try BackupArchiveCodec.decode(unsupportedVersion)
    }

    var oversizedManifest = archive
    writeBigEndian(
      UInt32(BackupArchiveLimits.maximumManifestByteCount + 1),
      to: &oversizedManifest,
      at: 12
    )
    #expect(
      throws: BackupArchiveError.manifestTooLarge(
        actual: BackupArchiveLimits.maximumManifestByteCount + 1,
        maximum: BackupArchiveLimits.maximumManifestByteCount
      )
    ) {
      try BackupArchiveCodec.decode(oversizedManifest)
    }
  }

  @Test("Duplicate model identifiers and oversized titles are rejected before encoding")
  func invalidLibraryStructureIsRejected() {
    let fixture = makeFixture()
    let original = fixture.library.notebooks[0]
    let duplicateNotebook = Notebook(
      id: original.id,
      title: "重复标识",
      pages: [
        NotePage(
          id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
          title: "另一页"
        )
      ]
    )
    let duplicateLibrary = LibraryDocument(notebooks: [original, duplicateNotebook])
    var drawings = fixture.drawings
    drawings[duplicateNotebook.pages[0].id] = Data()

    #expect(throws: BackupArchiveError.duplicateNotebookID(original.id)) {
      try BackupArchiveCodec.encode(
        library: duplicateLibrary,
        drawings: drawings,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
      )
    }

    let duplicatePageID = original.pages[0].id
    let duplicatePageLibrary = LibraryDocument(notebooks: [
      original,
      Notebook(
        title: "另一笔记本",
        pages: [NotePage(id: duplicatePageID, title: "重复页面标识")]
      ),
    ])
    #expect(throws: BackupArchiveError.duplicatePageID(duplicatePageID)) {
      try BackupArchiveCodec.encode(
        library: duplicatePageLibrary,
        drawings: [duplicatePageID: Data()],
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
      )
    }

    #expect(throws: BackupArchiveError.invalidLibraryStructure) {
      try BackupArchiveCodec.encode(
        library: LibraryDocument(notebooks: []),
        drawings: [:],
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
      )
    }

    let invalidDateLibrary = LibraryDocument(notebooks: [
      Notebook(
        title: "无效时间",
        pages: [NotePage(title: "页面")],
        createdAt: Date(timeIntervalSince1970: .infinity)
      )
    ])
    #expect(throws: BackupArchiveError.invalidManifest) {
      try BackupArchiveCodec.encode(
        library: invalidDateLibrary,
        drawings: [:],
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
      )
    }

    let oversizedPage = NotePage(
      id: fixture.firstPageID,
      title: String(repeating: "a", count: BackupArchiveLimits.maximumTitleUTF8ByteCount + 1)
    )
    let oversizedTitleLibrary = LibraryDocument(
      notebooks: [Notebook(title: "标题限制", pages: [oversizedPage])]
    )
    #expect(throws: BackupArchiveError.invalidTitle) {
      try BackupArchiveCodec.encode(
        library: oversizedTitleLibrary,
        drawings: [oversizedPage.id: Data()],
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
      )
    }
  }

  @Test("A canonical archive with an invalid per-page digest is rejected")
  func drawingChecksumMismatchIsRejected() throws {
    let fixture = makeFixture()
    let entries = fixture.library.notebooks[0].pages
      .map(\.id)
      .sorted(by: { $0.uuidString < $1.uuidString })
      .enumerated()
      .map { index, pageID in
        BackupDrawingEntry(
          pageID: pageID,
          offset: UInt64(index),
          byteCount: 1,
          sha256: String(repeating: "0", count: 64)
        )
      }
    let manifest = BackupArchiveManifest(
      backupID: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      sourceAppVersion: "0.2.0",
      sourceBuild: "2",
      librarySchemaVersion: fixture.library.schemaVersion,
      library: fixture.library,
      drawings: entries
    )
    let archive = try makeRawArchive(manifest: manifest, payload: Data([0x01, 0x02]))

    #expect(throws: BackupArchiveError.drawingChecksumMismatch(pageID: entries[0].pageID)) {
      try BackupArchiveCodec.decode(archive)
    }
  }

  @Test("Duplicate drawing entries are rejected even when the outer checksum is valid")
  func duplicateDrawingEntryIsRejected() throws {
    let fixture = makeFixture()
    let pageID = fixture.firstPageID
    let emptyDigest = sha256Hex(Data())
    let entries = [
      BackupDrawingEntry(pageID: pageID, offset: 0, byteCount: 0, sha256: emptyDigest),
      BackupDrawingEntry(pageID: pageID, offset: 0, byteCount: 0, sha256: emptyDigest),
    ]
    let manifest = BackupArchiveManifest(
      backupID: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      sourceAppVersion: "",
      sourceBuild: "",
      librarySchemaVersion: fixture.library.schemaVersion,
      library: fixture.library,
      drawings: entries
    )
    let archive = try makeRawArchive(manifest: manifest, payload: Data())

    #expect(throws: BackupArchiveError.duplicateDrawingEntry(pageID)) {
      try BackupArchiveCodec.decode(archive)
    }
  }

  @Test("Magic, flags, and minimum header length are validated before body access")
  func basicHeaderGuardsAreEnforced() throws {
    #expect(throws: BackupArchiveError.truncatedHeader) {
      try BackupArchiveCodec.decode(Data())
    }
    #expect(throws: BackupArchiveError.invalidMagic) {
      try BackupArchiveCodec.decode(Data(repeating: 0, count: BackupArchiveCodec.headerByteCount))
    }

    let fixture = makeFixture()
    var unsupportedFlags = try BackupArchiveCodec.encode(
      library: fixture.library,
      drawings: fixture.drawings,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    unsupportedFlags[10] = 0x00
    unsupportedFlags[11] = 0x01
    #expect(throws: BackupArchiveError.unsupportedFlags(found: 1)) {
      try BackupArchiveCodec.decode(unsupportedFlags)
    }
  }

  @Test("Manifest and embedded library schema versions must agree")
  func inconsistentSchemaIsRejected() throws {
    let fixture = makeFixture()
    let validArchive = try BackupArchiveCodec.encode(
      library: fixture.library,
      drawings: fixture.drawings,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let valid = try BackupArchiveCodec.decode(validArchive)
    let manifest = BackupArchiveManifest(
      backupID: valid.backupID,
      createdAt: valid.createdAt,
      sourceAppVersion: valid.sourceAppVersion,
      sourceBuild: valid.sourceBuild,
      librarySchemaVersion: LibraryDocument.currentSchemaVersion + 1,
      library: valid.library,
      drawings: drawingEntries(for: valid.library, drawings: valid.drawings)
    )
    let payload = payload(for: valid.library, drawings: valid.drawings)
    let archive = try makeRawArchive(manifest: manifest, payload: payload)

    #expect(throws: BackupArchiveError.inconsistentLibrarySchema) {
      try BackupArchiveCodec.decode(archive)
    }
  }

  @Test("Offsets must be canonical and drawing digests must be lowercase SHA-256")
  func drawingLayoutAndDigestFormatAreValidated() throws {
    let fixture = makeFixture()
    let pageIDs = fixture.library.notebooks.flatMap(\.pages).map(\.id)
      .sorted(by: { $0.uuidString < $1.uuidString })
    let firstDrawing = try #require(fixture.drawings[pageIDs[0]])
    let secondDrawing = try #require(fixture.drawings[pageIDs[1]])

    let invalidLayoutEntries = [
      BackupDrawingEntry(
        pageID: pageIDs[0],
        offset: 1,
        byteCount: UInt64(firstDrawing.count),
        sha256: sha256Hex(firstDrawing)
      ),
      BackupDrawingEntry(
        pageID: pageIDs[1],
        offset: UInt64(firstDrawing.count + 1),
        byteCount: UInt64(secondDrawing.count),
        sha256: sha256Hex(secondDrawing)
      ),
    ]
    let invalidLayoutManifest = makeManifest(
      library: fixture.library,
      entries: invalidLayoutEntries
    )
    let archiveWithInvalidLayout = try makeRawArchive(
      manifest: invalidLayoutManifest,
      payload: firstDrawing + secondDrawing
    )
    #expect(throws: BackupArchiveError.invalidDrawingLayout) {
      try BackupArchiveCodec.decode(archiveWithInvalidLayout)
    }

    var invalidDigestEntries = drawingEntries(
      for: fixture.library,
      drawings: fixture.drawings
    )
    invalidDigestEntries[0] = BackupDrawingEntry(
      pageID: invalidDigestEntries[0].pageID,
      offset: invalidDigestEntries[0].offset,
      byteCount: invalidDigestEntries[0].byteCount,
      sha256: String(repeating: "A", count: 64)
    )
    let invalidDigestManifest = makeManifest(
      library: fixture.library,
      entries: invalidDigestEntries
    )
    let archiveWithInvalidDigest = try makeRawArchive(
      manifest: invalidDigestManifest,
      payload: payload(for: fixture.library, drawings: fixture.drawings)
    )
    #expect(
      throws: BackupArchiveError.invalidDrawingDigest(
        pageID: invalidDigestEntries[0].pageID
      )
    ) {
      try BackupArchiveCodec.decode(archiveWithInvalidDigest)
    }
  }

  private func makeFixture() -> (
    library: LibraryDocument,
    drawings: [UUID: Data],
    firstPageID: UUID
  ) {
    let notebookID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    let firstPageID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    let secondPageID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
    let createdAt = Date(timeIntervalSince1970: 1_690_000_000)
    let updatedAt = Date(timeIntervalSince1970: 1_690_000_100)
    let firstPage = NotePage(
      id: firstPageID,
      title: "第一页",
      background: .ruled,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
    let secondPage = NotePage(
      id: secondPageID,
      title: "空白页",
      background: .blank,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
    let notebook = Notebook(
      id: notebookID,
      title: "备份测试",
      pages: [firstPage, secondPage],
      createdAt: createdAt,
      updatedAt: updatedAt
    )
    return (
      LibraryDocument(notebooks: [notebook]),
      [firstPageID: Data([0x49, 0x4E, 0x4B]), secondPageID: Data()],
      firstPageID
    )
  }

  private func makeRawArchive(
    manifest: BackupArchiveManifest,
    payload: Data
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    let manifestData = try encoder.encode(manifest)

    var prefix = Data([0x49, 0x4E, 0x4B, 0x4E, 0x4F, 0x54, 0x45, 0x00])
    // Keep the handcrafted archive independent from the production version constant.
    appendBigEndian(UInt16(1), to: &prefix)
    appendBigEndian(UInt16(0), to: &prefix)
    appendBigEndian(UInt32(manifestData.count), to: &prefix)
    appendBigEndian(UInt64(payload.count), to: &prefix)

    var hasher = SHA256()
    hasher.update(data: prefix)
    hasher.update(data: manifestData)
    hasher.update(data: payload)

    var result = prefix
    result.append(Data(hasher.finalize()))
    result.append(manifestData)
    result.append(payload)
    return result
  }

  private func makeManifest(
    library: LibraryDocument,
    entries: [BackupDrawingEntry]
  ) -> BackupArchiveManifest {
    BackupArchiveManifest(
      backupID: UUID(uuidString: "10000000-0000-0000-0000-000000000005")!,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      sourceAppVersion: "0.2.0",
      sourceBuild: "2",
      librarySchemaVersion: library.schemaVersion,
      library: library,
      drawings: entries
    )
  }

  private func drawingEntries(
    for library: LibraryDocument,
    drawings: [UUID: Data]
  ) -> [BackupDrawingEntry] {
    var offset: UInt64 = 0
    return library.notebooks.flatMap(\.pages).map(\.id)
      .sorted(by: { $0.uuidString < $1.uuidString })
      .map { pageID in
        let drawing = drawings[pageID] ?? Data()
        defer { offset += UInt64(drawing.count) }
        return BackupDrawingEntry(
          pageID: pageID,
          offset: offset,
          byteCount: UInt64(drawing.count),
          sha256: sha256Hex(drawing)
        )
      }
  }

  private func payload(
    for library: LibraryDocument,
    drawings: [UUID: Data]
  ) -> Data {
    var result = Data()
    for pageID in library.notebooks.flatMap(\.pages).map(\.id)
      .sorted(by: { $0.uuidString < $1.uuidString })
    {
      result.append(drawings[pageID] ?? Data())
    }
    return result
  }

  private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func appendBigEndian(_ value: UInt16, to data: inout Data) {
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
  }

  private func appendBigEndian(_ value: UInt32, to data: inout Data) {
    for shift in stride(from: 24, through: 0, by: -8) {
      data.append(UInt8((value >> UInt32(shift)) & 0xFF))
    }
  }

  private func appendBigEndian(_ value: UInt64, to data: inout Data) {
    for shift in stride(from: 56, through: 0, by: -8) {
      data.append(UInt8((value >> UInt64(shift)) & 0xFF))
    }
  }

  private func writeBigEndian(_ value: UInt32, to data: inout Data, at offset: Int) {
    for (index, shift) in stride(from: 24, through: 0, by: -8).enumerated() {
      data[offset + index] = UInt8((value >> UInt32(shift)) & 0xFF)
    }
  }
}
