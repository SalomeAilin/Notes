import CryptoKit
import Foundation
import Testing

@testable import InkNotesCore

@Suite("Baidu remote backup full-byte verification")
struct BaiduRemoteBackupContentVerifierTests {
  private let backupID = UUID(uuidString: "B8000000-0000-0000-0000-000000000001")!
  private let fsID: UInt64 = 8_001
  private let verificationChallenge = UUID(
    uuidString: "B8000000-0000-0000-0000-000000000003"
  )!

  @Test("An unavailable credential stops before metadata and download requests")
  func unavailableCredentialSendsNoVerificationRequest() async throws {
    let archive = Data(repeating: 0x31, count: 512)
    let record = try reconciliationRecord(archive: archive)
    let now = Date(timeIntervalSinceReferenceDate: 4_000_000)
    let metadataTransport = ScriptedBaiduHTTPTransport(handlers: [])
    let byteStreamer = ScriptedBaiduRemoteBackupByteStreamer(handlers: [])
    let clock = CredentialTestClock([now])
    let verifier = BaiduRemoteBackupContentVerifier(
      metadataTransport: metadataTransport,
      byteStreamer: byteStreamer,
      now: clock.now
    )
    let credential = try credential(
      scope: record.accountScope,
      expiresAt: now.addingTimeInterval(
        BaiduCredentialUsePolicy.minimumRequestRemainingLifetime
      )
    )

    await #expect(
      throws: BaiduRemoteBackupContentVerificationError.credential(
        .unavailableForRequest
      )
    ) {
      try await verifier.verify(
        record: record,
        fsID: fsID,
        verificationChallenge: verificationChallenge,
        credential: credential
      )
    }
    #expect(await metadataTransport.requestCount() == 0)
    #expect(await byteStreamer.requestCount() == 0)
  }

  @Test("Credential expiry after metadata prevents the download request")
  func credentialIsRecheckedBeforeDownload() async throws {
    let archive = Data(repeating: 0x32, count: 768)
    let record = try reconciliationRecord(archive: archive)
    let now = Date(timeIntervalSinceReferenceDate: 4_100_000)
    let metadataTransport = ScriptedBaiduHTTPTransport(handlers: [
      { _ in try Self.metadataResponse(record: record, fsID: 8_001) }
    ])
    let byteStreamer = ScriptedBaiduRemoteBackupByteStreamer(handlers: [])
    let clock = CredentialTestClock([now, now.addingTimeInterval(61)])
    let verifier = BaiduRemoteBackupContentVerifier(
      metadataTransport: metadataTransport,
      byteStreamer: byteStreamer,
      now: clock.now
    )
    let credential = try credential(
      scope: record.accountScope,
      expiresAt: now.addingTimeInterval(
        BaiduCredentialUsePolicy.minimumRequestRemainingLifetime + 60
      )
    )

    await #expect(
      throws: BaiduRemoteBackupContentVerificationError.credential(
        .unavailableForRequest
      )
    ) {
      try await verifier.verify(
        record: record,
        fsID: fsID,
        verificationChallenge: verificationChallenge,
        credential: credential
      )
    }
    #expect(await metadataTransport.requestCount() == 1)
    #expect(await byteStreamer.requestCount() == 0)
  }

  @Test("An exact full stream is the only successful content proof")
  func exactFullStreamIsVerified() async throws {
    let archive = Data((0..<4_097).map { UInt8($0 % 251) })
    let record = try reconciliationRecord(archive: archive)
    let secret = "verify.secret-token+value%25"
    let metadataTransport = ScriptedBaiduHTTPTransport(handlers: [
      { request in
        let query = try Self.queryItems(request)
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.url?.scheme == "https")
        #expect(request.url?.host == "pan.baidu.com")
        #expect(request.url?.path == "/rest/2.0/xpan/multimedia")
        #expect(query["method"] == "filemetas")
        #expect(query["fsids"] == "[8001]")
        #expect(query["dlink"] == "1")
        #expect(query["access_token"] == secret)
        #expect(Set(query.keys) == Set(["method", "fsids", "dlink", "access_token"]))
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "pan.baidu.com")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.httpShouldHandleCookies == false)
        return try Self.metadataResponse(
          record: record,
          fsID: 8_001,
          dlink: "https://d.pcs.baidu.com/file/full-proof?sign=signed%2Bvalue"
        )
      }
    ])
    let byteStreamer = ScriptedBaiduRemoteBackupByteStreamer(handlers: [
      { request, maximumByteCount in
        let query = try Self.queryItems(request)
        #expect(request.url?.scheme == "https")
        #expect(request.url?.host == "d.pcs.baidu.com")
        #expect(request.url?.path == "/file/full-proof")
        #expect(query["sign"] == "signed+value")
        #expect(query["access_token"] == secret)
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "pan.baidu.com")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(maximumByteCount == BackupArchiveLimits.maximumArchiveByteCount)
        return BaiduStreamedDownloadDigest(
          byteCount: UInt64(archive.count),
          sha256: Self.sha256Hex(archive)
        )
      }
    ])

    let result = try await BaiduRemoteBackupContentVerifier(
      metadataTransport: metadataTransport,
      byteStreamer: byteStreamer
    ).verify(
      record: record,
      fsID: fsID,
      verificationChallenge: verificationChallenge,
      credential: try credential(scope: record.accountScope, token: secret)
    )

    #expect(result.accountScope == record.accountScope)
    #expect(result.attemptID == record.attemptID)
    #expect(result.backupID == record.backupID)
    #expect(
      result.verification
        == .contentVerified(
          BaiduVerifiedRemoteBackupContentProof.testingOnly(
            record: record,
            fsID: fsID,
            byteCount: UInt64(archive.count),
            sha256: Self.sha256Hex(archive),
            verificationChallenge: verificationChallenge
          )
        )
    )
    #expect(await metadataTransport.requestCount() == 1)
    #expect(await byteStreamer.requestCount() == 1)
    let rendered = String(describing: result) + String(reflecting: result)
    #expect(!rendered.contains(secret))
    #expect(!rendered.contains("access_token"))
  }

  @Test("A metadata byte-count mismatch fails closed before download")
  func metadataSizeMismatchStopsBeforeDownload() async throws {
    let archive = Data(repeating: 0x41, count: 512)
    let record = try reconciliationRecord(archive: archive)
    let metadataTransport = ScriptedBaiduHTTPTransport(handlers: [
      { _ in
        try Self.metadataResponse(
          record: record,
          fsID: 8_001,
          size: UInt64(archive.count + 1)
        )
      }
    ])
    let byteStreamer = ScriptedBaiduRemoteBackupByteStreamer(handlers: [])

    let result = try await BaiduRemoteBackupContentVerifier(
      metadataTransport: metadataTransport,
      byteStreamer: byteStreamer
    ).verify(
      record: record,
      fsID: fsID,
      verificationChallenge: verificationChallenge,
      credential: try credential(scope: record.accountScope)
    )

    #expect(
      result.verification
        == .contentMismatch(
          .byteCount(
            expected: UInt64(archive.count),
            actual: UInt64(archive.count + 1)
          )
        )
    )
    #expect(await byteStreamer.requestCount() == 0)
  }

  @Test(
    "A streamed byte-count or digest mismatch never claims verification",
    arguments: [
      VerificationMismatch.size,
      VerificationMismatch.digest,
    ])
  func streamedMismatchFailsClosed(kind: VerificationMismatch) async throws {
    let archive = Data(repeating: 0x42, count: 768)
    let record = try reconciliationRecord(archive: archive)
    let metadataTransport = ScriptedBaiduHTTPTransport(handlers: [
      { _ in try Self.metadataResponse(record: record, fsID: 8_001) }
    ])
    let streamedDigest: BaiduStreamedDownloadDigest
    let expectedVerification: BaiduRemoteBackupContentVerification
    switch kind {
    case .size:
      streamedDigest = BaiduStreamedDownloadDigest(
        byteCount: UInt64(archive.count - 1),
        sha256: Self.sha256Hex(archive)
      )
      expectedVerification = .contentMismatch(
        .byteCount(expected: UInt64(archive.count), actual: UInt64(archive.count - 1))
      )
    case .digest:
      streamedDigest = BaiduStreamedDownloadDigest(
        byteCount: UInt64(archive.count),
        sha256: String(repeating: "f", count: 64)
      )
      expectedVerification = .contentMismatch(.sha256)
    }
    let byteStreamer = ScriptedBaiduRemoteBackupByteStreamer(handlers: [
      { _, _ in streamedDigest }
    ])

    let result = try await BaiduRemoteBackupContentVerifier(
      metadataTransport: metadataTransport,
      byteStreamer: byteStreamer
    ).verify(
      record: record,
      fsID: fsID,
      verificationChallenge: verificationChallenge,
      credential: try credential(scope: record.accountScope)
    )

    #expect(result.verification == expectedVerification)
    #expect(await byteStreamer.requestCount() == 1)
  }

  @Test(
    "The dlink must be HTTPS and cannot carry a second access token",
    arguments: [
      "http://d.pcs.baidu.com/file/unsafe",
      "https://example.invalid/file/token-recipient",
      "https://d.pcs.baidu.com:8443/file/nonstandard-port",
      "https://d.pcs.baidu.com/file/duplicate?access_token=server-value",
    ])
  func unsafeDLinkIsRejected(dlink: String) async throws {
    let archive = Data(repeating: 0x43, count: 512)
    let record = try reconciliationRecord(archive: archive)
    let metadataTransport = ScriptedBaiduHTTPTransport(handlers: [
      { _ in try Self.metadataResponse(record: record, fsID: 8_001, dlink: dlink) }
    ])
    let byteStreamer = ScriptedBaiduRemoteBackupByteStreamer(handlers: [])
    let verifier = BaiduRemoteBackupContentVerifier(
      metadataTransport: metadataTransport,
      byteStreamer: byteStreamer
    )

    await #expect(throws: BaiduRemoteBackupContentVerificationError.insecureDownloadURL) {
      try await verifier.verify(
        record: record,
        fsID: fsID,
        verificationChallenge: verificationChallenge,
        credential: self.credential(scope: record.accountScope)
      )
    }
    #expect(await byteStreamer.requestCount() == 0)
  }

  @Test("The filemetas response must bind fs_id, exact path, filename, and regular file")
  func metadataIdentityMustMatch() async throws {
    let archive = Data(repeating: 0x44, count: 512)
    let record = try reconciliationRecord(archive: archive)
    let metadataTransport = ScriptedBaiduHTTPTransport(handlers: [
      { _ in
        try Self.metadataResponse(
          record: record,
          fsID: 8_002,
          path: record.requestedPath + ".copy"
        )
      }
    ])
    let byteStreamer = ScriptedBaiduRemoteBackupByteStreamer(handlers: [])

    await #expect(
      throws: BaiduRemoteBackupContentVerificationError.malformedMetadataResponse
    ) {
      try await BaiduRemoteBackupContentVerifier(
        metadataTransport: metadataTransport,
        byteStreamer: byteStreamer
      ).verify(
        record: record,
        fsID: self.fsID,
        verificationChallenge: verificationChallenge,
        credential: self.credential(scope: record.accountScope)
      )
    }
    #expect(await byteStreamer.requestCount() == 0)
  }

  @Test("Filemetas requires the official filename field, not list server_filename")
  func filemetasUsesOfficialFilenameField() async throws {
    let archive = Data(repeating: 0x47, count: 512)
    let record = try reconciliationRecord(archive: archive)
    let metadataTransport = ScriptedBaiduHTTPTransport(handlers: [
      { _ in
        try Self.metadataResponse(
          record: record,
          fsID: 8_001,
          filenameKey: "server_filename"
        )
      }
    ])
    let byteStreamer = ScriptedBaiduRemoteBackupByteStreamer(handlers: [])

    await #expect(
      throws: BaiduRemoteBackupContentVerificationError.malformedMetadataResponse
    ) {
      try await BaiduRemoteBackupContentVerifier(
        metadataTransport: metadataTransport,
        byteStreamer: byteStreamer
      ).verify(
        record: record,
        fsID: self.fsID,
        verificationChallenge: verificationChallenge,
        credential: self.credential(scope: record.accountScope)
      )
    }
    #expect(await byteStreamer.requestCount() == 0)
  }

  @Test("Account mismatch and invalid fs_id dispatch no network request")
  func invalidIdentityDispatchesNothing() async throws {
    let archive = Data(repeating: 0x45, count: 512)
    let record = try reconciliationRecord(archive: archive)
    let otherScope = try BaiduAccountScope(
      brokerBindingID: UUID(uuidString: "B8000000-0000-0000-0000-000000000099")!
    )
    let metadataTransport = ScriptedBaiduHTTPTransport(handlers: [])
    let byteStreamer = ScriptedBaiduRemoteBackupByteStreamer(handlers: [])
    let verifier = BaiduRemoteBackupContentVerifier(
      metadataTransport: metadataTransport,
      byteStreamer: byteStreamer
    )

    await #expect(
      throws: BaiduRemoteBackupContentVerificationError.accountScopeMismatch
    ) {
      try await verifier.verify(
        record: record,
        fsID: self.fsID,
        verificationChallenge: verificationChallenge,
        credential: self.credential(scope: otherScope)
      )
    }
    await #expect(throws: BaiduRemoteBackupContentVerificationError.invalidFSID) {
      try await verifier.verify(
        record: record,
        fsID: 0,
        verificationChallenge: verificationChallenge,
        credential: self.credential(scope: record.accountScope)
      )
    }
    #expect(await metadataTransport.requestCount() == 0)
    #expect(await byteStreamer.requestCount() == 0)
  }

  @Test("Production byte streaming hashes incrementally and enforces the archive limit")
  func productionStreamerHashesAndLimits() async throws {
    let body = Data((0..<65_537).map { UInt8($0 % 239) })
    let successPath = "/proof-success-\(UUID().uuidString)"
    ControlledBaiduURLProtocol.register(
      .response(
        statusCode: 200,
        headers: ["Content-Length": String(body.count)],
        chunks: [Data(body.prefix(17)), Data(body.dropFirst(17))]
      ),
      path: successPath
    )
    let streamer = productionStreamer()
    let successRequest = try downloadRequest(path: successPath)
    let digest = try await streamer.streamSHA256(
      successRequest,
      maximumByteCount: body.count
    )
    #expect(
      digest
        == BaiduStreamedDownloadDigest(
          byteCount: UInt64(body.count),
          sha256: Self.sha256Hex(body)
        )
    )

    let oversizedPath = "/proof-oversized-\(UUID().uuidString)"
    ControlledBaiduURLProtocol.register(
      .response(
        statusCode: 200,
        headers: ["Content-Length": "129"],
        chunks: [Data(repeating: 0x41, count: 129)]
      ),
      path: oversizedPath
    )
    await #expect(throws: BaiduRemoteBackupByteStreamError.responseTooLarge(maximum: 128)) {
      try await streamer.streamSHA256(
        self.downloadRequest(path: oversizedPath),
        maximumByteCount: 128
      )
    }

    let unknownSizePath = "/proof-unknown-size-\(UUID().uuidString)"
    ControlledBaiduURLProtocol.register(
      .response(
        statusCode: 200,
        headers: [:],
        chunks: [Data(repeating: 0x42, count: 129)]
      ),
      path: unknownSizePath
    )
    await #expect(throws: BaiduRemoteBackupByteStreamError.responseTooLarge(maximum: 128)) {
      try await streamer.streamSHA256(
        self.downloadRequest(path: unknownSizePath),
        maximumByteCount: 128
      )
    }
  }

  @Test("Production byte streaming rejects a body shorter than its declared length")
  func productionStreamerRejectsTruncatedDeclaredBody() async throws {
    let path = "/proof-truncated-\(UUID().uuidString)"
    ControlledBaiduURLProtocol.register(
      .response(
        statusCode: 200,
        headers: ["Content-Length": "64"],
        chunks: [Data(repeating: 0x44, count: 63)]
      ),
      path: path
    )

    await #expect(throws: BaiduRemoteBackupByteStreamError.invalidResponse) {
      try await self.productionStreamer().streamSHA256(
        self.downloadRequest(path: path),
        maximumByteCount: 128
      )
    }
  }

  @Test("Cancelling production byte streaming stops URLSession work")
  func productionStreamerCancellationStopsURLSessionWork() async throws {
    let path = "/proof-hanging-\(UUID().uuidString)"
    ControlledBaiduURLProtocol.register(.hanging(statusCode: 200), path: path)
    let streamer = productionStreamer()
    let request = try downloadRequest(path: path)
    let task = Task {
      try await streamer.streamSHA256(request, maximumByteCount: 128)
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
      // Expected: URLSession cancellation remains task cancellation.
    }

    for _ in 0..<100 where ControlledBaiduURLProtocol.stopCount(path: path) == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(ControlledBaiduURLProtocol.stopCount(path: path) > 0)
  }

  @Test("Production byte streaming rejects encoded or partial response bodies")
  func productionStreamerRejectsTransformedOrPartialBodies() async throws {
    let encodedPath = "/proof-encoded-\(UUID().uuidString)"
    ControlledBaiduURLProtocol.register(
      .response(
        statusCode: 200,
        headers: ["Content-Encoding": "gzip"],
        chunks: [Data(repeating: 0x41, count: 32)]
      ),
      path: encodedPath
    )
    let streamer = productionStreamer()
    await #expect(throws: BaiduRemoteBackupByteStreamError.unsupportedContentEncoding) {
      try await streamer.streamSHA256(
        self.downloadRequest(path: encodedPath),
        maximumByteCount: 128
      )
    }

    let partialPath = "/proof-partial-\(UUID().uuidString)"
    ControlledBaiduURLProtocol.register(
      .response(
        statusCode: 206,
        headers: ["Content-Range": "bytes 0-31/64"],
        chunks: [Data(repeating: 0x42, count: 32)]
      ),
      path: partialPath
    )
    await #expect(throws: BaiduRemoteBackupByteStreamError.httpStatus(206)) {
      try await streamer.streamSHA256(
        self.downloadRequest(path: partialPath),
        maximumByteCount: 128
      )
    }

    let disguisedPartialPath = "/proof-disguised-partial-\(UUID().uuidString)"
    ControlledBaiduURLProtocol.register(
      .response(
        statusCode: 200,
        headers: ["Content-Range": "bytes 0-31/64"],
        chunks: [Data(repeating: 0x43, count: 32)]
      ),
      path: disguisedPartialPath
    )
    await #expect(throws: BaiduRemoteBackupByteStreamError.invalidResponse) {
      try await streamer.streamSHA256(
        self.downloadRequest(path: disguisedPartialPath),
        maximumByteCount: 128
      )
    }
  }

  @Test("Download redirects accept HTTPS only and strip credential-bearing headers")
  func redirectPolicyIsHTTPSOnly() throws {
    let source = try #require(URL(string: "https://d.pcs.baidu.com/source"))
    let response = try #require(
      HTTPURLResponse(
        url: source,
        statusCode: 302,
        httpVersion: "HTTP/1.1",
        headerFields: nil
      )
    )
    let session = URLSession(configuration: .ephemeral)
    let task = session.dataTask(with: source)
    let delegate = BaiduHTTPSOnlyRedirectDelegate()

    var insecureDecision: URLRequest??
    var insecureRequest = URLRequest(
      url: try #require(URL(string: "http://cdn.example.invalid/archive"))
    )
    insecureRequest.httpMethod = "GET"
    delegate.urlSession(
      session,
      task: task,
      willPerformHTTPRedirection: response,
      newRequest: insecureRequest
    ) { decision in
      insecureDecision = decision
    }
    #expect(insecureDecision != nil)
    #expect(insecureDecision! == nil)

    var tokenBearingDecision: URLRequest??
    var tokenBearingRequest = URLRequest(
      url: try #require(
        URL(string: "https://cdn.example.invalid/archive?access_token=must-not-follow")
      )
    )
    tokenBearingRequest.httpMethod = "GET"
    delegate.urlSession(
      session,
      task: task,
      willPerformHTTPRedirection: response,
      newRequest: tokenBearingRequest
    ) { decision in
      tokenBearingDecision = decision
    }
    #expect(tokenBearingDecision != nil)
    #expect(tokenBearingDecision! == nil)

    var secureDecision: URLRequest??
    var secureRequest = URLRequest(
      url: try #require(URL(string: "https://cdn.example.invalid/archive"))
    )
    secureRequest.httpMethod = "GET"
    secureRequest.setValue("Bearer should-not-follow", forHTTPHeaderField: "Authorization")
    secureRequest.setValue(
      "Basic should-not-follow",
      forHTTPHeaderField: "Proxy-Authorization"
    )
    secureRequest.setValue("session=should-not-follow", forHTTPHeaderField: "Cookie")
    secureRequest.setValue(
      "https://d.pcs.baidu.com/source?access_token=should-not-follow",
      forHTTPHeaderField: "Referer"
    )
    secureRequest.setValue(
      "https://d.pcs.baidu.com",
      forHTTPHeaderField: "Origin"
    )
    secureRequest.setValue("bytes=0-10", forHTTPHeaderField: "Range")
    delegate.urlSession(
      session,
      task: task,
      willPerformHTTPRedirection: response,
      newRequest: secureRequest
    ) { decision in
      secureDecision = decision
    }
    let redirected = try #require(secureDecision!)
    #expect(redirected.url?.scheme == "https")
    #expect(redirected.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(redirected.value(forHTTPHeaderField: "Proxy-Authorization") == nil)
    #expect(redirected.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(redirected.value(forHTTPHeaderField: "Referer") == nil)
    #expect(redirected.value(forHTTPHeaderField: "Origin") == nil)
    #expect(redirected.value(forHTTPHeaderField: "Range") == nil)
    #expect(redirected.value(forHTTPHeaderField: "User-Agent") == "pan.baidu.com")
    #expect(redirected.value(forHTTPHeaderField: "Cache-Control") == "no-store")
    #expect(redirected.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
    #expect(redirected.httpShouldHandleCookies == false)
  }

  @Test("Transport failures are redacted")
  func errorsDoNotRenderAccessToken() async throws {
    let archive = Data(repeating: 0x46, count: 512)
    let record = try reconciliationRecord(archive: archive)
    let secret = "never-render-this-secret"
    let metadataTransport = ScriptedBaiduHTTPTransport(handlers: [
      { _ in throw URLError(.notConnectedToInternet) }
    ])
    do {
      _ = try await BaiduRemoteBackupContentVerifier(
        metadataTransport: metadataTransport,
        byteStreamer: ScriptedBaiduRemoteBackupByteStreamer(handlers: [])
      ).verify(
        record: record,
        fsID: fsID,
        verificationChallenge: verificationChallenge,
        credential: try credential(scope: record.accountScope, token: secret)
      )
      Issue.record("Expected a redacted transport error")
    } catch let error as BaiduRemoteBackupContentVerificationError {
      let rendered = String(describing: error) + error.localizedDescription
      #expect(error == .metadataTransport)
      #expect(!rendered.contains(secret))
      #expect(!rendered.contains("access_token"))
    }
  }

  enum VerificationMismatch: Sendable {
    case size
    case digest
  }

  private func reconciliationRecord(
    archive: Data
  ) throws -> BaiduUploadReconciliationRecord {
    let scope = try BaiduAccountScope(
      brokerBindingID: UUID(uuidString: "B8000000-0000-0000-0000-000000000002")!
    )
    let directory = try BaiduNetdiskAppDirectory(folderName: "测试应用")
    return BaiduUploadReconciliationRecord(
      accountScope: scope,
      attemptID: UUID(uuidString: "B8000000-0000-0000-0000-000000000003")!,
      backupID: backupID,
      archiveSHA256: Self.sha256Hex(archive),
      localMD5: String(repeating: "a", count: 32),
      localByteCount: UInt64(archive.count),
      requestedPath: directory.backupPath(backupID: backupID)
    )
  }

  private func credential(
    scope: BaiduAccountScope,
    token: String = "test.short-lived-access-token",
    expiresAt: Date = .distantFuture
  ) throws -> BaiduAccountBoundCredential {
    try BaiduAccountBoundCredential.testingOnly(
      accountScope: scope,
      accessToken: BaiduAccessToken(token),
      expiresAt: expiresAt
    )
  }

  private func productionStreamer() -> URLSessionBaiduRemoteBackupByteStreamer {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ControlledBaiduURLProtocol.self]
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.httpShouldSetCookies = false
    return URLSessionBaiduRemoteBackupByteStreamer(
      session: URLSession(configuration: configuration)
    )
  }

  private func downloadRequest(path: String) throws -> URLRequest {
    var request = URLRequest(
      url: try #require(URL(string: "https://d.pcs.baidu.com\(path)")),
      cachePolicy: .reloadIgnoringLocalCacheData
    )
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent")
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    return request
  }

  private static func metadataResponse(
    record: BaiduUploadReconciliationRecord,
    fsID: UInt64,
    size: UInt64? = nil,
    path: String? = nil,
    filename: String? = nil,
    filenameKey: String = "filename",
    isDirectory: Int = 0,
    dlink: String = "https://d.pcs.baidu.com/file/archive?sign=signed"
  ) throws -> BaiduHTTPResponse {
    let file: [String: Any] = [
      "fs_id": fsID,
      "path": path ?? record.requestedPath,
      filenameKey: filename
        ?? BaiduNetdiskAppDirectory.backupFilename(backupID: record.backupID),
      "size": size ?? record.localByteCount,
      "isdir": isDirectory,
      "dlink": dlink,
    ]
    let object: [String: Any] = [
      "errno": 0,
      "list": [file],
    ]
    return BaiduHTTPResponse(
      statusCode: 200,
      headers: [:],
      body: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
  }

  private static func queryItems(_ request: URLRequest) throws -> [String: String] {
    let url = try #require(request.url)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    var values: [String: String] = [:]
    for item in components.queryItems ?? [] {
      guard values[item.name] == nil else {
        Issue.record("Duplicate query item \(item.name)")
        continue
      }
      values[item.name] = item.value
    }
    return values
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

actor ScriptedBaiduRemoteBackupByteStreamer: BaiduRemoteBackupByteStreaming {
  typealias Handler =
    @Sendable (URLRequest, Int) async throws
    -> BaiduStreamedDownloadDigest

  private var handlers: [Handler]
  private var capturedRequests: [URLRequest] = []

  init(handlers: [Handler]) {
    self.handlers = handlers
  }

  func streamSHA256(
    _ request: URLRequest,
    maximumByteCount: Int
  ) async throws -> BaiduStreamedDownloadDigest {
    capturedRequests.append(request)
    guard !handlers.isEmpty else {
      throw ScriptedBaiduHTTPTransportError.unexpectedRequest
    }
    let handler = handlers.removeFirst()
    return try await handler(request, maximumByteCount)
  }

  func requestCount() -> Int {
    capturedRequests.count
  }
}
