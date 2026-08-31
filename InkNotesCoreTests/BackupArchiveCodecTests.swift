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
    #expect(decoded.pageSources.isEmpty)
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

  @Test("Compatible backups stay v1 while oversized pages move to chunked v2")
  func bestAvailableFormatIsSelectedWithoutChangingTheFileIdentity() throws {
    let fixture = makeFixture()
    let smallArchive = try BackupArchiveCodec.encodeBestAvailable(
      library: fixture.library,
      drawings: fixture.drawings,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let smallDecoded = try BackupArchiveCodec.decode(smallArchive)
    #expect(readUInt16(smallArchive, at: 8) == BackupArchiveCodec.legacyFormatVersion)
    #expect(smallDecoded.formatVersion == BackupArchiveCodec.legacyFormatVersion)
    #expect(smallDecoded.drawings == fixture.drawings)

    let longPageID = fixture.firstPageID
    let largeDrawing = Data(
      repeating: 0xA5,
      count: BackupArchiveLimits.maximumLegacyDrawingByteCount + 1
    )
    var largeDrawings = fixture.drawings
    largeDrawings[longPageID] = largeDrawing
    let largeArchive = try BackupArchiveCodec.encodeBestAvailable(
      library: fixture.library,
      drawings: largeDrawings,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let largeDecoded = try BackupArchiveCodec.decode(largeArchive)

    #expect(readUInt16(largeArchive, at: 8) == BackupArchiveCodec.currentFormatVersion)
    #expect(largeDecoded.formatVersion == BackupArchiveCodec.currentFormatVersion)
    #expect(largeDecoded.drawings == largeDrawings)
    #expect(largeDecoded.pageSources.isEmpty)
    #expect(largeArchive.count <= BackupArchiveLimits.maximumArchiveByteCount)

    let manifestStart = BackupArchiveCodec.headerByteCount
    let manifestEnd = manifestStart + Int(readUInt32(largeArchive, at: 12))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let manifest = try decoder.decode(
      BackupArchiveManifestV2.self,
      from: largeArchive.subdata(in: manifestStart..<manifestEnd)
    )
    let largePage = try #require(manifest.pages.first { $0.pageID == longPageID })
    #expect(largePage.chunks.count == 9)
    #expect(
      largePage.chunks.allSatisfy {
        $0.byteCount > 0
          && $0.byteCount <= UInt64(BackupArchiveLimits.maximumPayloadChunkByteCount)
      }
    )

    var internallyTampered = largeArchive
    internallyTampered[internallyTampered.count - 1] ^= 0x01
    rewriteArchiveChecksum(&internallyTampered)
    #expect(throws: BackupArchiveError.drawingChecksumMismatch(pageID: longPageID)) {
      try BackupArchiveCodec.decode(internallyTampered)
    }
  }

  @Test("Page sources select v3 and remain attached to their page")
  func pageSourcesRoundTripInVersionThree() throws {
    let fixture = makeFixture()
    let source = PageSourceExcerpt(
      id: UUID(uuidString: "70000000-0000-0000-0000-000000000001")!,
      title: "参考页面",
      excerpt: "用户主动保存的文字",
      sourceURL: URL(string: "https://example.com/reference")!,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_010)
    )
    let archive = try BackupArchiveCodec.encodeBestAvailable(
      library: fixture.library,
      drawings: fixture.drawings,
      pageSources: [fixture.firstPageID: [source]],
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let decoded = try BackupArchiveCodec.decode(archive)

    #expect(readUInt16(archive, at: 8) == BackupArchiveCodec.pageSourceFormatVersion)
    #expect(decoded.formatVersion == BackupArchiveCodec.pageSourceFormatVersion)
    #expect(decoded.drawings == fixture.drawings)
    #expect(decoded.pageSources == [fixture.firstPageID: [source]])
  }

  @Test("Page source archives reject unknown pages and duplicate page records")
  func invalidPageSourcesFailClosed() throws {
    let fixture = makeFixture()
    let source = PageSourceExcerpt(
      title: "参考页面",
      excerpt: "用户主动保存的文字",
      sourceURL: URL(string: "https://example.com/reference")!,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_010)
    )
    #expect(throws: BackupArchiveError.invalidPageSources) {
      try BackupArchiveCodec.encodeV3(
        library: fixture.library,
        drawings: fixture.drawings,
        pageSources: [UUID(): [source]],
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
      )
    }

    let archive = try BackupArchiveCodec.encodeV3(
      library: fixture.library,
      drawings: fixture.drawings,
      pageSources: [fixture.firstPageID: [source]],
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let manifestStart = BackupArchiveCodec.headerByteCount
    let manifestEnd = manifestStart + Int(readUInt32(archive, at: 12))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let manifest = try decoder.decode(
      BackupArchiveManifestV3.self,
      from: archive.subdata(in: manifestStart..<manifestEnd)
    )
    let duplicated = BackupArchiveManifestV3(
      backupID: manifest.backupID,
      createdAt: manifest.createdAt,
      sourceAppVersion: manifest.sourceAppVersion,
      sourceBuild: manifest.sourceBuild,
      librarySchemaVersion: manifest.librarySchemaVersion,
      library: manifest.library,
      pages: manifest.pages,
      pageSources: manifest.pageSources + manifest.pageSources
    )
    let payload = archive.suffix(from: manifestEnd)
    let duplicateArchive = try makeRawVersionThreeArchive(
      manifest: duplicated,
      payload: Data(payload)
    )
    #expect(throws: BackupArchiveError.duplicatePageSources(fixture.firstPageID)) {
      try BackupArchiveCodec.decode(duplicateArchive)
    }
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
    unsupportedVersion[9] = 0x04
    #expect(throws: BackupArchiveError.unsupportedVersion(found: 4)) {
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

  @Test("The manifest projection bounds adversarial legal metadata")
  func projectedManifestBoundsEncodedManifest() throws {
    let title =
      "x"
      + String(
        repeating: "\0",
        count: BackupArchiveLimits.maximumTitleUTF8ByteCount - 1
      )
    let pageID = UUID(uuidString: "30000000-0000-0000-0000-000000000010")!
    let date = Date(timeIntervalSince1970: Double.greatestFiniteMagnitude)
    let library = LibraryDocument(notebooks: [
      Notebook(
        id: UUID(uuidString: "20000000-0000-0000-0000-000000000010")!,
        title: title,
        pages: [
          NotePage(
            id: pageID,
            title: title,
            background: .grid,
            createdAt: date,
            updatedAt: date
          )
        ],
        createdAt: date,
        updatedAt: date
      )
    ])
    let archive = try BackupArchiveCodec.encode(
      library: library,
      drawings: [pageID: Data([0x01, 0x02, 0x03])],
      createdAt: date,
      backupID: UUID(uuidString: "10000000-0000-0000-0000-000000000010")!,
      sourceAppVersion: String(
        repeating: "\0",
        count: BackupArchiveLimits.maximumSourceMetadataUTF8ByteCount
      ),
      sourceBuild: String(
        repeating: "\0",
        count: BackupArchiveLimits.maximumSourceMetadataUTF8ByteCount
      )
    )
    let actualManifestByteCount = Int(readUInt32(archive, at: 12))
    let projectedByteCount = try BackupArchiveCodec.projectedManifestByteCount(for: library)

    #expect(projectedByteCount >= actualManifestByteCount)
    try BackupArchiveCodec.validateProjectedManifestBudget(library)
  }

  @Test("The projected v1 manifest budget has an enforced production boundary")
  func projectedManifestBudgetBoundaryIsEnforced() throws {
    let fixture = try makeManifestBudgetTestFixture()
    let exactByteCount = try BackupArchiveCodec.projectedManifestByteCount(for: fixture.exact)
    let overflowingByteCount = try BackupArchiveCodec.projectedManifestByteCount(
      for: fixture.oneByteOver
    )

    #expect(exactByteCount == 2_097_152)
    #expect(exactByteCount == BackupArchiveLimits.maximumManifestByteCount)
    #expect(overflowingByteCount == 2_097_153)
    try BackupArchiveCodec.validateProjectedManifestBudget(fixture.exact)
    #expect(
      throws: BackupArchiveError.manifestTooLarge(
        actual: overflowingByteCount,
        maximum: BackupArchiveLimits.maximumManifestByteCount
      )
    ) {
      try BackupArchiveCodec.validateProjectedManifestBudget(fixture.oneByteOver)
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

  private func makeRawVersionThreeArchive(
    manifest: BackupArchiveManifestV3,
    payload: Data
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    let manifestData = try encoder.encode(manifest)

    var prefix = Data([0x49, 0x4E, 0x4B, 0x4E, 0x4F, 0x54, 0x45, 0x00])
    appendBigEndian(UInt16(3), to: &prefix)
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

  private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
    (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
  }

  private func rewriteArchiveChecksum(_ archive: inout Data) {
    var hasher = SHA256()
    hasher.update(data: archive.prefix(24))
    hasher.update(data: archive.suffix(from: BackupArchiveCodec.headerByteCount))
    archive.replaceSubrange(
      24..<BackupArchiveCodec.headerByteCount,
      with: Data(hasher.finalize())
    )
  }

  private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    var value: UInt32 = 0
    for index in offset..<(offset + 4) {
      value = (value << 8) | UInt32(data[index])
    }
    return value
  }
}
