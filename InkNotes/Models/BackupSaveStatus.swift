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
    static let currentVersion = 1

    let version: Int
    let savedAt: Date
    let notebookCount: Int
    let pageCount: Int
  }

  static let storageKey = "backup.last-successful-save-timestamp.v1"
  static let legacyRecordStorageKey = "backup.last-successful-save-record.v2"
  static let recordStorageKey = "backup.last-verified-save-record.v3"
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
    notebookCount: Int,
    pageCount: Int
  ) -> Data? {
    guard savedAt.timeIntervalSince1970.isFinite,
      notebookCount > 0,
      notebookCount <= BackupArchiveLimits.maximumNotebookCount,
      pageCount >= notebookCount,
      pageCount <= BackupArchiveLimits.maximumPageCount
    else { return nil }

    let record = PersistedRecord(
      version: PersistedRecord.currentVersion,
      savedAt: savedAt,
      notebookCount: notebookCount,
      pageCount: pageCount
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return try? encoder.encode(record)
  }

  static func freshness(
    recordData: Data,
    legacyRecordData: Data = Data(),
    legacyTimestamp: Double,
    library: LibraryDocument,
    now: Date = Date()
  ) -> BackupSaveFreshness {
    guard let record = validatedRecord(from: recordData, now: now) else {
      if let legacyRecord = validatedRecord(from: legacyRecordData, now: now) {
        return .unknown(legacyRecord.savedAt)
      }
      guard let legacySavedAt = savedAt(timestamp: legacyTimestamp, now: now) else {
        return .noRecord
      }
      return .unknown(legacySavedAt)
    }

    do {
      _ = try library.validatedPageIDs()
    } catch {
      return .unknown(record.savedAt)
    }

    var currentPageCount = 0
    var changedAfterSave = false
    for notebook in library.notebooks {
      let (nextPageCount, overflow) = currentPageCount.addingReportingOverflow(
        notebook.pages.count
      )
      guard !overflow else { return .unknown(record.savedAt) }
      currentPageCount = nextPageCount
      if notebook.createdAt > record.savedAt || notebook.updatedAt > record.savedAt {
        changedAfterSave = true
      }
      if notebook.pages.contains(where: {
        $0.createdAt > record.savedAt || $0.updatedAt > record.savedAt
      }) {
        changedAfterSave = true
      }
    }

    if record.notebookCount != library.notebooks.count
      || record.pageCount != currentPageCount
      || changedAfterSave
    {
      return .changedSinceSave(record.savedAt)
    }
    return .unchangedSinceSave(record.savedAt)
  }

  private static func validatedRecord(
    from data: Data,
    now: Date
  ) -> PersistedRecord? {
    guard !data.isEmpty else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    guard let record = try? decoder.decode(PersistedRecord.self, from: data),
      record.version == PersistedRecord.currentVersion,
      savedAt(timestamp: record.savedAt.timeIntervalSince1970, now: now) != nil,
      record.notebookCount > 0,
      record.notebookCount <= BackupArchiveLimits.maximumNotebookCount,
      record.pageCount >= record.notebookCount,
      record.pageCount <= BackupArchiveLimits.maximumPageCount
    else { return nil }
    return record
  }
}
