import CryptoKit
import Foundation

enum BackupArchiveCodec {
  static let uniformTypeIdentifier = "com.salomeailin.notes.backup"
  static let fileExtension = "notesbackup"
  static let mimeType = "application/vnd.salomeailin.notes-backup"
  static let formatVersion: UInt16 = 1
  static let headerByteCount = 56

  static let magic = Data([0x49, 0x4E, 0x4B, 0x4E, 0x4F, 0x54, 0x45, 0x00])
  private static let supportedFlags: UInt16 = 0
  private static let projectionBackupID = UUID(
    uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
  )!
  private static let projectionDate = Date(
    timeIntervalSince1970: -Double.greatestFiniteMagnitude
  )
  private static let projectionSourceMetadata = String(
    repeating: "\0",
    count: BackupArchiveLimits.maximumSourceMetadataUTF8ByteCount
  )
  private static let projectionDigest = String(repeating: "f", count: 64)

  static func encode(
    library: LibraryDocument,
    drawings: [UUID: Data],
    createdAt: Date,
    backupID: UUID = UUID(),
    sourceAppVersion: String = "",
    sourceBuild: String = ""
  ) throws -> Data {
    let pageIDs = try validateLibrary(library)
    try validateSourceMetadata(
      createdAt: createdAt,
      sourceAppVersion: sourceAppVersion,
      sourceBuild: sourceBuild
    )
    guard Set(drawings.keys) == pageIDs else {
      throw BackupArchiveError.drawingIndexMismatch
    }

    var payload = Data()
    var entries: [BackupDrawingEntry] = []
    entries.reserveCapacity(pageIDs.count)

    for pageID in pageIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      guard let drawing = drawings[pageID] else {
        throw BackupArchiveError.drawingIndexMismatch
      }
      guard drawing.count <= BackupArchiveLimits.maximumDrawingByteCount else {
        throw BackupArchiveError.drawingTooLarge(
          pageID: pageID,
          actual: UInt64(drawing.count),
          maximum: BackupArchiveLimits.maximumDrawingByteCount
        )
      }

      let (nextPayloadCount, overflow) = payload.count.addingReportingOverflow(drawing.count)
      guard !overflow,
        nextPayloadCount <= BackupArchiveLimits.maximumArchiveByteCount - headerByteCount
      else {
        throw BackupArchiveError.archiveTooLarge(
          actual: overflow ? Int.max : nextPayloadCount,
          maximum: BackupArchiveLimits.maximumArchiveByteCount
        )
      }

      entries.append(
        BackupDrawingEntry(
          pageID: pageID,
          offset: UInt64(payload.count),
          byteCount: UInt64(drawing.count),
          sha256: sha256Hex(drawing)
        )
      )
      payload.append(drawing)
    }

    let manifestData = try encodeManifest(
      library: library,
      entries: entries,
      backupID: backupID,
      createdAt: createdAt,
      sourceAppVersion: sourceAppVersion,
      sourceBuild: sourceBuild,
      using: makeEncoder()
    )

    guard manifestData.count <= BackupArchiveLimits.maximumManifestByteCount else {
      throw BackupArchiveError.manifestTooLarge(
        actual: manifestData.count,
        maximum: BackupArchiveLimits.maximumManifestByteCount
      )
    }

    let (bodyByteCount, bodyOverflow) = manifestData.count.addingReportingOverflow(payload.count)
    let (archiveByteCount, archiveOverflow) = headerByteCount.addingReportingOverflow(bodyByteCount)
    guard !bodyOverflow, !archiveOverflow,
      archiveByteCount <= BackupArchiveLimits.maximumArchiveByteCount
    else {
      throw BackupArchiveError.archiveTooLarge(
        actual: bodyOverflow || archiveOverflow ? Int.max : archiveByteCount,
        maximum: BackupArchiveLimits.maximumArchiveByteCount
      )
    }

    var prefix = Data()
    prefix.reserveCapacity(24)
    prefix.append(magic)
    appendBigEndian(formatVersion, to: &prefix)
    appendBigEndian(supportedFlags, to: &prefix)
    appendBigEndian(UInt32(manifestData.count), to: &prefix)
    appendBigEndian(UInt64(payload.count), to: &prefix)

    var hasher = SHA256()
    hasher.update(data: prefix)
    hasher.update(data: manifestData)
    hasher.update(data: payload)
    let archiveDigest = Data(hasher.finalize())

