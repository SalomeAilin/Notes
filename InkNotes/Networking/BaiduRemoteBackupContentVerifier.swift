import CryptoKit
import Foundation

protocol BaiduRemoteBackupContentVerifying: Sendable {
  func verify(
    record: BaiduUploadReconciliationRecord,
    fsID: UInt64,
    credential: BaiduAccountBoundCredential
  ) async throws -> BaiduRemoteBackupContentVerificationResult
}

struct BaiduVerifiedRemoteBackupContent: Equatable, Sendable {
  let fsID: UInt64
  let byteCount: UInt64
  let sha256: String
}

enum BaiduRemoteBackupContentMismatch: Equatable, Sendable {
  case byteCount(expected: UInt64, actual: UInt64)
  case sha256
}

enum BaiduRemoteBackupContentVerification: Equatable, Sendable {
  case contentVerified(BaiduVerifiedRemoteBackupContent)
  case contentMismatch(BaiduRemoteBackupContentMismatch)
}

struct BaiduRemoteBackupContentVerificationResult: Equatable, Sendable {
  let accountScope: BaiduAccountScope
  let attemptID: UUID
  let backupID: UUID
  let verification: BaiduRemoteBackupContentVerification
}

enum BaiduRemoteBackupContentVerificationError: LocalizedError, Equatable, Sendable {
  case accountScopeMismatch
  case invalidRecord
  case invalidFSID
  case requestEncoding
  case metadataTransport
  case invalidMetadataHTTPResponse
  case metadataHTTPStatus(Int)
  case metadataResponseTooLarge(maximum: Int)
  case malformedMetadataResponse
  case metadataAPI(Int)
  case insecureDownloadURL
  case downloadTransport
  case invalidDownloadHTTPResponse
  case downloadHTTPStatus(Int)
  case downloadTooLarge(maximum: Int)
  case unsupportedContentEncoding

  var errorDescription: String? {
    switch self {
    case .accountScopeMismatch:
      "百度网盘凭据与待核对备份不属于同一账号，未发起下载。"
    case .invalidRecord:
      "百度网盘待核对记录无效，未发起下载。"
    case .invalidFSID:
      "百度网盘文件标识无效，未发起下载。"
    case .requestEncoding:
      "无法安全构造百度网盘完整性核对请求。"
    case .metadataTransport:
      "连接百度网盘失败，请检查网络后重试。"
    case .invalidMetadataHTTPResponse:
      "百度网盘返回了无效的文件信息响应。"
    case .metadataHTTPStatus(let statusCode):
      "百度网盘文件信息查询失败（HTTP \(statusCode)）。"
    case .metadataResponseTooLarge:
      "百度网盘文件信息响应超过安全上限。"
    case .malformedMetadataResponse:
      "百度网盘文件信息响应无法验证。"
    case .metadataAPI(let code):
      "百度网盘拒绝了文件信息查询（错误码 \(code)）。"
    case .insecureDownloadURL:
      "百度网盘返回了不安全的下载地址，已停止核对。"
    case .downloadTransport:
      "下载百度网盘备份失败，请检查网络后重试。"
    case .invalidDownloadHTTPResponse:
      "百度网盘返回了无效的下载响应。"
    case .downloadHTTPStatus(let statusCode):
      "百度网盘备份下载失败（HTTP \(statusCode)）。"
    case .downloadTooLarge:
      "百度网盘备份超过本地备份格式的安全上限。"
    case .unsupportedContentEncoding:
      "百度网盘下载响应使用了无法逐字节核对的内容编码。"
    }
  }
}

struct BaiduStreamedDownloadDigest: Equatable, Sendable {
  let byteCount: UInt64
  let sha256: String
}

protocol BaiduRemoteBackupByteStreaming: Sendable {
  func streamSHA256(
    _ request: URLRequest,
    maximumByteCount: Int
  ) async throws -> BaiduStreamedDownloadDigest
}

enum BaiduRemoteBackupByteStreamError: Error, Equatable, Sendable {
  case invalidRequest
  case invalidResponse
  case httpStatus(Int)
  case responseTooLarge(maximum: Int)
  case unsupportedContentEncoding
  case network(URLError.Code)
  case unavailable
}

