import Foundation

/// The immutable bytes and file identity handed to every system export surface.
struct BackupExportArtifact: Equatable, Sendable {
  static let fileExtension = BackupArchiveCodec.fileExtension
  static let uniformTypeIdentifier = BackupArchiveCodec.uniformTypeIdentifier

  let data: Data
  let filename: String

  init(
    data: Data,
    createdAt: Date,
    timeZone: TimeZone = .autoupdatingCurrent
  ) {
    self.data = data

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    filename =
      "笔记备份-\(formatter.string(from: createdAt)).\(Self.fileExtension)"
  }
}
