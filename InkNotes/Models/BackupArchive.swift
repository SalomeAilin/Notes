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
    case .archiveTooLarge(_, let maximum):
      "备份文件超过 \(maximum) 字节的安全上限。"
    case .truncatedHeader:
      "备份文件头不完整。"
    case .invalidMagic:
      "这不是受支持的笔记备份文件。"
    case .unsupportedVersion(let found):
      "备份格式版本 \(found) 暂不受支持。"
    case .unsupportedFlags(let found):
      "备份文件包含暂不受支持的标记 \(found)。"
    case .manifestTooLarge(_, let maximum):
      "备份目录超过 \(maximum) 字节的安全上限。"
    case .invalidArchiveLength:
      "备份文件的长度字段无效。"
    case .truncatedArchive:
      "备份文件内容不完整。"
    case .trailingData:
      "备份文件末尾包含未声明的数据。"
    case .archiveChecksumMismatch:
      "备份文件完整性校验失败。"
    case .invalidManifest:
      "备份目录无法解析。"
    case .invalidSourceMetadata:
      "备份来源信息无效。"
    case .unsupportedLibrarySchema(let found):
      "笔记数据版本 \(found) 暂不受支持。"
    case .inconsistentLibrarySchema:
      "备份目录中的笔记数据版本不一致。"
    case .invalidLibraryStructure:
      "备份目录缺少笔记本或页面。"
    case .tooManyNotebooks(_, let maximum):
      "备份中的笔记本数量超过 \(maximum) 个。"
    case .tooManyPages(_, let maximum):
      "备份中的页面数量超过 \(maximum) 个。"
    case .invalidTitle:
      "备份中包含空标题或过长标题。"
    case .duplicateNotebookID:
      "备份中包含重复的笔记本标识。"
    case .duplicatePageID:
      "备份中包含重复的页面标识。"
    case .drawingIndexMismatch:
      "备份中的页面与笔迹索引不一致。"
    case .duplicateDrawingEntry:
      "备份中包含重复的笔迹条目。"
    case .invalidDrawingLayout:
      "备份中的笔迹数据布局无效。"
    case .drawingTooLarge(_, _, let maximum):
      "备份中的单页笔迹超过 \(maximum) 字节的安全上限。"
    case .invalidDrawingDigest:
      "备份中的笔迹校验值格式无效。"
    case .drawingChecksumMismatch:
      "备份中的笔迹完整性校验失败。"
    }
  }
}
