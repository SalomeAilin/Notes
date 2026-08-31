import Foundation

enum BackupArchiveLimits {
  static let maximumArchiveByteCount = 32 * 1024 * 1024
  static let maximumManifestByteCount = 2 * 1024 * 1024
  static let maximumDrawingByteCount = 8 * 1024 * 1024
  static let maximumNotebookCount = 1_000
  static let maximumPageCount = 5_000
  static let maximumTitleUTF8ByteCount = 1_024
  static let maximumSourceMetadataUTF8ByteCount = 128
}

struct BackupDrawingEntry: Codable, Equatable, Sendable {
  let pageID: UUID
  let offset: UInt64
  let byteCount: UInt64
  let sha256: String
}

struct BackupArchiveManifest: Codable, Equatable, Sendable {
  let backupID: UUID
  let createdAt: Date
  let sourceAppVersion: String
  let sourceBuild: String
  let librarySchemaVersion: Int
  let library: LibraryDocument
  let drawings: [BackupDrawingEntry]
}

struct ValidatedBackupArchive: Equatable, Sendable {
  let backupID: UUID
  let archiveChecksum: String
  let createdAt: Date
  let sourceAppVersion: String
  let sourceBuild: String
  let library: LibraryDocument
  let drawings: [UUID: Data]
}

struct BackupRestoreTransaction: Codable, Equatable, Sendable {
  static let currentVersion = 1

  let version: Int
  let backupID: UUID
  let archiveChecksum: String
  let importedAt: Date
  let copiedNotebooks: [Notebook]

  init(
    version: Int = BackupRestoreTransaction.currentVersion,
    backupID: UUID,
    archiveChecksum: String,
    importedAt: Date,
    copiedNotebooks: [Notebook]
  ) {
    self.version = version
    self.backupID = backupID
    self.archiveChecksum = archiveChecksum
    self.importedAt = importedAt
    self.copiedNotebooks = copiedNotebooks
  }
}

enum BackupArchiveError: LocalizedError, Equatable {
  case archiveTooLarge(actual: Int, maximum: Int)
  case truncatedHeader
  case invalidMagic
  case unsupportedVersion(found: UInt16)
  case unsupportedFlags(found: UInt16)
  case manifestTooLarge(actual: Int, maximum: Int)
  case invalidArchiveLength
  case truncatedArchive
  case trailingData
  case archiveChecksumMismatch
  case invalidManifest
  case invalidSourceMetadata
  case unsupportedLibrarySchema(found: Int)
  case inconsistentLibrarySchema
  case invalidLibraryStructure
  case tooManyNotebooks(actual: Int, maximum: Int)
  case tooManyPages(actual: Int, maximum: Int)
  case invalidTitle
  case duplicateNotebookID(UUID)
  case duplicatePageID(UUID)
  case drawingIndexMismatch
  case duplicateDrawingEntry(UUID)
  case invalidDrawingLayout
  case drawingTooLarge(pageID: UUID, actual: UInt64, maximum: Int)
  case invalidDrawingDigest(pageID: UUID)
  case drawingChecksumMismatch(pageID: UUID)

  var errorDescription: String? {
    switch self {
    case .archiveTooLarge:
      "备份内容较多，当前版本暂时无法一次处理。原有笔记没有改动。"
    case .truncatedHeader:
      "这份备份不完整，未导入任何内容。"
    case .invalidMagic:
      "这不是受支持的笔记备份文件。"
    case .unsupportedVersion, .unsupportedFlags, .unsupportedLibrarySchema:
      "这份备份由其他版本创建，请更新应用后再试。"
    case .manifestTooLarge:
      "这份备份包含的笔记较多，当前版本暂时无法处理。原有笔记没有改动。"
    case .invalidArchiveLength, .truncatedArchive, .trailingData,
      .archiveChecksumMismatch, .invalidManifest, .invalidSourceMetadata:
      "这份备份已损坏或不完整，未导入任何内容。"
    case .inconsistentLibrarySchema:
      "这份备份的内容不一致，未导入任何内容。"
    case .invalidLibraryStructure:
      "这份备份缺少笔记本或页面，未导入任何内容。"
    case .tooManyNotebooks:
      "这份备份包含的笔记本太多，当前版本暂时无法处理。"
    case .tooManyPages:
      "这份备份包含的页面太多，当前版本暂时无法处理。"
    case .invalidTitle:
      "备份中包含空标题或过长标题。"
    case .duplicateNotebookID:
      "备份中包含重复的笔记本，未导入任何内容。"
    case .duplicatePageID:
      "备份中包含重复的页面，未导入任何内容。"
    case .drawingIndexMismatch:
      "备份中的页面与笔迹不一致，未导入任何内容。"
    case .duplicateDrawingEntry:
      "备份中包含重复的笔迹，未导入任何内容。"
    case .invalidDrawingLayout:
      "备份中的笔迹内容不完整，未导入任何内容。"
    case .drawingTooLarge:
      "备份中有一页内容较多，当前版本暂时无法处理。原有笔记没有改动。"
    case .invalidDrawingDigest, .drawingChecksumMismatch:
      "这份备份中的一页已损坏或不完整，未导入任何内容。"
    }
  }
}