struct URLSessionBaiduRemoteBackupByteStreamer: BaiduRemoteBackupByteStreaming {
  static let hashChunkByteCount = 64 * 1024
  static let initialDownloadHost = "d.pcs.baidu.com"

  private let session: URLSession

  init(session: URLSession = Self.makeEphemeralSession()) {
    self.session = session
  }

  func streamSHA256(
    _ request: URLRequest,
    maximumByteCount: Int
  ) async throws -> BaiduStreamedDownloadDigest {
    precondition(maximumByteCount >= 0 && maximumByteCount < Int.max)
    guard Self.isSafeDownloadRequest(request) else {
      throw BaiduRemoteBackupByteStreamError.invalidRequest
    }

    do {
      try Task.checkCancellation()
      let (bytes, response) = try await session.bytes(
        for: request,
        delegate: BaiduHTTPSOnlyRedirectDelegate()
      )
      guard let response = response as? HTTPURLResponse else {
        bytes.task.cancel()
        throw BaiduRemoteBackupByteStreamError.invalidResponse
      }
      guard response.statusCode == 200 else {
        bytes.task.cancel()
        throw BaiduRemoteBackupByteStreamError.httpStatus(response.statusCode)
      }
      guard Self.hasIdentityContentEncoding(response) else {
        bytes.task.cancel()
        throw BaiduRemoteBackupByteStreamError.unsupportedContentEncoding
      }
      guard response.value(forHTTPHeaderField: "Content-Range") == nil else {
        bytes.task.cancel()
        throw BaiduRemoteBackupByteStreamError.invalidResponse
      }
      let declaredByteCount = response.expectedContentLength
      if declaredByteCount > Int64(maximumByteCount) {
        bytes.task.cancel()
        throw BaiduRemoteBackupByteStreamError.responseTooLarge(
          maximum: maximumByteCount
        )
      }

      var hasher = SHA256()
      var chunk = Data()
      chunk.reserveCapacity(Self.hashChunkByteCount)
      var receivedByteCount = 0
      for try await byte in bytes {
        try Task.checkCancellation()
        guard receivedByteCount < maximumByteCount else {
          bytes.task.cancel()
          throw BaiduRemoteBackupByteStreamError.responseTooLarge(
            maximum: maximumByteCount
          )
        }
        chunk.append(byte)
        receivedByteCount += 1
        if chunk.count == Self.hashChunkByteCount {
          hasher.update(data: chunk)
          chunk.removeAll(keepingCapacity: true)
        }
      }
      if !chunk.isEmpty {
        hasher.update(data: chunk)
      }
      if declaredByteCount >= 0, UInt64(declaredByteCount) != UInt64(receivedByteCount) {
        throw BaiduRemoteBackupByteStreamError.invalidResponse
      }
      let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
      return BaiduStreamedDownloadDigest(
        byteCount: UInt64(receivedByteCount),
        sha256: digest
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch let error as URLError {
      throw BaiduRemoteBackupByteStreamError.network(error.code)
    } catch let error as BaiduRemoteBackupByteStreamError {
      throw error
    } catch {
      throw BaiduRemoteBackupByteStreamError.unavailable
    }
  }

  static func makeEphemeralSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.httpShouldSetCookies = false
    return URLSession(configuration: configuration)
  }

  private static func isSafeDownloadRequest(_ request: URLRequest) -> Bool {
    guard request.httpMethod == "GET", request.httpBody == nil,
      let url = request.url,
      url.scheme?.lowercased() == "https",
      url.host?.lowercased() == Self.initialDownloadHost,
      url.port == nil || url.port == 443,
      url.user == nil,
      url.password == nil,
      url.fragment == nil,
      request.value(forHTTPHeaderField: "Authorization") == nil,
      request.value(forHTTPHeaderField: "Proxy-Authorization") == nil,
      request.value(forHTTPHeaderField: "Cookie") == nil,
      request.value(forHTTPHeaderField: "Referer") == nil,
      request.value(forHTTPHeaderField: "Origin") == nil,
      request.value(forHTTPHeaderField: "Range") == nil,
      request.httpShouldHandleCookies == false
    else {
      return false
    }
    return true
  }

  private static func hasIdentityContentEncoding(_ response: HTTPURLResponse) -> Bool {
    guard let value = response.value(forHTTPHeaderField: "Content-Encoding") else {
      return true
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      == "identity"
  }
}

final class BaiduHTTPSOnlyRedirectDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard var request = Self.sanitizedHTTPSRedirectRequest(request) else {
      completionHandler(nil)
      return
    }
    request.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent")
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    completionHandler(request)
  }

