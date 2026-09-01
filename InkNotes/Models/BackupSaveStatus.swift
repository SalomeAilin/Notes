import CryptoKit
import Foundation

enum BackupSaveFreshness: Equatable, Sendable {
  case noRecord
  case unchangedSinceSave(Date)
  case changedSinceSave(Date)
  case unknown(Date)
}

enum BackupSaveEntryPresentation: Equatable, Sendable {
  case firstSaveNeeded
  case noNewChanges
  case saveAgainNeeded
  case confirmationNeeded

  init(freshness: BackupSaveFreshness) {
    switch freshness {
    case .noRecord:
      self = .firstSaveNeeded
    case .unchangedSinceSave:
      self = .noNewChanges
    case .changedSinceSave:
      self = .saveAgainNeeded
    case .unknown:
      self = .confirmationNeeded
    }
  }

  var title: String {
    switch self {
    case .firstSaveNeeded:
      "备份与恢复，还没有保存备份"
    case .noNewChanges:
      "备份与恢复"
    case .saveAgainNeeded:
      "备份与恢复，有新修改"
    case .confirmationNeeded:
      "备份与恢复，保存状态需要确认"
    }
  }

  var systemImage: String {
    switch self {
    case .firstSaveNeeded:
      "externaldrive.badge.plus"
    case .noNewChanges:
      "externaldrive.badge.timemachine"
    case .saveAgainNeeded, .confirmationNeeded:
      "externaldrive.badge.exclamationmark"
    }
  }
}

struct BackupSaveStatus: Equatable, Sendable {
  private struct PersistedRecord: Codable, Equatable, Sendable {
    static let currentVersion = 2

    let version: Int
    let savedAt: Date
    let notebookCount: Int
    let pageCount: Int
    let libraryRevisionSHA256: String
  }

  private struct PreviousVerifiedRecord: Codable, Equatable, Sendable {
    static let version = 1

    let version: Int
    let savedAt: Date
    let notebookCount: Int
    let pageCount: Int
  }

  static let storageKey = "backup.last-successful-save-timestamp.v1"
  static let legacyRecordStorageKey = "backup.last-successful-save-record.v2"
  static let previousVerifiedRecordStorageKey = "backup.last-verified-save-record.v3"
  static let recordStorageKey = "backup.last-verified-save-record.v4"
  static let maximumFutureClockSkew: TimeInterval = 24 * 60 * 60

  static func savedAt(
    timestamp: Double,
    now: Date = Date()
  ) -> Date? {
    guard timestamp.isFinite, timestamp > 0 else { return nil }
    let savedAt = Date(timeIntervalSince1970: timestamp)
    guard savedAt <= now.addingTimeInterval(maximumFutureClockSkew) else { return nil }
    return savedAt
  }

  static func recordData(
    savedAt: Date,
    library: LibraryDocument
  ) -> Data? {
    guard let revision = libraryRevisionSummary(for: library) else { return nil }
    return recordData(
      savedAt: savedAt,
      notebookCount: revision.notebookCount,
      pageCount: revision.pageCount,
      libraryRevisionSHA256: revision.sha256
    )
  }

  static func libraryRevisionSHA256(for library: LibraryDocument) -> String? {
    libraryRevisionSummary(for: library)?.sha256
  }

