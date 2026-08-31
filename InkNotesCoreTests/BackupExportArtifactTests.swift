import Foundation
import Testing

@testable import InkNotesCore

@Suite("Backup export artifact")
struct BackupExportArtifactTests {
  @Test("Filename uses the requested time zone and stable backup identity")
  func stableFilenameAndIdentity() throws {
    let utc = try #require(TimeZone(secondsFromGMT: 0))
    let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    let createdAt = try #require(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 8,
          day: 31,
          hour: 23,
          minute: 30,
          second: 45
        )
      )
    )

    let artifact = BackupExportArtifact(
      data: Data(),
      createdAt: createdAt,
      timeZone: shanghai
    )

    #expect(artifact.filename == "笔记备份-2026-09-01-073045.notesbackup")
    #expect(artifact.filename.hasSuffix(".\(BackupArchiveCodec.fileExtension)"))
    #expect(BackupExportArtifact.fileExtension == BackupArchiveCodec.fileExtension)
    #expect(
      BackupExportArtifact.uniformTypeIdentifier
        == BackupArchiveCodec.uniformTypeIdentifier
    )
  }

  @Test("Export preserves the exact archive bytes")
  func preservesArchiveBytes() throws {
    let bytes = Data([0x00, 0x7F, 0x80, 0xFF, 0x42])
    let timeZone = try #require(TimeZone(secondsFromGMT: 0))

    let artifact = BackupExportArtifact(
      data: bytes,
      createdAt: Date(timeIntervalSince1970: 0),
      timeZone: timeZone
    )

    #expect(artifact.data == bytes)
    #expect(Array(artifact.data) == [0x00, 0x7F, 0x80, 0xFF, 0x42])
  }
}