  private static func sanitizedHTTPSRedirectRequest(
    _ request: URLRequest
  ) -> URLRequest? {
    guard request.httpMethod == "GET", request.httpBody == nil,
      let url = request.url,
      url.scheme?.lowercased() == "https",
      url.host != nil,
      url.port == nil || url.port == 443,
      url.user == nil,
      url.password == nil,
      url.fragment == nil,
      url.absoluteString.utf8.count <= 32 * 1024,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      !(components.queryItems ?? []).contains(where: {
        $0.name.caseInsensitiveCompare("access_token") == .orderedSame
      })
    else {
      return nil
    }
    var request = request
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false
    request.setValue(nil, forHTTPHeaderField: "Authorization")
    request.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
    request.setValue(nil, forHTTPHeaderField: "Cookie")
    request.setValue(nil, forHTTPHeaderField: "Referer")
    request.setValue(nil, forHTTPHeaderField: "Origin")
    request.setValue(nil, forHTTPHeaderField: "Range")
    return request
  }
}

struct BaiduRemoteBackupContentVerifier: BaiduRemoteBackupContentVerifying, Sendable {
  static let maximumMetadataResponseByteCount = 64 * 1024
  static let maximumDLinkUTF8ByteCount = 16 * 1024

  private static let metadataEndpoint = URL(
    string: "https://pan.baidu.com/rest/2.0/xpan/multimedia"
  )!

  private let metadataTransport: any BaiduHTTPTransport
  private let byteStreamer: any BaiduRemoteBackupByteStreaming

  init(
    metadataTransport: any BaiduHTTPTransport = URLSessionBaiduHTTPTransport(
      maximumResponseByteCount: Self.maximumMetadataResponseByteCount
    ),
    byteStreamer: any BaiduRemoteBackupByteStreaming =
      URLSessionBaiduRemoteBackupByteStreamer()
  ) {
    self.metadataTransport = metadataTransport
    self.byteStreamer = byteStreamer
  }

  func verify(
    record: BaiduUploadReconciliationRecord,
    fsID: UInt64,
    credential: BaiduAccountBoundCredential
  ) async throws -> BaiduRemoteBackupContentVerificationResult {
    try Task.checkCancellation()
    guard record.accountScope == credential.accountScope else {
      throw BaiduRemoteBackupContentVerificationError.accountScopeMismatch
    }
    guard let target = Self.target(for: record) else {
      throw BaiduRemoteBackupContentVerificationError.invalidRecord
    }
    guard fsID > 0 else {
      throw BaiduRemoteBackupContentVerificationError.invalidFSID
    }

    let metadataRequest = try makeMetadataRequest(
      fsID: fsID,
      accessToken: credential.requestAccessToken
    )
    let metadata = try await fetchMetadata(
      metadataRequest,
      expectedFSID: fsID,
      target: target
    )
    guard metadata.byteCount <= UInt64(BackupArchiveLimits.maximumArchiveByteCount)
    else {
      throw BaiduRemoteBackupContentVerificationError.downloadTooLarge(
        maximum: BackupArchiveLimits.maximumArchiveByteCount
      )
    }
    if metadata.byteCount != record.localByteCount {
      return Self.result(
        .contentMismatch(
          .byteCount(expected: record.localByteCount, actual: metadata.byteCount)
        ),
        for: record
      )
    }

    let downloadRequest = try makeDownloadRequest(
      dlink: metadata.dlink,
      accessToken: credential.requestAccessToken
    )
    let digest = try await stream(downloadRequest)
    try Task.checkCancellation()
    guard digest.byteCount == metadata.byteCount else {
      return Self.result(
        .contentMismatch(
          .byteCount(expected: metadata.byteCount, actual: digest.byteCount)
        ),
        for: record
      )
    }
    guard Self.constantTimeEqual(digest.sha256, record.archiveSHA256) else {
      return Self.result(.contentMismatch(.sha256), for: record)
    }
    return Self.result(
      .contentVerified(
        BaiduVerifiedRemoteBackupContent(
          fsID: fsID,
          byteCount: digest.byteCount,
          sha256: digest.sha256
        )
      ),
      for: record
    )
  }

