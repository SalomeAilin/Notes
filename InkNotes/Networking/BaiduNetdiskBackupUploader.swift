import CryptoKit
import Foundation

protocol BaiduBackupUploading: Sendable {
  func upload(
    archive: Data,
    accessToken: BaiduAccessToken,
    applicationDirectory: BaiduNetdiskAppDirectory,
    progress: @escaping @Sendable (BaiduBackupUploadProgress) async throws -> Void
  ) async throws -> BaiduBackupUploadOutcome
}

struct BaiduNetdiskBackupUploader: BaiduBackupUploading, Sendable {
  static let chunkByteCount = 4 * 1024 * 1024
  static let maximumJSONResponseByteCount = 256 * 1024

  private static let fileEndpoint = URL(
    string: "https://pan.baidu.com/rest/2.0/xpan/file"
  )!
  private static let uploadPartEndpoint = URL(
    string: "https://d.pcs.baidu.com/rest/2.0/pcs/superfile2"
  )!

  private let transport: any BaiduHTTPTransport

  init(transport: any BaiduHTTPTransport = URLSessionBaiduHTTPTransport()) {
    self.transport = transport
  }

  func upload(
    archive: Data,
    accessToken: BaiduAccessToken,
    applicationDirectory: BaiduNetdiskAppDirectory,
    progress: @escaping @Sendable (BaiduBackupUploadProgress) async throws -> Void = { _ in }
  ) async throws -> BaiduBackupUploadOutcome {
    let plan = try Self.makeUploadPlan(
      archive: archive,
      applicationDirectory: applicationDirectory
    )
    try Task.checkCancellation()

    let precreate = try await precreate(
      plan: plan,
      accessToken: accessToken,
      progress: progress
    )
    if precreate.returnType == 2 {
      return .rapidUpload(
        BaiduRapidUploadReceipt(
          backupID: plan.backupID,
          requestedPath: plan.remotePath,
          localByteCount: UInt64(plan.archive.count),
          localMD5: plan.md5
        )
      )
    }

    let requestedPartIndices = try requestedPartIndices(
      precreate.blockList,
      chunkCount: plan.chunks.count
    )

    var uploadedPartMD5s: [String] = []
    uploadedPartMD5s.reserveCapacity(requestedPartIndices.count)
    for (offset, partIndex) in requestedPartIndices.enumerated() {
      try Task.checkCancellation()
      let chunk = plan.chunks[partIndex]
      let serverDigest = try await uploadPart(
        chunk,
        remotePath: plan.remotePath,
        uploadID: precreate.uploadID,
        accessToken: accessToken,
        ordinal: offset + 1,
        total: requestedPartIndices.count,
        progress: progress
      )
      guard serverDigest == chunk.md5 else {
        throw BaiduNetdiskUploadError.partDigestMismatch(partIndex)
      }
      uploadedPartMD5s.append(serverDigest)
    }

    try Task.checkCancellation()
    return .uploaded(
      try await createFile(
        plan: plan,
        uploadID: precreate.uploadID,
        uploadedPartMD5s: uploadedPartMD5s,
        accessToken: accessToken,
        progress: progress
      )
    )
  }

  static func makeUploadPlan(
    archive: Data,
    applicationDirectory: BaiduNetdiskAppDirectory
  ) throws -> BaiduBackupUploadPlan {
    let validated: ValidatedBackupArchive
    do {
      validated = try BackupArchiveCodec.decode(archive)
    } catch let error as BackupArchiveError {
      throw BaiduNetdiskUploadError.invalidBackup(error)
    } catch {
      throw BaiduNetdiskUploadError.invalidBackup(.invalidManifest)
    }

    var chunks: [BaiduBackupUploadChunk] = []
    chunks.reserveCapacity((archive.count + chunkByteCount - 1) / chunkByteCount)
    var offset = 0
    var index = 0
    while offset < archive.count {
      let byteCount = min(chunkByteCount, archive.count - offset)
      let lowerBound = archive.index(archive.startIndex, offsetBy: offset)
      let upperBound = archive.index(lowerBound, offsetBy: byteCount)
      let data = Data(archive[lowerBound..<upperBound])
      chunks.append(
        BaiduBackupUploadChunk(index: index, data: data, md5: md5Hex(data))
      )
      offset += byteCount
      index += 1
    }

    guard !chunks.isEmpty else {
      throw BaiduNetdiskUploadError.invalidBackup(.truncatedHeader)
    }
    return BaiduBackupUploadPlan(
      backupID: validated.backupID,
      remotePath: applicationDirectory.backupPath(backupID: validated.backupID),
      archive: archive,
      md5: md5Hex(archive),
      chunks: chunks
    )
  }

