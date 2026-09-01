import Foundation
import Testing

@testable import InkNotesCore

@Suite("Backup save status")
struct BackupSaveStatusTests {
  private struct PreviousRecord: Codable {
    let version: Int
    let savedAt: Date
    let notebookCount: Int
    let pageCount: Int
  }

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
    #expect(
      BackupSaveStatus.previousVerifiedRecordStorageKey
        == "backup.last-verified-save-record.v3"
    )
    #expect(BackupSaveStatus.recordStorageKey == "backup.last-verified-save-record.v4")
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

  @Test("An exact library revision shows no changes since save")
  func unchangedSinceSave() throws {
    let savedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let library = makeLibrary(updatedAt: savedAt.addingTimeInterval(-1))
    let record = try #require(
      BackupSaveStatus.recordData(savedAt: savedAt, library: library)
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

  @Test("The saved record contains only time, counts, and an opaque revision")
  func recordIsPrivacyMinimal() throws {
    let savedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let library = makeLibrary(updatedAt: savedAt.addingTimeInterval(-1), pageCount: 5)
    let record = try #require(
      BackupSaveStatus.recordData(savedAt: savedAt, library: library)
    )
    let object = try #require(
      try JSONSerialization.jsonObject(with: record) as? [String: Any]
    )
    let digest = try #require(object["libraryRevisionSHA256"] as? String)
    let recordText = try #require(String(data: record, encoding: .utf8))

    #expect(
      Set(object.keys)
        == Set([
          "version", "savedAt", "notebookCount", "pageCount", "libraryRevisionSHA256",
        ])
    )
    #expect(object["version"] as? Int == 2)
    #expect(object["notebookCount"] as? Int == 1)
    #expect(object["pageCount"] as? Int == 5)
    #expect(digest.count == 64)
    #expect(digest.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) })
    #expect(!recordText.contains("笔记本"))
    #expect(!recordText.contains("页面"))
  }

  @Test("Titles are excluded while structural revision fields remain covered")
  func revisionPrivacyAndCoverage() throws {
    let updatedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let library = makeLibrary(updatedAt: updatedAt, pageCount: 2)
    let originalDigest = try #require(BackupSaveStatus.libraryRevisionSHA256(for: library))

    var renamed = library
    renamed.notebooks[0].title = "完全不同的笔记本名称"
    renamed.notebooks[0].pages[0].title = "完全不同的页面名称"
    #expect(BackupSaveStatus.libraryRevisionSHA256(for: renamed) == originalDigest)

    var reordered = library
    reordered.notebooks[0].pages.swapAt(0, 1)
    #expect(BackupSaveStatus.libraryRevisionSHA256(for: reordered) != originalDigest)

    var changedBackground = library
    changedBackground.notebooks[0].pages[0].background = .grid
    #expect(BackupSaveStatus.libraryRevisionSHA256(for: changedBackground) != originalDigest)
  }

  @Test("Invalid times, counts, and digests are never persisted")
  func rejectsInvalidRecordInputs() {
    let savedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let digest = String(repeating: "a", count: 64)

    #expect(
      BackupSaveStatus.recordData(
        savedAt: Date(timeIntervalSince1970: .nan),
        notebookCount: 1,
        pageCount: 1,
        libraryRevisionSHA256: digest
      ) == nil
    )
    #expect(
      BackupSaveStatus.recordData(
        savedAt: savedAt,
        notebookCount: 0,
        pageCount: 1,
        libraryRevisionSHA256: digest
      ) == nil
    )
    #expect(
      BackupSaveStatus.recordData(
        savedAt: savedAt,
        notebookCount: 2,
        pageCount: 1,
        libraryRevisionSHA256: digest
      ) == nil
    )
    #expect(
      BackupSaveStatus.recordData(
        savedAt: savedAt,
        notebookCount: 1,
        pageCount: 1,
        libraryRevisionSHA256: String(repeating: "A", count: 64)
      ) == nil
    )
  }

  @Test("Any different revision or aggregate count asks the user to save again")
  func changesSinceSave() throws {
    let savedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let library = makeLibrary(updatedAt: savedAt.addingTimeInterval(-1))
    let record = try #require(
      BackupSaveStatus.recordData(savedAt: savedAt, library: library)
    )
    var newerLibrary = library
    newerLibrary.notebooks[0].updatedAt = savedAt.addingTimeInterval(1)
    newerLibrary.notebooks[0].pages[0].updatedAt = savedAt.addingTimeInterval(1)
    var twoPageLibrary = library
    twoPageLibrary.notebooks[0].pages.append(
      NotePage(title: "新增页面", createdAt: savedAt, updatedAt: savedAt)
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

  @Test("Clock rollback cannot hide a later edit")
  func clockRollbackStillShowsChanges() throws {
    let savedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let library = makeLibrary(updatedAt: savedAt.addingTimeInterval(-1))
    let record = try #require(
      BackupSaveStatus.recordData(savedAt: savedAt, library: library)
    )
    var editedAfterClockRollback = library
    editedAfterClockRollback.notebooks[0].updatedAt = savedAt.addingTimeInterval(-3_600)
    editedAfterClockRollback.notebooks[0].pages[0].updatedAt =
      savedAt.addingTimeInterval(-3_600)

    #expect(
      BackupSaveStatus.freshness(
        recordData: record,
        legacyTimestamp: 0,
        library: editedAfterClockRollback,
        now: savedAt
      ) == .changedSinceSave(savedAt)
    )
  }

  @Test("Previous and legacy records never claim that current content was saved")
  func unknownAndMissingRecords() throws {
    let savedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let library = makeLibrary(updatedAt: savedAt.addingTimeInterval(-1))
    let previousRecord = try previousRecordData(savedAt: savedAt)

    #expect(
      BackupSaveStatus.freshness(
        recordData: Data(),
        previousVerifiedRecordData: previousRecord,
        legacyTimestamp: 0,
        library: library,
        now: savedAt
      ) == .unknown(savedAt)
    )
    #expect(
      BackupSaveStatus.freshness(
        recordData: Data(),
        legacyRecordData: previousRecord,
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
    let validLibrary = makeLibrary(updatedAt: savedAt.addingTimeInterval(-1))
    let page = validLibrary.notebooks[0].pages[0]
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
      BackupSaveStatus.recordData(savedAt: savedAt, library: validLibrary)
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

  private func previousRecordData(savedAt: Date) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(
      PreviousRecord(
        version: 1,
        savedAt: savedAt,
        notebookCount: 1,
        pageCount: 1
      )
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
