import Foundation

protocol BaiduRemoteBackupMetadataObserving: Sendable {
  func observe(
    record: BaiduUploadReconciliationRecord,
    credential: BaiduAccountBoundCredential
  ) async throws -> BaiduRemoteBackupMetadataObservationResult
}

struct BaiduObservedRemoteBackupMetadata: Equatable, Sendable {
  let fsID: UInt64
  let path: String
  let serverFilename: String
  let byteCount: UInt64
  let cloudMD5: String?
  let isDirectory: Bool
}

enum BaiduRemoteBackupMetadataIndeterminateReason: Equatable, Sendable {
  case duplicateExactPath
  case repeatedListingEntry
  case listingChangedDuringPagination
  case multiPageAbsenceUnproven
  case paginationLimitReached(maximumEntries: Int)
}

/// A metadata match is deliberately weaker than proof that the remote bytes equal the archive.
/// The official list response describes a cloud-side hash, so this type has no "verified" case.
enum BaiduRemoteBackupMetadataObservation: Equatable, Sendable {
  case exactMetadataMatchContentUnproven(BaiduObservedRemoteBackupMetadata)
  case metadataMismatch(BaiduObservedRemoteBackupMetadata)
  case notObservedAbsenceUnproven
  case indeterminate(BaiduRemoteBackupMetadataIndeterminateReason)
}

struct BaiduRemoteBackupMetadataObservationResult: Equatable, Sendable {
  let accountScope: BaiduAccountScope
  let attemptID: UUID
  let backupID: UUID
  let observation: BaiduRemoteBackupMetadataObservation
}

enum BaiduRemoteBackupMetadataObservationError: LocalizedError, Equatable, Sendable {
  case accountScopeMismatch
  case invalidRecord
  case credential(BaiduAccountCredentialError)
  case requestEncoding
  case transport
  case invalidHTTPResponse
  case httpStatus(Int)
  case responseTooLarge(maximum: Int)
  case malformedResponse
  case api(Int)

  var errorDescription: String? {
    switch self {
    case .accountScopeMismatch:
      "百度网盘凭据与待对账记录不属于同一账号，未发起查询。"
    case .invalidRecord:
      "百度网盘待对账记录无效，未发起查询。"
    case .credential:
      "百度网盘访问凭据已过期或剩余有效期不足，请重新连接。"
    case .requestEncoding:
      "无法安全构造百度网盘元数据查询。"
    case .transport:
      "连接百度网盘失败，请检查网络后重试。"
    case .invalidHTTPResponse:
      "百度网盘返回了无效的网络响应。"
    case .httpStatus(let statusCode):
      "百度网盘元数据查询失败（HTTP \(statusCode)）。"
    case .responseTooLarge:
      "百度网盘元数据响应超过安全上限。"
    case .malformedResponse:
      "百度网盘元数据响应无法验证。"
    case .api(let code):
      "百度网盘拒绝了元数据查询（错误码 \(code)）。"
    }
  }
}

struct BaiduRemoteBackupMetadataObserver: BaiduRemoteBackupMetadataObserving, Sendable {
  static let pageSize = 100
  static let maximumPageCount = 10
  static let maximumJSONResponseByteCount = 64 * 1024

  private static let endpoint = URL(
    string: "https://pan.baidu.com/rest/2.0/xpan/file"
  )!

  private let transport: any BaiduHTTPTransport
  private let now: @Sendable () -> Date

  init(
    transport: any BaiduHTTPTransport = URLSessionBaiduHTTPTransport(
      maximumResponseByteCount: BaiduRemoteBackupMetadataObserver
        .maximumJSONResponseByteCount
    ),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.transport = transport
    self.now = now
  }

