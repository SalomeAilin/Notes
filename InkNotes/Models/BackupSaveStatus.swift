import Foundation

struct BackupSaveStatus: Equatable, Sendable {
  static let storageKey = "backup.last-successful-save-timestamp.v1"
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
}