  static func recordData(
    savedAt: Date,
    notebookCount: Int,
    pageCount: Int,
    libraryRevisionSHA256: String
  ) -> Data? {
    guard savedAt.timeIntervalSince1970.isFinite,
      notebookCount > 0,
      notebookCount <= BackupArchiveLimits.maximumNotebookCount,
      pageCount >= notebookCount,
      pageCount <= BackupArchiveLimits.maximumPageCount,
      isValidSHA256Hex(libraryRevisionSHA256)
    else { return nil }

    let record = PersistedRecord(
      version: PersistedRecord.currentVersion,
      savedAt: savedAt,
      notebookCount: notebookCount,
      pageCount: pageCount,
      libraryRevisionSHA256: libraryRevisionSHA256
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return try? encoder.encode(record)
  }

  static func freshness(
    recordData: Data,
    previousVerifiedRecordData: Data = Data(),
    legacyRecordData: Data = Data(),
    legacyTimestamp: Double,
    library: LibraryDocument,
    now: Date = Date()
  ) -> BackupSaveFreshness {
    guard let record = validatedRecord(from: recordData, now: now) else {
      if let previousSavedAt = validatedPreviousSavedAt(
        from: previousVerifiedRecordData,
        now: now
      ) {
        return .unknown(previousSavedAt)
      }
      if let legacySavedAt = validatedPreviousSavedAt(from: legacyRecordData, now: now) {
        return .unknown(legacySavedAt)
      }
      guard let legacySavedAt = savedAt(timestamp: legacyTimestamp, now: now) else {
        return .noRecord
      }
      return .unknown(legacySavedAt)
    }

    guard let revision = libraryRevisionSummary(for: library) else {
      return .unknown(record.savedAt)
    }

    if record.notebookCount != revision.notebookCount
      || record.pageCount != revision.pageCount
      || record.libraryRevisionSHA256 != revision.sha256
    {
      return .changedSinceSave(record.savedAt)
    }
    return .unchangedSinceSave(record.savedAt)
  }

  private static func validatedRecord(
    from data: Data,
    now: Date
  ) -> PersistedRecord? {
    let expectedKeys = Set([
      "version", "savedAt", "notebookCount", "pageCount", "libraryRevisionSHA256",
    ])
    guard hasExactJSONObjectKeys(data, expectedKeys: expectedKeys) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    guard let record = try? decoder.decode(PersistedRecord.self, from: data),
      record.version == PersistedRecord.currentVersion,
      savedAt(timestamp: record.savedAt.timeIntervalSince1970, now: now) != nil,
      record.notebookCount > 0,
      record.notebookCount <= BackupArchiveLimits.maximumNotebookCount,
      record.pageCount >= record.notebookCount,
      record.pageCount <= BackupArchiveLimits.maximumPageCount,
      isValidSHA256Hex(record.libraryRevisionSHA256)
    else { return nil }
    return record
  }

  private static func validatedPreviousSavedAt(
    from data: Data,
    now: Date
  ) -> Date? {
    let expectedKeys = Set(["version", "savedAt", "notebookCount", "pageCount"])
    guard hasExactJSONObjectKeys(data, expectedKeys: expectedKeys) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    guard let record = try? decoder.decode(PreviousVerifiedRecord.self, from: data),
      record.version == PreviousVerifiedRecord.version,
      savedAt(timestamp: record.savedAt.timeIntervalSince1970, now: now) != nil,
      record.notebookCount > 0,
      record.notebookCount <= BackupArchiveLimits.maximumNotebookCount,
      record.pageCount >= record.notebookCount,
      record.pageCount <= BackupArchiveLimits.maximumPageCount
    else { return nil }
    return record.savedAt
  }

  private struct LibraryRevisionSummary {
    let notebookCount: Int
    let pageCount: Int
    let sha256: String
  }

  private static func libraryRevisionSummary(
    for library: LibraryDocument
  ) -> LibraryRevisionSummary? {
    guard library.schemaVersion == LibraryDocument.currentSchemaVersion else { return nil }
    do {
      _ = try library.validatedPageIDs()
    } catch {
      return nil
    }

    let notebookCount = library.notebooks.count
    guard notebookCount <= BackupArchiveLimits.maximumNotebookCount else { return nil }
    var pageCount = 0
    var revisionBytes = Data("inknotes.library-revision.v1\0".utf8)
    appendUnsigned(UInt64(library.schemaVersion), to: &revisionBytes)
    appendUnsigned(UInt64(notebookCount), to: &revisionBytes)

    for notebook in library.notebooks {
      appendUUID(notebook.id, to: &revisionBytes)
      appendDate(notebook.createdAt, to: &revisionBytes)
      appendDate(notebook.updatedAt, to: &revisionBytes)
      appendUnsigned(UInt64(notebook.pages.count), to: &revisionBytes)

      let (nextPageCount, overflow) = pageCount.addingReportingOverflow(notebook.pages.count)
      guard !overflow, nextPageCount <= BackupArchiveLimits.maximumPageCount else { return nil }
      pageCount = nextPageCount

      for page in notebook.pages {
        appendUUID(page.id, to: &revisionBytes)
        appendDate(page.createdAt, to: &revisionBytes)
        appendDate(page.updatedAt, to: &revisionBytes)
        revisionBytes.append(backgroundByte(page.background))
      }
    }

    let digest = SHA256.hash(data: revisionBytes)
      .map { String(format: "%02x", $0) }
      .joined()
    return LibraryRevisionSummary(
      notebookCount: notebookCount,
      pageCount: pageCount,
      sha256: digest
    )
  }

  private static func appendUnsigned(_ value: UInt64, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { bytes in
      data.append(contentsOf: bytes)
    }
  }

  private static func appendUUID(_ value: UUID, to data: inout Data) {
    data.append(contentsOf: value.uuidString.lowercased().utf8)
  }

  private static func appendDate(_ value: Date, to data: inout Data) {
    appendUnsigned(value.timeIntervalSinceReferenceDate.bitPattern, to: &data)
  }

  private static func backgroundByte(_ background: PageBackground) -> UInt8 {
    switch background {
    case .blank: 0
    case .ruled: 1
    case .grid: 2
    }
  }

  private static func hasExactJSONObjectKeys(
    _ data: Data,
    expectedKeys: Set<String>
  ) -> Bool {
    guard !data.isEmpty,
      let object = try? JSONSerialization.jsonObject(with: data),
      let dictionary = object as? [String: Any]
    else { return false }
    return Set(dictionary.keys) == expectedKeys
  }

  private static func isValidSHA256Hex(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { byte in
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
      }
  }
}
