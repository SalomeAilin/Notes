import Foundation

final class CredentialTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var queuedDates: [Date]
  private var fallbackDate: Date

  init(_ dates: [Date]) {
    precondition(!dates.isEmpty)
    queuedDates = dates
    fallbackDate = dates[dates.count - 1]
  }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    guard !queuedDates.isEmpty else { return fallbackDate }
    let next = queuedDates.removeFirst()
    fallbackDate = next
    return next
  }

  func set(_ date: Date) {
    lock.lock()
    queuedDates = []
    fallbackDate = date
    lock.unlock()
  }
}