  func observe(
    record: BaiduUploadReconciliationRecord,
    credential: BaiduAccountBoundCredential
  ) async throws -> BaiduRemoteBackupMetadataObservationResult {
    try Task.checkCancellation()
    guard record.accountScope == credential.accountScope else {
      throw BaiduRemoteBackupMetadataObservationError.accountScopeMismatch
    }
    guard let target = Self.target(for: record) else {
      throw BaiduRemoteBackupMetadataObservationError.invalidRecord
    }

    var exactMatch: BaiduObservedRemoteBackupMetadata?
    var seenPaths = Set<Data>()
    var seenFSIDs: [UInt64: Data] = [:]
    for pageIndex in 0..<Self.maximumPageCount {
      try Task.checkCancellation()
      let start = pageIndex * Self.pageSize
      let accessToken: BaiduAccessToken
      do {
        accessToken = try credential.requestAccessToken(at: now())
      } catch let error as BaiduAccountCredentialError {
        throw BaiduRemoteBackupMetadataObservationError.credential(error)
      }
      let request = try makeRequest(
        directoryPath: target.directoryPath,
        start: start,
        accessToken: accessToken
      )
      let page = try await send(request)
      guard page.entries.count <= Self.pageSize else {
        throw BaiduRemoteBackupMetadataObservationError.malformedResponse
      }

      for entry in page.entries {
        guard let path = entry.path, Self.isSafeAbsolutePath(path) else {
          throw BaiduRemoteBackupMetadataObservationError.malformedResponse
        }
        guard let fsID = entry.fsID, fsID > 0 else {
          throw BaiduRemoteBackupMetadataObservationError.malformedResponse
        }
        let pathBytes = Data(path.utf8)
        if let previousPath = seenFSIDs[fsID] {
          if previousPath == pathBytes {
            return Self.result(
              pathBytes == target.pathBytes
                ? .indeterminate(.duplicateExactPath)
                : .indeterminate(.repeatedListingEntry),
              for: record
            )
          }
          return Self.result(
            .indeterminate(.listingChangedDuringPagination),
            for: record
          )
        }
        seenFSIDs[fsID] = pathBytes
        guard seenPaths.insert(pathBytes).inserted else {
          return Self.result(
            pathBytes == target.pathBytes
              ? .indeterminate(.duplicateExactPath)
              : .indeterminate(.repeatedListingEntry),
            for: record
          )
        }
        guard pathBytes == target.pathBytes else { continue }
        let metadata = try Self.metadata(from: entry, target: target)
        guard exactMatch == nil else {
          return Self.result(.indeterminate(.duplicateExactPath), for: record)
        }
        exactMatch = metadata
      }

      if page.entries.count < Self.pageSize {
        if exactMatch == nil, pageIndex > 0 {
          return Self.result(
            .indeterminate(.multiPageAbsenceUnproven),
            for: record
          )
        }
        return Self.result(
          Self.classify(exactMatch, record: record, target: target),
          for: record
        )
      }
    }

    return Self.result(
      .indeterminate(
        .paginationLimitReached(
          maximumEntries: Self.pageSize * Self.maximumPageCount
        )
      ),
      for: record
    )
  }