    var archive = Data()
    archive.reserveCapacity(archiveByteCount)
    archive.append(prefix)
    archive.append(archiveDigest)
    archive.append(manifestData)
    archive.append(payload)
    return archive
  }

  static func decode(_ data: Data) throws -> ValidatedBackupArchive {
    guard data.count <= BackupArchiveLimits.maximumArchiveByteCount else {
      throw BackupArchiveError.archiveTooLarge(
        actual: data.count,
        maximum: BackupArchiveLimits.maximumArchiveByteCount
      )
    }
    guard data.count >= headerByteCount else {
      throw BackupArchiveError.truncatedHeader
    }
    guard data.prefix(magic.count) == magic else {
      throw BackupArchiveError.invalidMagic
    }

    let version = readUInt16(data, at: 8)
    guard version == formatVersion else {
      throw BackupArchiveError.unsupportedVersion(found: version)
    }
    let flags = readUInt16(data, at: 10)
    guard flags == supportedFlags else {
      throw BackupArchiveError.unsupportedFlags(found: flags)
    }

    let manifestByteCount = Int(readUInt32(data, at: 12))
    guard manifestByteCount <= BackupArchiveLimits.maximumManifestByteCount else {
      throw BackupArchiveError.manifestTooLarge(
        actual: manifestByteCount,
        maximum: BackupArchiveLimits.maximumManifestByteCount
      )
    }

    let encodedPayloadByteCount = readUInt64(data, at: 16)
    guard encodedPayloadByteCount <= UInt64(Int.max) else {
      throw BackupArchiveError.invalidArchiveLength
    }
    let payloadByteCount = Int(encodedPayloadByteCount)
    let (bodyByteCount, bodyOverflow) = manifestByteCount.addingReportingOverflow(payloadByteCount)
    let (expectedArchiveByteCount, archiveOverflow) =
      headerByteCount.addingReportingOverflow(bodyByteCount)
    guard !bodyOverflow, !archiveOverflow else {
      throw BackupArchiveError.invalidArchiveLength
    }
    guard expectedArchiveByteCount <= BackupArchiveLimits.maximumArchiveByteCount else {
      throw BackupArchiveError.archiveTooLarge(
        actual: expectedArchiveByteCount,
        maximum: BackupArchiveLimits.maximumArchiveByteCount
      )
    }
    guard data.count >= expectedArchiveByteCount else {
      throw BackupArchiveError.truncatedArchive
    }
    guard data.count == expectedArchiveByteCount else {
      throw BackupArchiveError.trailingData
    }

    let storedDigest = data.subdata(in: 24..<headerByteCount)
    var hasher = SHA256()
    hasher.update(data: data.prefix(24))
    hasher.update(data: data.suffix(from: headerByteCount))
    guard storedDigest == Data(hasher.finalize()) else {
      throw BackupArchiveError.archiveChecksumMismatch
    }

    let manifestStart = headerByteCount
    let manifestEnd = manifestStart + manifestByteCount
    let manifestData = data.subdata(in: manifestStart..<manifestEnd)
    let manifest: BackupArchiveManifest
    do {
      manifest = try makeDecoder().decode(BackupArchiveManifest.self, from: manifestData)
      guard try makeEncoder().encode(manifest) == manifestData else {
        throw BackupArchiveError.invalidManifest
      }
    } catch let error as BackupArchiveError {
      throw error
    } catch {
      throw BackupArchiveError.invalidManifest
    }

    try validateSourceMetadata(
      createdAt: manifest.createdAt,
      sourceAppVersion: manifest.sourceAppVersion,
      sourceBuild: manifest.sourceBuild
    )
    guard manifest.librarySchemaVersion == manifest.library.schemaVersion else {
      throw BackupArchiveError.inconsistentLibrarySchema
    }
    let pageIDs = try validateLibrary(manifest.library)
    let drawings = try decodeDrawings(
      manifest.drawings,
      expectedPageIDs: pageIDs,
      archiveData: data,
      payloadStart: manifestEnd,
      declaredPayloadByteCount: encodedPayloadByteCount
    )

    return ValidatedBackupArchive(
      backupID: manifest.backupID,
      archiveChecksum: hexString(storedDigest),
      createdAt: manifest.createdAt,
      sourceAppVersion: manifest.sourceAppVersion,
      sourceBuild: manifest.sourceBuild,
      library: manifest.library,
      drawings: drawings
    )
  }

  @discardableResult
  static func validateLibrary(_ library: LibraryDocument) throws -> Set<UUID> {
    guard library.schemaVersion == LibraryDocument.currentSchemaVersion else {
      throw BackupArchiveError.unsupportedLibrarySchema(found: library.schemaVersion)
    }
    let pageIDs: Set<UUID>
    do {
      pageIDs = try library.validatedPageIDs()
    } catch let error as LibraryDocumentStructureError {
      switch error {
      case .invalidStructure:
        throw BackupArchiveError.invalidLibraryStructure
      case .duplicateNotebookID(let id):
        throw BackupArchiveError.duplicateNotebookID(id)
      case .duplicatePageID(let id):
        throw BackupArchiveError.duplicatePageID(id)
      case .invalidDate:
        throw BackupArchiveError.invalidManifest
      }
    }
    guard library.notebooks.count <= BackupArchiveLimits.maximumNotebookCount else {
      throw BackupArchiveError.tooManyNotebooks(
        actual: library.notebooks.count,
        maximum: BackupArchiveLimits.maximumNotebookCount
      )
    }

    var pageCount = 0
    for notebook in library.notebooks {
      try validateTitle(notebook.title)

      let (nextPageCount, overflow) = pageCount.addingReportingOverflow(notebook.pages.count)
      guard !overflow, nextPageCount <= BackupArchiveLimits.maximumPageCount else {
        throw BackupArchiveError.tooManyPages(
          actual: overflow ? Int.max : nextPageCount,
          maximum: BackupArchiveLimits.maximumPageCount
        )
      }
      pageCount = nextPageCount

      for page in notebook.pages {
        try validateTitle(page.title)
      }
    }
    return pageIDs
  }

  /// Returns a conservative v1 manifest size for a library without allocating drawing payloads.
  ///
  /// The projection uses the real manifest model and encoder. Values whose encoded length can
  /// change after a library edit are replaced with their longest v1 representation: finite dates,
  /// source metadata, drawing offsets, drawing byte counts, and fixed-width SHA-256 digests.
  static func projectedManifestByteCount(for library: LibraryDocument) throws -> Int {
    let pageIDs = try validateLibrary(library)
    let projectedEntries = pageIDs.sorted(by: { $0.uuidString < $1.uuidString }).map {
      BackupDrawingEntry(
        pageID: $0,
        offset: UInt64(BackupArchiveLimits.maximumArchiveByteCount),
        byteCount: UInt64(BackupArchiveLimits.maximumDrawingByteCount),
        sha256: projectionDigest
      )
    }
    return try encodeManifest(
      library: library,
      entries: projectedEntries,
      backupID: projectionBackupID,
      createdAt: projectionDate,
      sourceAppVersion: projectionSourceMetadata,
      sourceBuild: projectionSourceMetadata,
      using: makeProjectionEncoder()
    ).count
  }

  static func validateProjectedManifestBudget(_ library: LibraryDocument) throws {
    let byteCount = try projectedManifestByteCount(for: library)
    guard byteCount <= BackupArchiveLimits.maximumManifestByteCount else {
      throw BackupArchiveError.manifestTooLarge(
        actual: byteCount,
        maximum: BackupArchiveLimits.maximumManifestByteCount
      )
    }
  }

  private static func validateSourceMetadata(
    createdAt: Date,
    sourceAppVersion: String,
    sourceBuild: String
  ) throws {
    try validateDate(createdAt)
    guard sourceAppVersion.utf8.count <= BackupArchiveLimits.maximumSourceMetadataUTF8ByteCount,
      sourceBuild.utf8.count <= BackupArchiveLimits.maximumSourceMetadataUTF8ByteCount
    else {
      throw BackupArchiveError.invalidSourceMetadata
    }
  }

  private static func validateTitle(_ title: String) throws {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      title.utf8.count <= BackupArchiveLimits.maximumTitleUTF8ByteCount
    else {
      throw BackupArchiveError.invalidTitle
    }
  }

  private static func validateDate(_ date: Date) throws {
    guard date.timeIntervalSince1970.isFinite else {
      throw BackupArchiveError.invalidManifest
    }
  }

  private static func decodeDrawings(
    _ entries: [BackupDrawingEntry],
    expectedPageIDs: Set<UUID>,
    archiveData: Data,
    payloadStart: Int,
    declaredPayloadByteCount: UInt64
  ) throws -> [UUID: Data] {
    var entryPageIDs = Set<UUID>()
    for entry in entries {
      guard entryPageIDs.insert(entry.pageID).inserted else {
        throw BackupArchiveError.duplicateDrawingEntry(entry.pageID)
      }
    }
    guard entryPageIDs == expectedPageIDs else {
      throw BackupArchiveError.drawingIndexMismatch
    }
    let orderedPageIDs = expectedPageIDs.sorted(by: { $0.uuidString < $1.uuidString })
    guard entries.map(\.pageID) == orderedPageIDs else {
      throw BackupArchiveError.invalidDrawingLayout
    }

    var expectedOffset: UInt64 = 0
    var result: [UUID: Data] = [:]
    result.reserveCapacity(entries.count)

    for entry in entries {
      guard entry.offset == expectedOffset else {
        throw BackupArchiveError.invalidDrawingLayout
      }
      guard entry.byteCount <= UInt64(BackupArchiveLimits.maximumDrawingByteCount) else {
        throw BackupArchiveError.drawingTooLarge(
          pageID: entry.pageID,
          actual: entry.byteCount,
          maximum: BackupArchiveLimits.maximumDrawingByteCount
        )
      }
      guard isValidSHA256Hex(entry.sha256) else {
        throw BackupArchiveError.invalidDrawingDigest(pageID: entry.pageID)
      }
      let (nextOffset, overflow) = expectedOffset.addingReportingOverflow(entry.byteCount)
      guard !overflow, nextOffset <= declaredPayloadByteCount,
        nextOffset <= UInt64(Int.max)
      else {
        throw BackupArchiveError.invalidDrawingLayout
      }

      let start = payloadStart + Int(expectedOffset)
      let end = payloadStart + Int(nextOffset)
      let drawing = archiveData.subdata(in: start..<end)
      guard sha256Hex(drawing) == entry.sha256 else {
        throw BackupArchiveError.drawingChecksumMismatch(pageID: entry.pageID)
      }
      result[entry.pageID] = drawing
      expectedOffset = nextOffset
    }

    guard expectedOffset == declaredPayloadByteCount,
      archiveData.count - payloadStart == Int(declaredPayloadByteCount)
    else {
      throw BackupArchiveError.invalidDrawingLayout
    }
    return result
  }

  private static func encodeManifest(
    library: LibraryDocument,
    entries: [BackupDrawingEntry],
    backupID: UUID,
    createdAt: Date,
    sourceAppVersion: String,
    sourceBuild: String,
    using encoder: JSONEncoder
  ) throws -> Data {
    let manifest = BackupArchiveManifest(
      backupID: backupID,
      createdAt: createdAt,
      sourceAppVersion: sourceAppVersion,
      sourceBuild: sourceBuild,
      librarySchemaVersion: library.schemaVersion,
      library: library,
      drawings: entries
    )
    do {
      return try encoder.encode(manifest)
    } catch {
      throw BackupArchiveError.invalidManifest
    }
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private static func makeProjectionEncoder() -> JSONEncoder {
    let encoder = makeEncoder()
    encoder.dateEncodingStrategy = .custom { _, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(-Double.greatestFiniteMagnitude)
    }
    return encoder
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return decoder
  }

  private static func sha256Hex(_ data: Data) -> String {
    hexString(Data(SHA256.hash(data: data)))
  }

  private static func hexString(_ data: Data) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var bytes: [UInt8] = []
    bytes.reserveCapacity(data.count * 2)
    for byte in data {
      bytes.append(digits[Int(byte >> 4)])
      bytes.append(digits[Int(byte & 0x0F)])
    }
    return String(decoding: bytes, as: UTF8.self)
  }

  private static func isValidSHA256Hex(_ string: String) -> Bool {
    let bytes = string.utf8
    return bytes.count == 64
      && bytes.allSatisfy {
        ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
      }
  }

  private static func appendBigEndian(_ value: UInt16, to data: inout Data) {
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
  }

  private static func appendBigEndian(_ value: UInt32, to data: inout Data) {
    for shift in stride(from: 24, through: 0, by: -8) {
      data.append(UInt8((value >> UInt32(shift)) & 0xFF))
    }
  }

  private static func appendBigEndian(_ value: UInt64, to data: inout Data) {
    for shift in stride(from: 56, through: 0, by: -8) {
      data.append(UInt8((value >> UInt64(shift)) & 0xFF))
    }
  }

  private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
    (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
  }

  private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    var value: UInt32 = 0
    for index in offset..<(offset + 4) {
      value = (value << 8) | UInt32(data[index])
    }
    return value
  }

  private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for index in offset..<(offset + 8) {
      value = (value << 8) | UInt64(data[index])
    }
    return value
  }
}