  private func fetchMetadata(
    _ request: URLRequest,
    expectedFSID: UInt64,
    target: Target
  ) async throws -> RemoteFileMetadata {
    let response: BaiduHTTPResponse
    do {
      response = try await metadataTransport.send(request)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch let error as BaiduHTTPTransportError {
      switch error {
      case .invalidResponse:
        throw BaiduRemoteBackupContentVerificationError.invalidMetadataHTTPResponse
      case .responseTooLarge(let maximum):
        throw BaiduRemoteBackupContentVerificationError.metadataResponseTooLarge(
          maximum: maximum
        )
      case .network, .unavailable:
        throw BaiduRemoteBackupContentVerificationError.metadataTransport
      }
    } catch {
      throw BaiduRemoteBackupContentVerificationError.metadataTransport
    }

    try Task.checkCancellation()
    guard response.statusCode == 200 else {
      throw BaiduRemoteBackupContentVerificationError.metadataHTTPStatus(
        response.statusCode
      )
    }
    guard response.body.count <= Self.maximumMetadataResponseByteCount else {
      throw BaiduRemoteBackupContentVerificationError.metadataResponseTooLarge(
        maximum: Self.maximumMetadataResponseByteCount
      )
    }

    let decoded: FileMetasResponse
    do {
      decoded = try JSONDecoder().decode(FileMetasResponse.self, from: response.body)
    } catch {
      throw BaiduRemoteBackupContentVerificationError.malformedMetadataResponse
    }
    guard let errno = decoded.errno else {
      throw BaiduRemoteBackupContentVerificationError.malformedMetadataResponse
    }
    guard errno == 0 else {
      throw BaiduRemoteBackupContentVerificationError.metadataAPI(errno)
    }
    guard let entries = decoded.list, entries.count == 1,
      let entry = entries.first,
      entry.fsID == expectedFSID,
      entry.isdir == 0,
      let path = entry.path,
      Data(path.utf8) == target.pathBytes,
      let filename = entry.filename,
      Data(filename.utf8) == target.filenameBytes,
      let byteCount = entry.size,
      let dlink = entry.dlink,
      !dlink.isEmpty,
      dlink.utf8.count <= Self.maximumDLinkUTF8ByteCount,
      !dlink.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
      })
    else {
      throw BaiduRemoteBackupContentVerificationError.malformedMetadataResponse
    }
    return RemoteFileMetadata(byteCount: byteCount, dlink: dlink)
  }

  private func stream(_ request: URLRequest) async throws -> BaiduStreamedDownloadDigest {
    do {
      return try await byteStreamer.streamSHA256(
        request,
        maximumByteCount: BackupArchiveLimits.maximumArchiveByteCount
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch let error as BaiduRemoteBackupByteStreamError {
      switch error {
      case .invalidRequest:
        throw BaiduRemoteBackupContentVerificationError.insecureDownloadURL
      case .invalidResponse:
        throw BaiduRemoteBackupContentVerificationError.invalidDownloadHTTPResponse
      case .httpStatus(let statusCode):
        throw BaiduRemoteBackupContentVerificationError.downloadHTTPStatus(statusCode)
      case .responseTooLarge(let maximum):
        throw BaiduRemoteBackupContentVerificationError.downloadTooLarge(maximum: maximum)
      case .unsupportedContentEncoding:
        throw BaiduRemoteBackupContentVerificationError.unsupportedContentEncoding
      case .network, .unavailable:
        throw BaiduRemoteBackupContentVerificationError.downloadTransport
      }
    } catch {
      throw BaiduRemoteBackupContentVerificationError.downloadTransport
    }
  }

  private func makeMetadataRequest(
    fsID: UInt64,
    accessToken: BaiduAccessToken
  ) throws -> URLRequest {
    guard
      var components = URLComponents(
        url: Self.metadataEndpoint,
        resolvingAgainstBaseURL: false
      )
    else {
      throw BaiduRemoteBackupContentVerificationError.requestEncoding
    }
    components.queryItems = [
      URLQueryItem(name: "method", value: "filemetas"),
      URLQueryItem(name: "fsids", value: "[\(fsID)]"),
      URLQueryItem(name: "dlink", value: "1"),
      URLQueryItem(name: "access_token", value: accessToken.requestValue),
    ]
    guard let url = components.url else {
      throw BaiduRemoteBackupContentVerificationError.requestEncoding
    }
    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 15
    )
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent")
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    return request
  }

  private func makeDownloadRequest(
    dlink: String,
    accessToken: BaiduAccessToken
  ) throws -> URLRequest {
    guard let rawURL = URL(string: dlink),
      var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "https",
      components.host?.lowercased()
        == URLSessionBaiduRemoteBackupByteStreamer.initialDownloadHost,
      components.port == nil || components.port == 443,
      components.user == nil,
      components.password == nil,
      components.fragment == nil
    else {
      throw BaiduRemoteBackupContentVerificationError.insecureDownloadURL
    }
    let existingItems = components.queryItems ?? []
    guard
      !existingItems.contains(where: {
        $0.name.caseInsensitiveCompare("access_token") == .orderedSame
      })
    else {
      throw BaiduRemoteBackupContentVerificationError.insecureDownloadURL
    }
    components.queryItems =
      existingItems + [
        URLQueryItem(name: "access_token", value: accessToken.requestValue)
      ]
    guard let url = components.url, url.absoluteString.utf8.count <= 32 * 1024 else {
      throw BaiduRemoteBackupContentVerificationError.requestEncoding
    }

    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 120
    )
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent")
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    return request
  }

  private static func result(
    _ verification: BaiduRemoteBackupContentVerification,
    for record: BaiduUploadReconciliationRecord
  ) -> BaiduRemoteBackupContentVerificationResult {
    BaiduRemoteBackupContentVerificationResult(
      accountScope: record.accountScope,
      attemptID: record.attemptID,
      backupID: record.backupID,
      verification: verification
    )
  }

  private static func target(for record: BaiduUploadReconciliationRecord) -> Target? {
    guard record.schemaVersion == BaiduUploadReconciliationRecord.currentSchemaVersion,
      isLowercaseHex(record.archiveSHA256, count: 64),
      isLowercaseHex(record.localMD5, count: 32),
      record.localByteCount >= UInt64(BackupArchiveCodec.headerByteCount),
      record.localByteCount <= UInt64(BackupArchiveLimits.maximumArchiveByteCount)
    else {
      return nil
    }
    let components = record.requestedPath.split(
      separator: "/",
      omittingEmptySubsequences: false
    )
    guard components.count == 4,
      components[0].isEmpty,
      components[1] == "apps",
      let directory = try? BaiduNetdiskAppDirectory(folderName: String(components[2])),
      Data(directory.backupPath(backupID: record.backupID).utf8)
        == Data(record.requestedPath.utf8)
    else {
      return nil
    }
    return Target(
      pathBytes: Data(record.requestedPath.utf8),
      filenameBytes: Data(
        BaiduNetdiskAppDirectory.backupFilename(backupID: record.backupID).utf8
      )
    )
  }

  private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
    value.utf8.count == count
      && value.unicodeScalars.allSatisfy {
        (48...57).contains($0.value) || (97...102).contains($0.value)
      }
  }

  private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let lhsBytes = Array(lhs.utf8)
    let rhsBytes = Array(rhs.utf8)
    guard lhsBytes.count == rhsBytes.count else { return false }
    var difference: UInt8 = 0
    for index in lhsBytes.indices {
      difference |= lhsBytes[index] ^ rhsBytes[index]
    }
    return difference == 0
  }
}

extension BaiduRemoteBackupContentVerifier {
  fileprivate struct Target {
    let pathBytes: Data
    let filenameBytes: Data
  }

  fileprivate struct RemoteFileMetadata {
    let byteCount: UInt64
    let dlink: String
  }

  fileprivate struct FileMetasResponse: Decodable {
    let errno: Int?
    let list: [FileMeta]?
  }

  fileprivate struct FileMeta: Decodable {
    let fsID: UInt64?
    let path: String?
    let filename: String?
    let size: UInt64?
    let isdir: Int?
    let dlink: String?

    private enum CodingKeys: String, CodingKey {
      case fsID = "fs_id"
      case path
      case filename
      case size
      case isdir
      case dlink
    }
  }
}
