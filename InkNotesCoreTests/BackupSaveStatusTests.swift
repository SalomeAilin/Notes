import Foundation
import Testing

@testable import InkNotesCore

@Suite("Backup save status")
struct BackupSaveStatusTests {
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
}
