import Foundation
import Testing

@testable import InkNotesCore

@Suite("Baidu Netdisk backup upload core")
struct BaiduNetdiskBackupUploaderTests {
  private let backupID = UUID(uuidString: "B1000000-0000-0000-0000-000000000001")!

  @Test("Credentials are redacted and application directories are single safe components")
  func credentialAndPathBoundaries() throws {
    let secret = "test.access-token_value-123"
    let token = try BaiduAccessToken(secret)
    #expect(String(describing: token) == "<redacted>")
    #expect(String(reflecting: token) == "<redacted>")
    #expect(!String(describing: token).contains(secret))
    #expect(Array(Mirror(reflecting: token).children).isEmpty)
    var dumpOutput = ""
    dump(token, to: &dumpOutput)
    #expect(!dumpOutput.contains(secret))

    #expect(throws: BaiduNetdiskConfigurationError.invalidAccessToken) {
      try BaiduAccessToken("")
    }
    #expect(throws: BaiduNetdiskConfigurationError.invalidAccessToken) {
      try BaiduAccessToken("token\nvalue")
    }

    let directory = try BaiduNetdiskAppDirectory(folderName: "测试应用_1")
    #expect(directory.remotePath == "/apps/测试应用_1")
    #expect(
      directory.backupPath(backupID: backupID)
        == "/apps/测试应用_1/backup-b1000000-0000-0000-0000-000000000001.notesbackup"
    )

    for invalidName in ["", " 前导", "尾随 ", "a/b", "a\\b", "a%b", "emoji😀"] {
      #expect(throws: BaiduNetdiskConfigurationError.invalidApplicationFolderName) {
        try BaiduNetdiskAppDirectory(folderName: invalidName)
      }
    }
  }

  @Test("An invalid archive fails before any HTTP request")
  func invalidArchiveMakesNoRequest() async throws {
    let transport = ScriptedBaiduHTTPTransport(handlers: [])
    let uploader = BaiduNetdiskBackupUploader(transport: transport)

    await #expect(
      throws: BaiduNetdiskUploadError.invalidBackup(.truncatedHeader)
    ) {
      try await uploader.upload(
        archive: Data(),
        accessToken: self.accessToken(),
        applicationDirectory: self.applicationDirectory()
      )
    }
    #expect(await transport.requestCount() == 0)
  }

  @Test("Four MiB is one chunk and one extra byte starts a second chunk")
  func fourMiBChunkBoundary() throws {
    let oneChunkArchive = try makeArchive(exactByteCount: 4 * 1024 * 1024)
    let twoChunkArchive = try makeArchive(exactByteCount: 4 * 1024 * 1024 + 1)

    let oneChunk = try BaiduNetdiskBackupUploader.makeUploadPlan(
      archive: oneChunkArchive,
      applicationDirectory: applicationDirectory()
    )
    let twoChunks = try BaiduNetdiskBackupUploader.makeUploadPlan(
      archive: twoChunkArchive,
      applicationDirectory: applicationDirectory()
    )

    #expect(oneChunk.chunks.map(\.data.count) == [4 * 1024 * 1024])
    #expect(twoChunks.chunks.map(\.data.count) == [4 * 1024 * 1024, 1])
    #expect(oneChunk.chunks[0].md5 == BaiduNetdiskBackupUploader.md5Hex(oneChunkArchive))
  }

  @Test("A complete upload emits the documented request sequence and fields")
  func completeUploadSequence() async throws {
    let archive = try makeArchive()
    let directory = try applicationDirectory()
    let plan = try BaiduNetdiskBackupUploader.makeUploadPlan(
      archive: archive,
      applicationDirectory: directory
    )
    let transport = ScriptedBaiduHTTPTransport(
      handlers: try successfulHandlers(plan: plan, requestedPartIndices: [0])
    )
    let uploader = BaiduNetdiskBackupUploader(transport: transport)

    let outcome = try await uploader.upload(
      archive: archive,
      accessToken: accessToken(),
      applicationDirectory: directory
    )
    let result: BaiduRemoteBackup
    switch outcome {
    case .uploaded(let remoteBackup):
      result = remoteBackup
    case .rapidUpload:
      Issue.record("Expected the ordinary upload outcome")
      return
    }
    let requests = await transport.requests()

    #expect(requests.count == 3)
    #expect(result.backupID == backupID)
    #expect(result.path == plan.remotePath)
    #expect(result.byteCount == UInt64(archive.count))
    #expect(result.md5 == plan.md5)

    let precreate = requests[0]
    #expect(precreate.httpMethod == "POST")
    #expect(precreate.url?.host == "pan.baidu.com")
    #expect(precreate.url?.path == "/rest/2.0/xpan/file")
    #expect(try queryItems(precreate)["method"] == "precreate")
    #expect(try queryItems(precreate)["access_token"] == "test.access-token_value-123")
    let precreateForm = try formItems(precreate)
    let expectedBlockList = try jsonString(plan.chunks.map(\.md5))
    #expect(precreateForm["path"] == plan.remotePath)
    #expect(precreateForm["size"] == String(archive.count))
    #expect(precreateForm["isdir"] == "0")
    #expect(precreateForm["autoinit"] == "1")
    #expect(precreateForm["rtype"] == "0")
    #expect(precreateForm["block_list"] == expectedBlockList)
    #expect(
      Set(precreateForm.keys)
        == Set(["path", "size", "isdir", "autoinit", "rtype", "block_list"])
    )

    let part = requests[1]
    let partQuery = try queryItems(part)
    #expect(part.httpMethod == "POST")
    #expect(part.url?.scheme == "https")
    #expect(part.url?.host == "d.pcs.baidu.com")
    #expect(part.url?.path == "/rest/2.0/pcs/superfile2")
    #expect(partQuery["method"] == "upload")
    #expect(partQuery["type"] == "tmpfile")
    #expect(partQuery["partseq"] == "0")
    #expect(try multipartPayload(part) == plan.chunks[0].data)
    #expect(part.value(forHTTPHeaderField: "User-Agent") == "pan.baidu.com")

    let create = requests[2]
    #expect(create.httpMethod == "POST")
    #expect(try queryItems(create)["method"] == "create")
    let createForm = try formItems(create)
    #expect(createForm["path"] == plan.remotePath)
    #expect(createForm["size"] == String(archive.count))
    #expect(createForm["rtype"] == "0")
    #expect(createForm["block_list"] == expectedBlockList)
    #expect(
      Set(createForm.keys)
        == Set(["path", "size", "isdir", "rtype", "uploadid", "block_list"])
    )

    for request in requests {
      let query = try queryItems(request)
      #expect(query["method"] != "locateupload")
      #expect(query["appid"] == nil)
      #expect(query["upload_version"] == nil)
    }
  }

  @Test("Dispatch checkpoints follow precreate, part, and create order")
  func dispatchCheckpointSequence() async throws {
    let archive = try makeArchive()
    let directory = try applicationDirectory()
    let plan = try BaiduNetdiskBackupUploader.makeUploadPlan(
      archive: archive,
      applicationDirectory: directory
    )
    let transport = ScriptedBaiduHTTPTransport(
      handlers: try successfulHandlers(plan: plan, requestedPartIndices: [0])
    )
    let recorder = BaiduProgressRecorder()

    _ = try await BaiduNetdiskBackupUploader(transport: transport).upload(
      archive: archive,
      accessToken: accessToken(),
      applicationDirectory: directory,
      progress: { progress in
        await recorder.append(progress)
      }
    )

    #expect(
      await recorder.values()
        == [
          .precreateDispatchPermitted,
          .uploadPartDispatchPermitted(partIndex: 0, ordinal: 1, total: 1),
          .createDispatchPermitted,
        ]
    )
  }

  @Test("A rejected create checkpoint prevents the create request")
  func rejectedCreateCheckpointPreventsDispatch() async throws {
    let archive = try makeArchive()
    let directory = try applicationDirectory()
    let plan = try BaiduNetdiskBackupUploader.makeUploadPlan(
      archive: archive,
      applicationDirectory: directory
    )
    let transport = ScriptedBaiduHTTPTransport(
      handlers: Array(
        try successfulHandlers(plan: plan, requestedPartIndices: [0]).dropLast()
      )
    )
    var receivedCancellation = false

    do {
      _ = try await BaiduNetdiskBackupUploader(transport: transport).upload(
        archive: archive,
        accessToken: accessToken(),
        applicationDirectory: directory,
        progress: { progress in
          if progress == .createDispatchPermitted {
            throw CancellationError()
          }
        }
      )
    } catch is CancellationError {
      receivedCancellation = true
    }

    #expect(receivedCancellation)
    #expect(await transport.requestCount() == 2)
  }

  @Test("Return type two finishes after precreate without inventing remote metadata")
  func rapidUploadStopsAfterPrecreate() async throws {
    let archive = try makeArchive()
    let directory = try applicationDirectory()
    let plan = try BaiduNetdiskBackupUploader.makeUploadPlan(
      archive: archive,
      applicationDirectory: directory
    )
    let precreate = try jsonData([
      "errno": 0,
      "return_type": 2,
      "uploadid": "",
      "block_list": [],
    ])
    let transport = ScriptedBaiduHTTPTransport(handlers: [
      { _ in Self.response(body: precreate) }
    ])

    let outcome = try await BaiduNetdiskBackupUploader(transport: transport).upload(
      archive: archive,
      accessToken: accessToken(),
      applicationDirectory: directory
    )

    #expect(
      outcome
        == .rapidUpload(
          BaiduRapidUploadReceipt(
            backupID: backupID,
            requestedPath: plan.remotePath,
            localByteCount: UInt64(archive.count),
            localMD5: plan.md5
          )
        )
    )
    #expect(await transport.requestCount() == 1)
  }

  @Test("Only server-requested missing chunks are uploaded")
  func uploadsOnlyRequestedChunks() async throws {
    let archive = try makeArchive(exactByteCount: 4 * 1024 * 1024 + 1)
    let directory = try applicationDirectory()
    let plan = try BaiduNetdiskBackupUploader.makeUploadPlan(
      archive: archive,
      applicationDirectory: directory
    )
    let transport = ScriptedBaiduHTTPTransport(
      handlers: try successfulHandlers(plan: plan, requestedPartIndices: [1])
    )

    _ = try await BaiduNetdiskBackupUploader(transport: transport).upload(
      archive: archive,
      accessToken: accessToken(),
      applicationDirectory: directory
    )
    let requests = await transport.requests()

    #expect(requests.count == 3)
    #expect(try queryItems(requests[1])["partseq"] == "1")
    #expect(try multipartPayload(requests[1]) == plan.chunks[1].data)
    let createForm = try formItems(requests[2])
    let uploadedBlockList = try jsonString([plan.chunks[1].md5])
    let completeLocalBlockList = try jsonString(plan.chunks.map(\.md5))
    #expect(createForm["block_list"] == uploadedBlockList)
    #expect(createForm["block_list"] != completeLocalBlockList)
  }

  @Test("Duplicate and out-of-range server part indices fail closed")
  func invalidPartIndicesFailClosed() async throws {
    let archive = try makeArchive()
    let directory = try applicationDirectory()
    for (indices, expectedError) in [
      ([0, 0], BaiduNetdiskUploadError.duplicatePartIndex(0)),
      ([1], BaiduNetdiskUploadError.invalidPartIndex(1)),
    ] {
      let body = try jsonData([
        "errno": 0,
        "return_type": 1,
        "uploadid": "upload-id",
        "block_list": indices,
      ])
      let transport = ScriptedBaiduHTTPTransport(
        handlers: [{ _ in Self.response(body: body) }]
      )

      await #expect(throws: expectedError) {
        try await BaiduNetdiskBackupUploader(transport: transport).upload(
          archive: archive,
          accessToken: self.accessToken(),
          applicationDirectory: directory
        )
      }
      #expect(await transport.requestCount() == 1)
    }
  }

  @Test("Precreate accepts only documented return types one and two")
  func invalidReturnTypesFailClosed() async throws {
    let archive = try makeArchive()
    let directory = try applicationDirectory()

    for returnType in [nil, 0, 3] as [Int?] {
      var object: [String: Any] = ["errno": 0]
      if let returnType {
        object["return_type"] = returnType
      }
      let body = try jsonData(object)
      let transport = ScriptedBaiduHTTPTransport(
        handlers: [{ _ in Self.response(body: body) }]
      )

      await #expect(
        throws: BaiduNetdiskUploadError.invalidReturnType(returnType)
      ) {
        try await BaiduNetdiskBackupUploader(transport: transport).upload(
          archive: archive,
          accessToken: self.accessToken(),
          applicationDirectory: directory
        )
      }
      #expect(await transport.requestCount() == 1)
    }
  }

  @Test("Return type one with an empty part list fails before file creation")
  func emptyPartListFailsClosed() async throws {
    let archive = try makeArchive(exactByteCount: 4 * 1024 * 1024 + 1)
    let directory = try applicationDirectory()
    let plan = try BaiduNetdiskBackupUploader.makeUploadPlan(
      archive: archive,
      applicationDirectory: directory
    )
    let transport = ScriptedBaiduHTTPTransport(
      handlers: try successfulHandlers(plan: plan, requestedPartIndices: [])
    )
    await #expect(throws: BaiduNetdiskUploadError.malformedResponse(.precreate)) {
      try await BaiduNetdiskBackupUploader(transport: transport).upload(
        archive: archive,
        accessToken: self.accessToken(),
        applicationDirectory: directory
      )
    }
    #expect(await transport.requestCount() == 1)
  }

  @Test("A mismatched uploaded-part digest prevents file creation")
  func partDigestMismatchStopsCreate() async throws {
    let archive = try makeArchive()
    let directory = try applicationDirectory()
    let plan = try BaiduNetdiskBackupUploader.makeUploadPlan(
      archive: archive,
      applicationDirectory: directory
    )
    let handlers = try successfulHandlers(
      plan: plan,
      requestedPartIndices: [0],
      partDigestOverrides: [0: "00000000000000000000000000000000"]
    ).dropLast()
    let transport = ScriptedBaiduHTTPTransport(handlers: Array(handlers))

    await #expect(throws: BaiduNetdiskUploadError.partDigestMismatch(0)) {
      try await BaiduNetdiskBackupUploader(transport: transport).upload(
        archive: archive,
        accessToken: self.accessToken(),
        applicationDirectory: directory
      )
    }
    #expect(await transport.requestCount() == 2)
  }

  @Test("Committed path, size, and digest must exactly match the upload plan")
  func createMetadataMustMatch() async throws {
    let archive = try makeArchive()
    let directory = try applicationDirectory()
    let plan = try BaiduNetdiskBackupUploader.makeUploadPlan(
      archive: archive,
      applicationDirectory: directory
    )
    let cases: [(String, UInt64, String, BaiduNetdiskUploadError)] = [
      (plan.remotePath + ".renamed", UInt64(archive.count), plan.md5, .committedPathMismatch),
      (plan.remotePath, UInt64(archive.count + 1), plan.md5, .committedSizeMismatch),
      (
        plan.remotePath,
        UInt64(archive.count),
        "00000000000000000000000000000000",
        .committedDigestMismatch
      ),
    ]

    for (path, size, digest, expectedError) in cases {
      let transport = ScriptedBaiduHTTPTransport(
        handlers: try successfulHandlers(
          plan: plan,
          requestedPartIndices: [0],
          committedPath: path,
          committedSize: size,
          committedDigest: digest
        )
      )
      await #expect(throws: expectedError) {
        try await BaiduNetdiskBackupUploader(transport: transport).upload(
          archive: archive,
          accessToken: self.accessToken(),
          applicationDirectory: directory
        )
      }
      #expect(await transport.requestCount() == 3)
    }
  }

  @Test("HTTP status, API errno, malformed JSON, and oversized JSON are distinct")
  func responseFailuresAreTyped() async throws {
    let archive = try makeArchive()
    let directory = try applicationDirectory()
    let cases: [(BaiduHTTPResponse, BaiduNetdiskUploadError)] = [
      (
        Self.response(body: Data("{}".utf8), statusCode: 503),
        .httpStatus(stage: .precreate, statusCode: 503)
      ),
      (
        Self.response(body: Data("{\"errno\":31024}".utf8)),
        .api(stage: .precreate, code: 31024)
      ),
      (
        Self.response(body: Data("not-json".utf8)),
        .malformedResponse(.precreate)
      ),
      (
        Self.response(
          body: Data(
            repeating: 0x20,
            count: BaiduNetdiskBackupUploader.maximumJSONResponseByteCount + 1
          )
        ),
        .responseTooLarge(
          stage: .precreate,
          maximum: BaiduNetdiskBackupUploader.maximumJSONResponseByteCount
        )
      ),
    ]

    for (response, expectedError) in cases {
      let transport = ScriptedBaiduHTTPTransport(handlers: [{ _ in response }])
      await #expect(throws: expectedError) {
        try await BaiduNetdiskBackupUploader(transport: transport).upload(
          archive: archive,
          accessToken: self.accessToken(),
          applicationDirectory: directory
        )
      }
      #expect(await transport.requestCount() == 1)
    }
  }

  @Test("Cancellation is propagated and no later request is sent")
  func cancellationIsPropagated() async throws {
    let archive = try makeArchive()
    let transport = ScriptedBaiduHTTPTransport(handlers: [
      { _ in throw CancellationError() }
    ])
    var receivedCancellation = false

    do {
      _ = try await BaiduNetdiskBackupUploader(transport: transport).upload(
        archive: archive,
        accessToken: accessToken(),
        applicationDirectory: applicationDirectory()
      )
    } catch is CancellationError {
      receivedCancellation = true
    }

    #expect(receivedCancellation)
    #expect(await transport.requestCount() == 1)
  }

  @Test("Transport errors never expose the token or failing URL")
  func transportErrorsAreRedacted() async throws {
    let archive = try makeArchive()
    let secret = "secret-access-token-for-redaction"
    let transport = ScriptedBaiduHTTPTransport(handlers: [
      { _ in
        throw URLError(
          .cannotConnectToHost,
          userInfo: [
            NSURLErrorFailingURLStringErrorKey:
              "https://pan.baidu.com/example?access_token=\(secret)"
          ]
        )
      }
    ])

    do {
      _ = try await BaiduNetdiskBackupUploader(transport: transport).upload(
        archive: archive,
        accessToken: BaiduAccessToken(secret),
        applicationDirectory: applicationDirectory()
      )
      Issue.record("Expected a redacted transport error")
    } catch let error as BaiduNetdiskUploadError {
      let rendered = String(describing: error) + (error.localizedDescription)
      #expect(error == .transport(.precreate))
      #expect(!rendered.contains(secret))
      #expect(!rendered.contains("access_token"))
    }
  }

  @Test("Production transport stops at the streaming response limit")
  func productionTransportStreamsWithHardLimit() async throws {
    let path = "/oversized-\(UUID().uuidString)"
    let maximum = URLSessionBaiduHTTPTransport.maximumResponseByteCount
    ControlledBaiduURLProtocol.register(
      .response(
        statusCode: 200,
        headers: ["Content-Length": String(maximum + 1)],
        chunks: [Data(repeating: 0x41, count: maximum + 1)]
      ),
      path: path
    )
    let request = URLRequest(
      url: try #require(URL(string: "https://baidu-transport.test\(path)"))
    )

    await #expect(
      throws: BaiduHTTPTransportError.responseTooLarge(maximum: maximum)
    ) {
      try await productionTransport().send(request)
    }
    #expect(ControlledBaiduURLProtocol.requestCount(path: path) == 1)
  }

  @Test("Per-task redirect delegate always refuses redirected requests")
  func redirectDelegateRejectsRedirects() throws {
    let source = try #require(URL(string: "https://pan.baidu.com/source"))
    let target = try #require(URL(string: "https://example.invalid/target"))
    let response = try #require(
      HTTPURLResponse(
        url: source,
        statusCode: 302,
        httpVersion: "HTTP/1.1",
        headerFields: ["Location": target.absoluteString]
      )
    )
    let session = URLSession(configuration: .ephemeral)
    let task = session.dataTask(with: source)
    var redirectDecision: URLRequest??

    BaiduNoRedirectDelegate().urlSession(
      session,
      task: task,
      willPerformHTTPRedirection: response,
      newRequest: URLRequest(url: target)
    ) { decision in
      redirectDecision = decision
    }

    #expect(redirectDecision != nil)
    #expect(redirectDecision! == nil)
  }

  @Test("Cancelling a real production transport task cancels URLSession work")
  func productionTransportPropagatesRealTaskCancellation() async throws {
    let path = "/hanging-\(UUID().uuidString)"
    ControlledBaiduURLProtocol.register(.hanging(statusCode: 200), path: path)
    let url = try #require(URL(string: "https://baidu-transport.test\(path)"))
    let transport = productionTransport()
    let task = Task {
      try await transport.send(URLRequest(url: url))
    }

    for _ in 0..<100 where ControlledBaiduURLProtocol.requestCount(path: path) == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(ControlledBaiduURLProtocol.requestCount(path: path) == 1)
    task.cancel()

    do {
      _ = try await task.value
      Issue.record("Expected CancellationError")
    } catch is CancellationError {
      // Expected: the production transport maps URLSession cancellation.
    }

    for _ in 0..<100 where ControlledBaiduURLProtocol.stopCount(path: path) == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(ControlledBaiduURLProtocol.stopCount(path: path) > 0)
  }

  private func accessToken() throws -> BaiduAccessToken {
    try BaiduAccessToken("test.access-token_value-123")
  }

  private func applicationDirectory() throws -> BaiduNetdiskAppDirectory {
    try BaiduNetdiskAppDirectory(folderName: "测试应用")
  }

  private func productionTransport() -> URLSessionBaiduHTTPTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ControlledBaiduURLProtocol.self]
    return URLSessionBaiduHTTPTransport(
      session: URLSession(configuration: configuration)
    )
  }

  private func makeArchive(drawingByteCount: Int = 0) throws -> Data {
    try makeArchive(drawingByteCount: drawingByteCount, library: LibraryDocument.starter())
  }

  private func makeArchive(exactByteCount targetByteCount: Int) throws -> Data {
    let library = LibraryDocument.starter()
    var drawingByteCount = max(0, targetByteCount - 2_048)

    for _ in 0..<16 {
      let archive = try makeArchive(
        drawingByteCount: drawingByteCount,
        library: library
      )
      if archive.count == targetByteCount {
        return archive
      }
      drawingByteCount += targetByteCount - archive.count
      guard drawingByteCount >= 0 else {
        throw BaiduUploaderTestError.couldNotCreateExactArchive
      }
    }
    throw BaiduUploaderTestError.couldNotCreateExactArchive
  }

  private func makeArchive(
    drawingByteCount: Int,
    library: LibraryDocument
  ) throws -> Data {
    let pageID = try #require(library.notebooks.first?.pages.first?.id)
    return try BackupArchiveCodec.encode(
      library: library,
      drawings: [pageID: Data(repeating: 0x7A, count: drawingByteCount)],
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      backupID: backupID,
      sourceAppVersion: "0.2.0",
      sourceBuild: "2"
    )
  }

  private func successfulHandlers(
    plan: BaiduBackupUploadPlan,
    requestedPartIndices: [Int],
    partDigestOverrides: [Int: String] = [:],
    committedPath: String? = nil,
    committedSize: UInt64? = nil,
    committedDigest: String? = nil
  ) throws -> [ScriptedBaiduHTTPTransport.Handler] {
    let precreate = try jsonData([
      "errno": 0,
      "return_type": 1,
      "uploadid": "upload-id",
      "block_list": requestedPartIndices,
    ])
    var handlers: [ScriptedBaiduHTTPTransport.Handler] = [
      { _ in Self.response(body: precreate) }
    ]

    for index in requestedPartIndices where (0..<plan.chunks.count).contains(index) {
      let digest = partDigestOverrides[index] ?? plan.chunks[index].md5
      let part = try jsonData(["md5": digest])
      handlers.append { _ in Self.response(body: part) }
    }

    let create = try jsonData([
      "errno": 0,
      "fs_id": 123_456,
      "md5": committedDigest ?? plan.md5,
      "path": committedPath ?? plan.remotePath,
      "size": committedSize ?? UInt64(plan.archive.count),
      "isdir": 0,
    ])
    handlers.append { _ in Self.response(body: create) }
    return handlers
  }

  private static func response(
    body: Data,
    statusCode: Int = 200
  ) -> BaiduHTTPResponse {
    BaiduHTTPResponse(statusCode: statusCode, headers: [:], body: body)
  }

  private func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  private func jsonString(_ values: [String]) throws -> String {
    let data = try JSONEncoder().encode(values)
    return try #require(String(data: data, encoding: .utf8))
  }

  private func queryItems(_ request: URLRequest) throws -> [String: String] {
    let url = try #require(request.url)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = try #require(components.queryItems)
    return Dictionary(
      uniqueKeysWithValues: items.compactMap { item in
        item.value.map { (item.name, $0) }
      })
  }

  private func formItems(_ request: URLRequest) throws -> [String: String] {
    let body = try #require(request.httpBody)
    let bodyString = try #require(String(data: body, encoding: .utf8))
    let components = try #require(URLComponents(string: "https://example.invalid/?\(bodyString)"))
    let items = try #require(components.queryItems)
    return Dictionary(
      uniqueKeysWithValues: items.compactMap { item in
        item.value.map { (item.name, $0) }
      })
  }

  private func multipartPayload(_ request: URLRequest) throws -> Data {
    let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
    let boundary = try #require(contentType.components(separatedBy: "boundary=").last)
    let body = try #require(request.httpBody)
    let headerTerminator = Data("\r\n\r\n".utf8)
    let trailer = Data("\r\n--\(boundary)--\r\n".utf8)
    let headerRange = try #require(body.range(of: headerTerminator))
    let trailerRange = try #require(body.range(of: trailer, options: .backwards))
    return body.subdata(in: headerRange.upperBound..<trailerRange.lowerBound)
  }
}

private enum BaiduUploaderTestError: Error {
  case couldNotCreateExactArchive
}

private actor BaiduProgressRecorder {
  private var recorded: [BaiduBackupUploadProgress] = []

  func append(_ progress: BaiduBackupUploadProgress) {
    recorded.append(progress)
  }

  func values() -> [BaiduBackupUploadProgress] {
    recorded
  }
}