  private func send(_ request: URLRequest) async throws -> ListPage {
    let response: BaiduHTTPResponse
    do {
      response = try await transport.send(request)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch let error as BaiduHTTPTransportError {
      switch error {
      case .invalidResponse:
        throw BaiduRemoteBackupMetadataObservationError.invalidHTTPResponse
      case .responseTooLarge(let maximum):
        throw BaiduRemoteBackupMetadataObservationError.responseTooLarge(
          maximum: maximum
        )
      case .network, .unavailable:
        throw BaiduRemoteBackupMetadataObservationError.transport
      }
    } catch {
      throw BaiduRemoteBackupMetadataObservationError.transport
    }

    try Task.checkCancellation()
    guard response.statusCode == 200 else {
      throw BaiduRemoteBackupMetadataObservationError.httpStatus(response.statusCode)
    }
    guard response.body.count <= Self.maximumJSONResponseByteCount else {
      throw BaiduRemoteBackupMetadataObservationError.responseTooLarge(
        maximum: Self.maximumJSONResponseByteCount
      )
    }

    let decoded: ListResponse
    do {
      decoded = try JSONDecoder().decode(ListResponse.self, from: response.body)
    } catch {
      throw BaiduRemoteBackupMetadataObservationError.malformedResponse
    }
    guard let errno = decoded.errno else {
      throw BaiduRemoteBackupMetadataObservationError.malformedResponse
    }
    guard errno == 0 else {
      throw BaiduRemoteBackupMetadataObservationError.api(errno)
    }
    guard let list = decoded.entries else {
      throw BaiduRemoteBackupMetadataObservationError.malformedResponse
    }
    return ListPage(entries: list)
  }

  private func makeRequest(
    directoryPath: String,
    start: Int,
    accessToken: BaiduAccessToken
  ) throws -> URLRequest {
    guard
      var components = URLComponents(
        url: Self.endpoint,
        resolvingAgainstBaseURL: false
      )
    else {
      throw BaiduRemoteBackupMetadataObservationError.requestEncoding
    }
    let queryItems = [
      ("method", "list"),
      ("dir", directoryPath),
      ("order", "name"),
      ("desc", "0"),
      ("start", String(start)),
      ("limit", String(Self.pageSize)),
      ("folder", "0"),
      ("access_token", accessToken.requestValue),
    ]
    var encodedItems: [String] = []
    encodedItems.reserveCapacity(queryItems.count)
    for (name, value) in queryItems {
      guard let encodedName = Self.queryEncode(name),
        let encodedValue = Self.queryEncode(value)
      else {
        throw BaiduRemoteBackupMetadataObservationError.requestEncoding
      }
      encodedItems.append("\(encodedName)=\(encodedValue)")
    }
    components.percentEncodedQuery = encodedItems.joined(separator: "&")
    guard let url = components.url else {
      throw BaiduRemoteBackupMetadataObservationError.requestEncoding
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

  private static func classify(
    _ metadata: BaiduObservedRemoteBackupMetadata?,
    record: BaiduUploadReconciliationRecord,
    target: Target
  ) -> BaiduRemoteBackupMetadataObservation {
    guard let metadata else { return .notObservedAbsenceUnproven }
    guard !metadata.isDirectory,
      Data(metadata.serverFilename.utf8) == target.filenameBytes,
      metadata.byteCount == record.localByteCount,
      metadata.cloudMD5 == record.localMD5
    else {
      return .metadataMismatch(metadata)
    }
    return .exactMetadataMatchContentUnproven(metadata)
  }

  private static func result(
    _ observation: BaiduRemoteBackupMetadataObservation,
    for record: BaiduUploadReconciliationRecord
  ) -> BaiduRemoteBackupMetadataObservationResult {
    BaiduRemoteBackupMetadataObservationResult(
      accountScope: record.accountScope,
      attemptID: record.attemptID,
      backupID: record.backupID,
      observation: observation
    )
  }

  private static func metadata(
    from entry: ListEntry,
    target: Target
  ) throws -> BaiduObservedRemoteBackupMetadata {
    guard let fsID = entry.fsID, fsID > 0,
      let serverFilename = entry.serverFilename,
      !serverFilename.isEmpty,
      serverFilename.utf8.count <= 255,
      !serverFilename.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
      }),
      let size = entry.size, size >= 0,
      let isdir = entry.isdir, isdir == 0 || isdir == 1
    else {
      throw BaiduRemoteBackupMetadataObservationError.malformedResponse
    }

    let cloudMD5: String?
    if isdir == 0 {
      guard let md5 = entry.md5, isLowercaseHex(md5, count: 32) else {
        throw BaiduRemoteBackupMetadataObservationError.malformedResponse
      }
      cloudMD5 = md5
    } else if let md5 = entry.md5, !md5.isEmpty {
      guard isLowercaseHex(md5, count: 32) else {
        throw BaiduRemoteBackupMetadataObservationError.malformedResponse
      }
      cloudMD5 = md5
    } else {
      cloudMD5 = nil
    }

    guard let path = entry.path, Data(path.utf8) == target.pathBytes else {
      throw BaiduRemoteBackupMetadataObservationError.malformedResponse
    }
    return BaiduObservedRemoteBackupMetadata(
      fsID: fsID,
      path: path,
      serverFilename: serverFilename,
      byteCount: UInt64(size),
      cloudMD5: cloudMD5,
      isDirectory: isdir == 1
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
      directoryPath: directory.remotePath,
      filenameBytes: Data(
        BaiduNetdiskAppDirectory.backupFilename(backupID: record.backupID).utf8
      )
    )
  }

  private static func isSafeAbsolutePath(_ path: String) -> Bool {
    guard path.hasPrefix("/"),
      path.utf8.count <= 4_096,
      !path.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
      })
    else {
      return false
    }
    return true
  }

  private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
    value.utf8.count == count
      && value.unicodeScalars.allSatisfy {
        (48...57).contains($0.value) || (97...102).contains($0.value)
      }
  }

  private static func queryEncode(_ value: String) -> String? {
    let unreserved = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
    return value.addingPercentEncoding(withAllowedCharacters: unreserved)
  }
}

extension BaiduRemoteBackupMetadataObserver {
  fileprivate struct Target {
    let pathBytes: Data
    let directoryPath: String
    let filenameBytes: Data
  }

  fileprivate struct ListPage {
    let entries: [ListEntry]
  }

  fileprivate struct ListResponse: Decodable {
    let errno: Int?
    let entries: [ListEntry]?

    private enum CodingKeys: String, CodingKey {
      case errno
      case entries = "list"
    }
  }

  fileprivate struct ListEntry: Decodable {
    let fsID: UInt64?
    let path: String?
    let serverFilename: String?
    let size: Int64?
    let isdir: Int?
    let md5: String?

    private enum CodingKeys: String, CodingKey {
      case fsID = "fs_id"
      case path
      case serverFilename = "server_filename"
      case size
      case isdir
      case md5
    }
  }
}
