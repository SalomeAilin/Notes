import Foundation
import Testing

@testable import InkNotesCore

@Suite("Backup save status")
struct BackupSaveStatusTests {
  @Test("The main backup entry distinguishes four user-facing save states")
  func mainEntryPresentation() {
    let savedAt = Date(timeIntervalSince1970: 2_000_000_000)

    #expect(
      BackupSaveEntryPresentation(freshness: .noRecord) == .firstSaveNeeded
    )
    #expect(
      BackupSaveEntryPresentation(freshness: .unchangedSinceSave(savedAt)) == .noNewChanges
    )
    #expect(
      BackupSaveEntryPresentation(freshness: .changedSinceSave(savedAt)) == .saveAgainNeeded
    )
    #expect(
      BackupSaveEntryPresentation(freshness: .unknown(savedAt)) == .confirmationNeeded
    )
    #expect(BackupSaveEntryPresentation.firstSaveNeeded.title == "备份与恢复，还没有保存备份")
    #expect(BackupSaveEntryPresentation.noNewChanges.title == "备份与恢复")
    #expect(BackupSaveEntryPresentation.saveAgainNeeded.title == "备份与恢复，有新修改")
    #expect(
      BackupSaveEntryPresentation.confirmationNeeded.title == "备份与恢复，保存状态需要确认"
    )
    #expect(
      BackupSaveEntryPresentation.noNewChanges.systemImage
        == "externaldrive.badge.timemachine"
    )
    #expect(
      BackupSaveEntryPresentation.saveAgainNeeded.systemImage
        == "externaldrive.badge.exclamationmark"
    )
    for presentation in [
      BackupSaveEntryPresentation.firstSaveNeeded,
      .noNewChanges,
      .saveAgainNeeded,
      .confirmationNeeded,
    ] {
      #expect(!presentation.title.contains("已同步"))
      #expect(!presentation.title.contains("自动"))
    }
  }

  @Test("A plausible successful save time remains visible")
  func acceptsPlausibleTimestamp() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let savedAt = now.addingTimeInterval(-90)
    let allowedFutureTime = now.addingTimeInterval(BackupSaveStatus.maximumFutureClockSkew)

    #expect(
      BackupSaveStatus.savedAt(
        timestamp: savedAt.timeIntervalSince1970,
        now: now
      ) == savedAt
    )
    #expect(
      BackupSaveStatus.savedAt(
        timestamp: allowedFutureTime.timeIntervalSince1970,
        now: now
      ) == allowedFutureTime
    )
    #expect(BackupSaveStatus.storageKey == "backup.last-successful-save-timestamp.v1")
    #expect(BackupSaveStatus.legacyRecordStorageKey == "backup.last-successful-save-record.v2")
    #expect(BackupSaveStatus.recordStorageKey == "backup.last-verified-save-record.v3")
  }

  @Test("Missing, corrupt, and implausibly future save times stay hidden")
  func rejectsInvalidTimestamp() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let justBeyondAllowedSkew = now.addingTimeInterval(
      BackupSaveStatus.maximumFutureClockSkew + 1
    )

    #expect(BackupSaveStatus.savedAt(timestamp: 0, now: now) == nil)
    #expect(BackupSaveStatus.savedAt(timestamp: -1, now: now) == nil)
    #expect(BackupSaveStatus.savedAt(timestamp: .nan, now: now) == nil)
    #expect(BackupSaveStatus.savedAt(timestamp: .infinity, now: now) == nil)
    #expect(
      BackupSaveStatus.savedAt(
        timestamp: justBeyondAllowedSkew.timeIntervalSince1970,
        now: now
      ) == nil
    )
  }

  @Test("Matching counts and timestamps show no changes since save")
  func unchangedSinceSave() throws {
    let savedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let library = makeLibrary(updatedAt: savedAt.addingTimeInterval(-1))
    let record = try #require(
      BackupSaveStatus.recordData(
        savedAt: savedAt,
        notebookCount: 1,
        pageCount: 1
      )
    )

    #expect(
      BackupSaveStatus.freshness(
        recordData: record,
        legacyTimestamp: 0,
        library: library,
        now: savedAt
      ) == .unchangedSinceSave(savedAt)
    )
  }

  @Test("The saved record contains only time and aggregate counts")
  func recordIsPrivacyMinimal() throws {
    let savedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let record = try #require(
      BackupSaveStatus.recordData(
        savedAt: savedAt,
        notebookCount: 2,
        pageCount: 5
      )
    )
    let object = try #require(
      try JSONSerialization.jsonObject(with: record) as? [String: Any]
    )

    #expect(Set(object.keys) == Set(["version", "savedAt", "notebookCount", "pageCount"]))
    #expect(object["version"] as? Int == 1)
    #expect(object["notebookCount"] as? Int == 2)
    #expect(object["pageCount"] as? Int == 5)
  }

  @Test("Invalid times and aggregate counts are never persisted")
  func rejectsInvalidRecordInputs() {
    let savedAt = Date(timeIntervalSince1970: 2_000_000_000)

    #expect(
      BackupSaveStatus.recordData(
        savedAt: Date(timeIntervalSince1970: .nan),
        notebookCount: 1,
        pageCount: 1
      ) == nil
    )
    #expect(
      BackupSaveStatus.recordData(
        savedAt: savedAt,
        notebookCount: 0,
        pageCount: 1
      ) == nil
    )
    #expect(
      BackupSaveStatus.recordData(
        savedAt: savedAt,
        notebookCount: 2,
        pageCount: 1
      ) == nil
    )
  }

  @Test("Newer content or changed counts ask the user to save again")
  func changesSinceSave() throws {
    let savedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let record = try #require(
      BackupSaveStatus.recordData(
        savedAt: savedAt,
        notebookCount: 1,
        pageCount: 1
      )
    )
    let newerLibrary = makeLibrary(updatedAt: savedAt.addingTimeInterval(1))
    let twoPageLibrary = makeLibrary(
      updatedAt: savedAt.addingTimeInterval(-1),
      pageCount: 2
    )

    #expect(
      BackupSaveStatus.freshness(
        recordData: record,
        legacyTimestamp: 0,
        library: newerLibrary,
        now: savedAt
      ) == .changedSinceSave(savedAt)
    )
    #expect(
      BackupSaveStatus.freshness(
        recordData: record,
        legacyTimestamp: 0,
        library: twoPageLibrary,
        now: savedAt
      ) == .changedSinceSave(savedAt)
    )
  }

  @Test("Legacy and invalid records never claim that current content was saved")
  func unknownAndMissingRecords() throws {
    let savedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let library = makeLibrary(updatedAt: savedAt.addingTimeInterval(-1))
    let legacyRecord = try #require(
      BackupSaveStatus.recordData(
        savedAt: savedAt,
        notebookCount: 1,
        pageCount: 1
      )
    )

    #expect(
      BackupSaveStatus.freshness(
        recordData: Data(),
        legacyRecordData: legacyRecord,
        legacyTimestamp: 0,
        library: library,
        now: savedAt
      ) == .unknown(savedAt)
    )
    #expect(
      BackupSaveStatus.freshness(
        recordData: Data(),
        legacyTimestamp: savedAt.timeIntervalSince1970,
        library: library,
        now: savedAt
      ) == .unknown(savedAt)
    )
    #expect(
      BackupSaveStatus.freshness(
        recordData: Data("not-json".utf8),
        legacyTimestamp: 0,
        library: library,
        now: savedAt
      ) == .noRecord
    )
    #expect(
      BackupSaveStatus.freshness(
        recordData: Data(),
        legacyTimestamp: 0,
        library: library,
        now: savedAt
      ) == .noRecord
    )
  }

  @Test("Invalid libraries keep an otherwise valid save record uncertain")
  func invalidLibraryIsUnknown() throws {
    let savedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let pageID = UUID()
    let page = NotePage(
      id: pageID,
      title: "页面",
      createdAt: savedAt.addingTimeInterval(-2),
      updatedAt: savedAt.addingTimeInterval(-1)
    )
    let invalidLibrary = LibraryDocument(
      notebooks: [
        Notebook(
          title: "笔记本",
          pages: [page, page],
          createdAt: savedAt.addingTimeInterval(-2),
          updatedAt: savedAt.addingTimeInterval(-1)
        )
      ]
    )
    let record = try #require(
      BackupSaveStatus.recordData(
        savedAt: savedAt,
        notebookCount: 1,
        pageCount: 2
      )
    )

    #expect(
      BackupSaveStatus.freshness(
        recordData: record,
        legacyTimestamp: 0,
        library: invalidLibrary,
        now: savedAt
      ) == .unknown(savedAt)
    )
  }

  private func makeLibrary(
    updatedAt: Date,
    pageCount: Int = 1
  ) -> LibraryDocument {
    let createdAt = updatedAt.addingTimeInterval(-1)
    let pages = (0..<pageCount).map { index in
      NotePage(
        title: "页面 \(index + 1)",
        createdAt: createdAt,
        updatedAt: updatedAt
      )
    }
    return LibraryDocument(
      notebooks: [
        Notebook(
          title: "笔记本",
          pages: pages,
          createdAt: createdAt,
          updatedAt: updatedAt
        )
      ]
    )
  }
}