  static func md5Hex(_ data: Data) -> String {
    Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func precreate(
    plan: BaiduBackupUploadPlan,
    accessToken: BaiduAccessToken,
    progress: @escaping @Sendable (BaiduBackupUploadProgress) async throws -> Void
  ) async throws -> PrecreateResult {
    let stage = BaiduUploadStage.precreate
    let blockList = try encodeJSONString(plan.chunks.map(\.md5), stage: stage)
    let request = try makeFormRequest(
      endpoint: Self.fileEndpoint,
      queryItems: [
        URLQueryItem(name: "method", value: "precreate"),
        URLQueryItem(name: "access_token", value: accessToken.requestValue),
      ],
      formItems: [
        ("path", plan.remotePath),
        ("size", String(plan.archive.count)),
        ("isdir", "0"),
        ("autoinit", "1"),
        ("rtype", "0"),
        ("block_list", blockList),
      ],
      stage: stage
    )
    let response: PrecreateResponse = try await send(
      request,
      stage: stage,
      beforeSending: {
        try await progress(.precreateDispatchPermitted)
      }
    )
    guard let returnType = response.returnType, returnType == 1 || returnType == 2 else {
      throw BaiduNetdiskUploadError.invalidReturnType(response.returnType)
    }
    if returnType == 2 {
      return PrecreateResult(returnType: returnType, uploadID: "", blockList: [])
    }
    try await progress(.precreateUploadRequiredConfirmed)
    guard let uploadID = response.uploadid,
      !uploadID.isEmpty,
      uploadID.utf8.count <= 4_096,
      uploadID.unicodeScalars.allSatisfy({
        !CharacterSet.whitespacesAndNewlines.contains($0)
          && !CharacterSet.controlCharacters.contains($0)
      })
    else {
      throw BaiduNetdiskUploadError.invalidUploadID
    }
    guard let blockList = response.blockList, !blockList.isEmpty else {
      throw BaiduNetdiskUploadError.malformedResponse(stage)
    }
    return PrecreateResult(
      returnType: returnType,
      uploadID: uploadID,
      blockList: blockList
    )
  }

  private func uploadPart(
    _ chunk: BaiduBackupUploadChunk,
    remotePath: String,
    uploadID: String,
    accessToken: BaiduAccessToken,
    ordinal: Int,
    total: Int,
    progress: @escaping @Sendable (BaiduBackupUploadProgress) async throws -> Void
  ) async throws -> String {
    let stage = BaiduUploadStage.uploadPart(chunk.index)
    let url = try makeURL(
      endpoint: Self.uploadPartEndpoint,
      queryItems: [
        URLQueryItem(name: "access_token", value: accessToken.requestValue),
        URLQueryItem(name: "method", value: "upload"),
        URLQueryItem(name: "type", value: "tmpfile"),
        URLQueryItem(name: "path", value: remotePath),
        URLQueryItem(name: "uploadid", value: uploadID),
        URLQueryItem(name: "partseq", value: String(chunk.index)),
      ],
      stage: stage
    )

    let boundary = "InkNotesBoundary-\(UUID().uuidString)"
    let body = multipartBody(fileData: chunk.data, boundary: boundary)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue(
      "multipart/form-data; boundary=\(boundary)",
      forHTTPHeaderField: "Content-Type"
    )
    request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
    applyCommonHeaders(to: &request)

    let response: UploadPartResponse = try await send(
      request,
      stage: stage,
      beforeSending: {
        try await progress(
          .uploadPartDispatchPermitted(
            partIndex: chunk.index,
            ordinal: ordinal,
            total: total
          )
        )
      }
    )
    guard let md5 = response.md5, Self.isLowercaseMD5(md5) else {
      throw BaiduNetdiskUploadError.malformedResponse(stage)
    }
    return md5
  }

  private func createFile(
    plan: BaiduBackupUploadPlan,
    uploadID: String,
    uploadedPartMD5s: [String],
    accessToken: BaiduAccessToken,
    progress: @escaping @Sendable (BaiduBackupUploadProgress) async throws -> Void
  ) async throws -> BaiduRemoteBackup {
    let stage = BaiduUploadStage.create
    let blockList = try encodeJSONString(uploadedPartMD5s, stage: stage)
    let request = try makeFormRequest(
      endpoint: Self.fileEndpoint,
      queryItems: [
        URLQueryItem(name: "method", value: "create"),
        URLQueryItem(name: "access_token", value: accessToken.requestValue),
      ],
      formItems: [
        ("path", plan.remotePath),
        ("size", String(plan.archive.count)),
        ("isdir", "0"),
        ("rtype", "0"),
        ("uploadid", uploadID),
        ("block_list", blockList),
      ],
      stage: stage
    )

    let response: CreateFileResponse = try await send(
      request,
      stage: stage,
      beforeSending: {
        try await progress(.createDispatchPermitted)
      }
    )
    guard let fsID = response.fsID, fsID > 0,
      let path = response.path,
      let size = response.size,
      let md5 = response.md5,
      response.isdir == 0,
      Self.isLowercaseMD5(md5)
    else {
      throw BaiduNetdiskUploadError.malformedResponse(stage)
    }
    guard path == plan.remotePath else {
      throw BaiduNetdiskUploadError.committedPathMismatch
    }
    guard size == UInt64(plan.archive.count) else {
      throw BaiduNetdiskUploadError.committedSizeMismatch
    }
    guard md5 == plan.md5 else {
      throw BaiduNetdiskUploadError.committedDigestMismatch
    }

    return BaiduRemoteBackup(
      backupID: plan.backupID,
      fsID: fsID,
      path: path,
      byteCount: size,
      md5: md5
    )
  }

  private func requestedPartIndices(
    _ indices: [Int],
    chunkCount: Int
  ) throws -> [Int] {
    var seen = Set<Int>()
    for index in indices {
      guard (0..<chunkCount).contains(index) else {
        throw BaiduNetdiskUploadError.invalidPartIndex(index)
      }
      guard seen.insert(index).inserted else {
        throw BaiduNetdiskUploadError.duplicatePartIndex(index)
      }
    }
    return indices
  }

  private func send<Response: Decodable & BaiduAPIStatusResponse>(
    _ request: URLRequest,
    stage: BaiduUploadStage,
    beforeSending: @escaping @Sendable () async throws -> Void
  ) async throws -> Response {
    try Task.checkCancellation()
    try await beforeSending()
    let response: BaiduHTTPResponse
    do {
      response = try await transport.send(request)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as BaiduHTTPTransportError {
      if case .invalidResponse = error {
        throw BaiduNetdiskUploadError.invalidHTTPResponse(stage)
      }
      if case .responseTooLarge(let maximum) = error {
        throw BaiduNetdiskUploadError.responseTooLarge(
          stage: stage,
          maximum: maximum
        )
      }
      throw BaiduNetdiskUploadError.transport(stage)
    } catch {
      throw BaiduNetdiskUploadError.transport(stage)
    }

    guard (200..<300).contains(response.statusCode) else {
      throw BaiduNetdiskUploadError.httpStatus(
        stage: stage,
        statusCode: response.statusCode
      )
    }
    guard response.body.count <= Self.maximumJSONResponseByteCount else {
      throw BaiduNetdiskUploadError.responseTooLarge(
        stage: stage,
        maximum: Self.maximumJSONResponseByteCount
      )
    }

    let decoded: Response
    do {
      decoded = try JSONDecoder().decode(Response.self, from: response.body)
    } catch {
      throw BaiduNetdiskUploadError.malformedResponse(stage)
    }
    if let code = decoded.apiErrorCode, code != 0 {
      throw BaiduNetdiskUploadError.api(stage: stage, code: code)
    }
    return decoded
  }

  private func makeFormRequest(
    endpoint: URL,
    queryItems: [URLQueryItem],
    formItems: [(String, String)],
    stage: BaiduUploadStage
  ) throws -> URLRequest {
    let url = try makeURL(endpoint: endpoint, queryItems: queryItems, stage: stage)
    var encodedItems: [String] = []
    encodedItems.reserveCapacity(formItems.count)
    for (key, value) in formItems {
      guard let encodedKey = formEncode(key), let encodedValue = formEncode(value) else {
        throw BaiduNetdiskUploadError.requestEncoding(stage)
      }
      encodedItems.append("\(encodedKey)=\(encodedValue)")
    }
    let body = encodedItems.joined(separator: "&")

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = Data(body.utf8)
    request.setValue(
      "application/x-www-form-urlencoded; charset=utf-8",
      forHTTPHeaderField: "Content-Type"
    )
    applyCommonHeaders(to: &request)
    return request
  }

  private func makeURL(
    endpoint: URL,
    queryItems: [URLQueryItem],
    stage: BaiduUploadStage
  ) throws -> URL {
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      throw BaiduNetdiskUploadError.requestEncoding(stage)
    }
    components.queryItems = queryItems
    guard let url = components.url else {
      throw BaiduNetdiskUploadError.requestEncoding(stage)
    }
    return url
  }

  private func encodeJSONString(
    _ values: [String],
    stage: BaiduUploadStage
  ) throws -> String {
    do {
      let data = try JSONEncoder().encode(values)
      guard let value = String(data: data, encoding: .utf8) else {
        throw BaiduNetdiskUploadError.requestEncoding(stage)
      }
      return value
    } catch let error as BaiduNetdiskUploadError {
      throw error
    } catch {
      throw BaiduNetdiskUploadError.requestEncoding(stage)
    }
  }

  private func formEncode(_ value: String) -> String? {
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
    return value.addingPercentEncoding(withAllowedCharacters: allowed)
  }

  private func multipartBody(fileData: Data, boundary: String) -> Data {
    var body = Data()
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(
      Data("Content-Disposition: form-data; name=\"file\"; filename=\"part\"\r\n".utf8)
    )
    body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
    body.append(fileData)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return body
  }

  private func applyCommonHeaders(to request: inout URLRequest) {
    request.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent")
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    request.timeoutInterval = 120
  }

  private static func isLowercaseMD5(_ value: String) -> Bool {
    value.utf8.count == 32
      && value.unicodeScalars.allSatisfy {
        (48...57).contains($0.value) || (97...102).contains($0.value)
      }
  }
}

private protocol BaiduAPIStatusResponse {
  var errno: Int? { get }
  var errorCode: Int? { get }
}

extension BaiduAPIStatusResponse {
  var apiErrorCode: Int? {
    if let errno, errno != 0 { return errno }
    if let errorCode, errorCode != 0 { return errorCode }
    return errno ?? errorCode
  }
}

private struct PrecreateResult: Sendable {
  let returnType: Int
  let uploadID: String
  let blockList: [Int]
}

private struct PrecreateResponse: Decodable, BaiduAPIStatusResponse {
  let errno: Int?
  let errorCode: Int?
  let returnType: Int?
  let uploadid: String?
  let blockList: [Int]?

  private enum CodingKeys: String, CodingKey {
    case errno
    case errorCode = "error_code"
    case returnType = "return_type"
    case uploadid
    case blockList = "block_list"
  }
}

private struct UploadPartResponse: Decodable, BaiduAPIStatusResponse {
  let errno: Int?
  let errorCode: Int?
  let md5: String?

  private enum CodingKeys: String, CodingKey {
    case errno
    case errorCode = "error_code"
    case md5
  }
}

private struct CreateFileResponse: Decodable, BaiduAPIStatusResponse {
  let errno: Int?
  let errorCode: Int?
  let fsID: UInt64?
  let md5: String?
  let path: String?
  let size: UInt64?
  let isdir: Int?

  private enum CodingKeys: String, CodingKey {
    case errno
    case errorCode = "error_code"
    case fsID = "fs_id"
    case md5
    case path
    case size
    case isdir
  }
}
