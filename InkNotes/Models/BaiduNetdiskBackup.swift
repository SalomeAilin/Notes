import Foundation

enum BaiduNetdiskConfigurationError: LocalizedError, Equatable, Sendable {
  case invalidAccessToken
  case invalidApplicationFolderName

  var errorDescription: String? {
    switch self {
    case .invalidAccessToken:
      "百度网盘访问凭证无效，请重新连接后再试。"
    case .invalidApplicationFolderName:
      "百度网盘应用目录名称无效。"
    }
  }
}

struct BaiduAccessToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  private let value: String

  init(_ value: String) throws {
    guard !value.isEmpty,
      value.utf8.count <= 256,
      value.unicodeScalars.allSatisfy({
        !CharacterSet.whitespacesAndNewlines.contains($0)
          && !CharacterSet.controlCharacters.contains($0)
      })
    else {
      throw BaiduNetdiskConfigurationError.invalidAccessToken
    }
    self.value = value
  }

  var requestValue: String { value }

  var description: String { "<redacted>" }
  var debugDescription: String { "<redacted>" }
  var customMirror: Mirror {
    Mirror(self, children: EmptyCollection<Mirror.Child>())
  }
}

struct BaiduNetdiskAppDirectory: Hashable, Sendable {
  let folderName: String

  init(folderName: String) throws {
    guard (1...12).contains(folderName.count),
      folderName == folderName.trimmingCharacters(in: .whitespacesAndNewlines),
      folderName.unicodeScalars.allSatisfy(Self.isAllowedFolderNameScalar)
    else {
      throw BaiduNetdiskConfigurationError.invalidApplicationFolderName
    }
    self.folderName = folderName
  }

  var remotePath: String { "/apps/\(folderName)" }

  func backupPath(backupID: UUID) -> String {
    "\(remotePath)/\(Self.backupFilename(backupID: backupID))"
  }

  static func backupFilename(backupID: UUID) -> String {
    "backup-\(backupID.uuidString.lowercased()).\(BackupArchiveCodec.fileExtension)"
  }

  private static func isAllowedFolderNameScalar(_ scalar: Unicode.Scalar) -> Bool {
    CharacterSet.letters.contains(scalar)
      || CharacterSet.decimalDigits.contains(scalar)
      || scalar == " "
      || scalar == "-"
      || scalar == "_"
  }
}

struct BaiduRemoteBackup: Equatable, Sendable {
  let backupID: UUID
  let fsID: UInt64
  let path: String
  let byteCount: UInt64
  let md5: String
}

struct BaiduRapidUploadReceipt: Equatable, Sendable {
  let backupID: UUID
  let requestedPath: String
  let localByteCount: UInt64
  let localMD5: String
}

enum BaiduBackupUploadOutcome: Equatable, Sendable {
  case uploaded(BaiduRemoteBackup)
  case rapidUpload(BaiduRapidUploadReceipt)
}

enum BaiduBackupUploadProgress: Equatable, Sendable {
  case precreateDispatchPermitted
  case uploadPartDispatchPermitted(partIndex: Int, ordinal: Int, total: Int)
  case createDispatchPermitted
}

enum BaiduUploadStage: Equatable, Sendable {
  case precreate
  case uploadPart(Int)
  case create
}

enum BaiduNetdiskUploadError: LocalizedError, Equatable, Sendable {
  case invalidBackup(BackupArchiveError)
  case requestEncoding(BaiduUploadStage)
  case transport(BaiduUploadStage)
  case invalidHTTPResponse(BaiduUploadStage)
  case httpStatus(stage: BaiduUploadStage, statusCode: Int)
  case responseTooLarge(stage: BaiduUploadStage, maximum: Int)
  case malformedResponse(BaiduUploadStage)
  case api(stage: BaiduUploadStage, code: Int)
  case invalidReturnType(Int?)
  case invalidUploadID
  case duplicatePartIndex(Int)
  case invalidPartIndex(Int)
  case partDigestMismatch(Int)
  case committedPathMismatch
  case committedSizeMismatch
  case committedDigestMismatch

  var errorDescription: String? {
    switch self {
    case .invalidBackup:
      "备份文件未通过本地完整性校验，未开始上传。"
    case .requestEncoding:
      "无法安全构造百度网盘上传请求。"
    case .transport:
      "连接百度网盘失败，请检查网络后重试。"
    case .invalidHTTPResponse:
      "百度网盘返回了无效的网络响应。"
    case .httpStatus(_, let statusCode):
      "百度网盘请求失败（HTTP \(statusCode)）。"
    case .responseTooLarge(_, let maximum):
      "百度网盘响应超过 \(maximum) 字节的安全上限。"
    case .malformedResponse:
      "百度网盘返回的数据无法验证。"
    case .api(_, let code):
      "百度网盘拒绝了本次操作（错误码 \(code)）。"
    case .invalidReturnType:
      "百度网盘返回了无法识别的上传类型。"
    case .invalidUploadID:
      "百度网盘返回了无效的上传任务标识。"
    case .duplicatePartIndex:
      "百度网盘返回了重复的上传分片。"
    case .invalidPartIndex:
      "百度网盘返回了越界的上传分片。"
    case .partDigestMismatch:
      "百度网盘返回的分片校验值不一致。"
    case .committedPathMismatch:
      "百度网盘创建文件后的路径与请求不一致。"
    case .committedSizeMismatch:
      "百度网盘创建文件后的大小与本地备份不一致。"
    case .committedDigestMismatch:
      "百度网盘创建文件后的校验值与本地备份不一致。"
    }
  }
}

struct BaiduBackupUploadChunk: Equatable, Sendable {
  let index: Int
  let data: Data
  let md5: String
}

struct BaiduBackupUploadPlan: Equatable, Sendable {
  let backupID: UUID
  let remotePath: String
  let archive: Data
  let md5: String
  let chunks: [BaiduBackupUploadChunk]
}
