import Foundation
import Testing

@testable import InkNotesCore

@Suite("Baidu remote backup metadata observation")
struct BaiduRemoteBackupMetadataObserverTests {
  private let backupID = UUID(uuidString: "B7000000-0000-0000-0000-000000000001")!

  @Test("An unavailable credential stops before the first metadata request")
  func unavailableCredentialSendsNoMetadataRequest() async throws {
    let record = try reconciliationRecord()
    let now = Date(timeIntervalSinceReferenceDate: 3_000_000)
    let transport = ScriptedBaiduHTTPTransport(handlers: [])
    let clock = CredentialTestClock([now])
    let observer = BaiduRemoteBackupMetadataObserver(
      transport: transport,
      now: clock.now
    )
    let credential = try credential(
      scope: record.accountScope,
      expiresAt: now.addingTimeInterval(
        BaiduCredentialUsePolicy.minimumRequestRemainingLifetime
      )
    )

    await #expect(
      throws: BaiduRemoteBackupMetadataObservationError.credential(
        .unavailableForRequest
      )
    ) {
      try await observer.observe(record: record, credential: credential)
    }
    #expect(await transport.requestCount() == 0)
  }

  @Test("Credential expiry between listing pages prevents the next request")
  func credentialIsRecheckedBeforeEveryListingPage() async throws {
    let record = try reconciliationRecord()
    let now = Date(timeIntervalSinceReferenceDate: 3_100_000)
    let fullPage = (0..<BaiduRemoteBackupMetadataObserver.pageSize).map { index in
      Self.entry(
        path: "/apps/测试应用/expiry-\(index)",
        fsID: UInt64(index + 1),
        size: 7,
        md5: String(repeating: "c", count: 32)
      )
    }
    let fullResponse = try Self.page(entries: fullPage)
    let transport = ScriptedBaiduHTTPTransport(handlers: [
      { _ in fullResponse }
    ])
    let clock = CredentialTestClock([now, now.addingTimeInterval(61)])
    let observer = BaiduRemoteBackupMetadataObserver(
      transport: transport,
      now: clock.now
    )
    let credential = try credential(
      scope: record.accountScope,
      expiresAt: now.addingTimeInterval(
        BaiduCredentialUsePolicy.minimumRequestRemainingLifetime + 60
      )
    )

    await #expect(
      throws: BaiduRemoteBackupMetadataObservationError.credential(
        .unavailableForRequest
      )
    ) {
      try await observer.observe(record: record, credential: credential)
    }
    #expect(await transport.requestCount() == 1)
  }

  @Test("A same-account exact metadata match remains explicitly content-unproven")
  func exactMatchRemainsContentUnproven() async throws {
    let record = try reconciliationRecord()
    let secret = "metadata.secret-token+value%25"
    let transport = ScriptedBaiduHTTPTransport(handlers: [
      { request in
        let query = try Self.queryItems(request)
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.url?.scheme == "https")
        #expect(request.url?.host == "pan.baidu.com")
        #expect(request.url?.path == "/rest/2.0/xpan/file")
        let requestURL = try #require(request.url)
        let requestComponents = try #require(
          URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
        )
        let percentEncodedQuery = try #require(requestComponents.percentEncodedQuery)
        #expect(
          percentEncodedQuery.contains(
            "dir=%2Fapps%2F%E6%B5%8B%E8%AF%95%E5%BA%94%E7%94%A8"
          )
        )
        #expect(
          percentEncodedQuery.contains(
            "access_token=metadata.secret-token%2Bvalue%2525"
          )
        )
        #expect(!percentEncodedQuery.contains(secret))
        #expect(query["method"] == "list")
        #expect(query["dir"] == "/apps/测试应用")
        #expect(query["order"] == "name")
        #expect(query["desc"] == "0")
        #expect(query["start"] == "0")
        #expect(query["limit"] == "100")
        #expect(query["folder"] == "0")
        #expect(query["access_token"] == secret)
        #expect(
          Set(query.keys)
            == Set([
              "method", "dir", "order", "desc", "start", "limit", "folder",
              "access_token",
            ])
        )
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "pan.baidu.com")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.httpShouldHandleCookies == false)
        return try Self.page(entries: [Self.entry(for: record)])
      }
    ])
    let observer = BaiduRemoteBackupMetadataObserver(transport: transport)

    let observation = try await observer.observe(
      record: record,
      credential: try credential(scope: record.accountScope, token: secret)
    )
    #expect(observation.accountScope == record.accountScope)
    #expect(observation.attemptID == record.attemptID)
    #expect(observation.backupID == record.backupID)
    guard case .exactMetadataMatchContentUnproven(let metadata) = observation.observation else {
      Issue.record("Expected a content-unproven metadata match")
      return
    }
    #expect(metadata.path == record.requestedPath)
    #expect(metadata.byteCount == record.localByteCount)
    #expect(metadata.cloudMD5 == record.localMD5)
    #expect(metadata.isDirectory == false)
    #expect(await transport.requestCount() == 1)

    let rendered = [
      String(describing: observation),
      String(reflecting: observation),
    ].joined(separator: " ")
    #expect(!rendered.contains(secret))
    #expect(!rendered.lowercased().contains("verified"))
  }

  @Test("Listing paginates by offset and only an exact absolute path matches")
  func paginatedExactPathMatching() async throws {
    let record = try reconciliationRecord()
    let firstPage = (0..<BaiduRemoteBackupMetadataObserver.pageSize).map { index in
      Self.entry(
        path: "/apps/other/\(index)-\(record.requestedPath.split(separator: "/").last!)",
        fsID: UInt64(index + 1),
        size: Int64(record.localByteCount),
        md5: record.localMD5
      )
    }
    let firstResponse = try Self.page(entries: firstPage)
    let secondResponse = try Self.page(entries: [Self.entry(for: record, fsID: 1_001)])
    let transport = ScriptedBaiduHTTPTransport(handlers: [
      { request in
        let query = try Self.queryItems(request)
        #expect(query["start"] == "0")
        return firstResponse
      },
      { request in
        let query = try Self.queryItems(request)
        #expect(query["start"] == "100")
        return secondResponse
      },
    ])

    let observation = try await BaiduRemoteBackupMetadataObserver(transport: transport)
      .observe(record: record, credential: try credential(scope: record.accountScope))
    #expect(observation.isContentUnprovenMatch)
    #expect(await transport.requestCount() == 2)
  }

  @Test("A single short listing may report not observed without proving absence")
  func notObservedAfterCompleteListing() async throws {
    let record = try reconciliationRecord()
    let transport = ScriptedBaiduHTTPTransport(handlers: [
      { _ in
        try Self.page(entries: [
          Self.entry(
            path: record.requestedPath + ".copy",
            fsID: 2,
            size: Int64(record.localByteCount),
            md5: record.localMD5
          )
        ])
      }
    ])

    let observation = try await BaiduRemoteBackupMetadataObserver(transport: transport)
      .observe(record: record, credential: try credential(scope: record.accountScope))
    expectIdentity(observation, for: record)
    #expect(observation.observation == .notObservedAbsenceUnproven)
  }

  @Test("A multi-page miss stays indeterminate because offset listing is not a snapshot")
  func fullPageThenEmptyPageIsComplete() async throws {
    let record = try reconciliationRecord()
    let entries = (0..<BaiduRemoteBackupMetadataObserver.pageSize).map { index in
      Self.entry(
        path: "/apps/测试应用/complete-\(index)",
        fsID: UInt64(index + 1),
        size: 7,
        md5: String(repeating: "d", count: 32)
      )
    }
    let fullResponse = try Self.page(entries: entries)
    let emptyResponse = try Self.page(entries: [])
    let transport = ScriptedBaiduHTTPTransport(handlers: [
      { _ in fullResponse },
      { request in
        let query = try Self.queryItems(request)
        #expect(query["start"] == "100")
        return emptyResponse
      },
    ])

    let observation = try await BaiduRemoteBackupMetadataObserver(transport: transport)
      .observe(record: record, credential: credential(scope: record.accountScope))
    expectIdentity(observation, for: record)
    #expect(observation.observation == .indeterminate(.multiPageAbsenceUnproven))
    #expect(await transport.requestCount() == 2)
  }

  @Test("Canonically equivalent Unicode paths do not satisfy byte-exact matching")
  func unicodePathMatchingUsesExactUTF8() async throws {
    let record = try reconciliationRecord(folderName: "é")
    let decomposedPath = record.requestedPath.replacingOccurrences(
      of: "é",
      with: "e\u{301}"
    )
    #expect(decomposedPath == record.requestedPath)
    #expect(Data(decomposedPath.utf8) != Data(record.requestedPath.utf8))
    let response = try Self.page(entries: [
      Self.entry(
        path: decomposedPath,
        fsID: 7,
        size: Int64(record.localByteCount),
        md5: record.localMD5
      )
    ])
    let transport = ScriptedBaiduHTTPTransport(handlers: [{ _ in response }])

    let observation = try await BaiduRemoteBackupMetadataObserver(transport: transport)
      .observe(record: record, credential: credential(scope: record.accountScope))
    #expect(observation.observation == .notObservedAbsenceUnproven)
  }

  @Test("Size, cloud hash, filename, and directory mismatches never prove content")
  func metadataMismatches() async throws {
    let record = try reconciliationRecord()
    let variants: [[String: Any]] = [
      Self.entry(for: record, size: Int64(record.localByteCount) + 1),
      Self.entry(for: record, md5: String(repeating: "c", count: 32)),
      Self.entry(for: record, serverFilename: "wrong.notesbackup"),
      Self.entry(for: record, md5: "", isdir: 1),
    ]

    for variant in variants {
      let response = try Self.page(entries: [variant])
      let transport = ScriptedBaiduHTTPTransport(
        handlers: [{ _ in response }]
      )
      let observation = try await BaiduRemoteBackupMetadataObserver(transport: transport)
        .observe(record: record, credential: try credential(scope: record.accountScope))
      expectIdentity(observation, for: record)
      guard case .metadataMismatch = observation.observation else {
        Issue.record("Expected a metadata mismatch")
        continue
      }
    }
  }

  @Test("Repeated non-target listing entries are indeterminate")
  func repeatedListingEntriesAreIndeterminate() async throws {
    let record = try reconciliationRecord()
    let repeated = Self.entry(
      path: "/apps/测试应用/repeated.notesbackup",
      fsID: 1_000,
      size: 7,
      md5: String(repeating: "d", count: 32)
    )
    var firstPage = (0..<BaiduRemoteBackupMetadataObserver.pageSize).map { index in
      Self.entry(
        path: "/apps/测试应用/unrelated-\(index)",
        fsID: UInt64(index + 1),
        size: 7,
        md5: String(repeating: "d", count: 32)
      )
    }
    firstPage[0] = repeated
    let firstResponse = try Self.page(entries: firstPage)
    let secondResponse = try Self.page(entries: [repeated])
    let transport = ScriptedBaiduHTTPTransport(handlers: [
      { _ in firstResponse },
      { _ in secondResponse },
    ])

    let observation = try await BaiduRemoteBackupMetadataObserver(transport: transport)
      .observe(record: record, credential: credential(scope: record.accountScope))
    #expect(observation.observation == .indeterminate(.repeatedListingEntry))
    #expect(await transport.requestCount() == 2)
  }

  @Test("A file identifier that changes path across pages makes the scan indeterminate")
  func fileIdentifierRenameIsIndeterminate() async throws {
    let record = try reconciliationRecord()
    var firstPage = (0..<BaiduRemoteBackupMetadataObserver.pageSize).map { index in
      Self.entry(
        path: "/apps/测试应用/original-\(index)",
        fsID: UInt64(index + 1),
        size: 7,
        md5: String(repeating: "d", count: 32)
      )
    }
    firstPage[0] = Self.entry(
      path: "/apps/测试应用/original-name",
      fsID: 1_000,
      size: 7,
      md5: String(repeating: "d", count: 32)
    )
    let firstResponse = try Self.page(entries: firstPage)
    let renamedResponse = try Self.page(entries: [
      Self.entry(
        path: "/apps/测试应用/renamed",
        fsID: 1_000,
        size: 7,
        md5: String(repeating: "d", count: 32)
      )
    ])
    let transport = ScriptedBaiduHTTPTransport(handlers: [
      { _ in firstResponse },
      { _ in renamedResponse },
    ])

    let result = try await BaiduRemoteBackupMetadataObserver(transport: transport)
      .observe(record: record, credential: credential(scope: record.accountScope))
    #expect(result.observation == .indeterminate(.listingChangedDuringPagination))
  }

  @Test("Duplicate exact paths are indeterminate and never collapse into a match")
  func duplicateExactPathsAreIndeterminate() async throws {
    let record = try reconciliationRecord()
    let transport = ScriptedBaiduHTTPTransport(handlers: [
      { _ in
        try Self.page(entries: [
          Self.entry(for: record, fsID: 10),
          Self.entry(for: record, fsID: 11),
        ])
      }
    ])

    let observation = try await BaiduRemoteBackupMetadataObserver(transport: transport)
      .observe(record: record, credential: try credential(scope: record.accountScope))
    #expect(observation.observation == .indeterminate(.duplicateExactPath))
  }

  @Test("An exact path repeated on a later page is indeterminate")
  func crossPageDuplicateExactPathIsIndeterminate() async throws {
    let record = try reconciliationRecord()
    var firstPage = (0..<BaiduRemoteBackupMetadataObserver.pageSize).map { index in
      Self.entry(
        path: "/apps/测试应用/non-target-\(index)",
        fsID: UInt64(index + 1),
        size: 7,
        md5: String(repeating: "d", count: 32)
      )
    }
    firstPage[0] = Self.entry(for: record, fsID: 1_000)
    let firstResponse = try Self.page(entries: firstPage)
    let duplicateResponse = try Self.page(entries: [Self.entry(for: record, fsID: 1_001)])
    let transport = ScriptedBaiduHTTPTransport(handlers: [
      { _ in firstResponse },
      { _ in duplicateResponse },
    ])

    let result = try await BaiduRemoteBackupMetadataObserver(transport: transport)
      .observe(record: record, credential: credential(scope: record.accountScope))
    #expect(result.observation == .indeterminate(.duplicateExactPath))
  }

  @Test("A full final scan page stops at the hard pagination ceiling")
  func paginationCeilingIsIndeterminate() async throws {
    let record = try reconciliationRecord()
    let transport = FullMetadataPageTransport(pageSize: BaiduRemoteBackupMetadataObserver.pageSize)
    let observation = try await BaiduRemoteBackupMetadataObserver(transport: transport)
      .observe(record: record, credential: try credential(scope: record.accountScope))

    #expect(
      observation.observation
        == .indeterminate(
          .paginationLimitReached(
            maximumEntries: BaiduRemoteBackupMetadataObserver.pageSize
              * BaiduRemoteBackupMetadataObserver.maximumPageCount
          )
        )
    )
    #expect(
      await transport.requestCount()
        == BaiduRemoteBackupMetadataObserver.maximumPageCount
    )
  }

  @Test("An account mismatch and an invalid record fail before network access")
  func localAdmissionFailuresMakeNoRequest() async throws {
    let record = try reconciliationRecord()
    let transport = ScriptedBaiduHTTPTransport(handlers: [])
    let observer = BaiduRemoteBackupMetadataObserver(transport: transport)
    let otherScope = try BaiduAccountScope(
      brokerBindingID: UUID(uuidString: "B7000000-0000-0000-0000-000000000099")!
    )

    await #expect(
      throws: BaiduRemoteBackupMetadataObservationError.accountScopeMismatch
    ) {
      try await observer.observe(
        record: record,
        credential: self.credential(scope: otherScope)
      )
    }

    let invalid = BaiduUploadReconciliationRecord(
      accountScope: record.accountScope,
      attemptID: record.attemptID,
      backupID: record.backupID,
      archiveSHA256: record.archiveSHA256,
      localMD5: record.localMD5,
      localByteCount: record.localByteCount,
      requestedPath: record.requestedPath + "/escape"
    )
    await #expect(throws: BaiduRemoteBackupMetadataObservationError.invalidRecord) {
      try await observer.observe(
        record: invalid,
        credential: self.credential(scope: invalid.accountScope)
      )
    }
    #expect(await transport.requestCount() == 0)
  }

  @Test("HTTP, API, transport, response-size, and malformed failures stay distinct")
  func failuresRemainFailClosed() async throws {
    let record = try reconciliationRecord()
    let cases:
      [(@Sendable () async throws -> BaiduHTTPResponse, BaiduRemoteBackupMetadataObservationError)] =
        [
          ({ Self.response(statusCode: 201, body: #"{"errno":0,"list":[]}"#) }, .httpStatus(201)),
          ({ Self.response(statusCode: 202, body: #"{"errno":0,"list":[]}"#) }, .httpStatus(202)),
          ({ Self.response(statusCode: 204, body: #"{"errno":0,"list":[]}"#) }, .httpStatus(204)),
          ({ Self.response(statusCode: 206, body: #"{"errno":0,"list":[]}"#) }, .httpStatus(206)),
          ({ Self.response(statusCode: 503, body: #"{"errno":0,"list":[]}"#) }, .httpStatus(503)),
          ({ Self.response(body: #"{"errno":31034,"list":[]}"#) }, .api(31_034)),
          ({ Self.response(body: #"{"list":[]}"#) }, .malformedResponse),
          ({ Self.response(body: #"{"error_code":0,"list":[]}"#) }, .malformedResponse),
          ({ Self.response(body: #"{"errno":0}"#) }, .malformedResponse),
          ({ Self.response(body: #"{"errno":0,"list":[{}]}"#) }, .malformedResponse),
          (
            { Self.response(body: #"{"errno":0,"list":[{"fs_id":18446744073709551616}]}"#) },
            .malformedResponse
          ),
        ]

    for (response, expectedError) in cases {
      let transport = ScriptedBaiduHTTPTransport(handlers: [{ _ in try await response() }])
      await #expect(throws: expectedError) {
        try await BaiduRemoteBackupMetadataObserver(transport: transport)
          .observe(record: record, credential: self.credential(scope: record.accountScope))
      }
    }

    let oversized = Data(
      repeating: 0x41,
      count: BaiduRemoteBackupMetadataObserver.maximumJSONResponseByteCount + 1
    )
    let oversizedTransport = ScriptedBaiduHTTPTransport(
      handlers: [{ _ in Self.response(data: oversized) }]
    )
    await #expect(
      throws: BaiduRemoteBackupMetadataObservationError.responseTooLarge(
        maximum: BaiduRemoteBackupMetadataObserver.maximumJSONResponseByteCount
      )
    ) {
      try await BaiduRemoteBackupMetadataObserver(transport: oversizedTransport)
        .observe(record: record, credential: self.credential(scope: record.accountScope))
    }

    var boundaryBody = Data(#"{"errno":0,"list":[]}"#.utf8)
    boundaryBody.append(
      Data(
        repeating: 0x20,
        count: BaiduRemoteBackupMetadataObserver.maximumJSONResponseByteCount
          - boundaryBody.count
      )
    )
    let boundaryResponse = Self.response(data: boundaryBody)
    let boundaryTransport = ScriptedBaiduHTTPTransport(
      handlers: [{ _ in boundaryResponse }]
    )
    let boundaryObservation = try await BaiduRemoteBackupMetadataObserver(
      transport: boundaryTransport
    ).observe(record: record, credential: credential(scope: record.accountScope))
    #expect(boundaryObservation.observation == .notObservedAbsenceUnproven)

    let mappedTransport = ScriptedBaiduHTTPTransport(
      handlers: [{ _ in throw BaiduHTTPTransportError.invalidResponse }]
    )
    await #expect(
      throws: BaiduRemoteBackupMetadataObservationError.invalidHTTPResponse
    ) {
      try await BaiduRemoteBackupMetadataObserver(transport: mappedTransport)
        .observe(record: record, credential: self.credential(scope: record.accountScope))
    }

    let transportLimit = BaiduRemoteBackupMetadataObserver.maximumJSONResponseByteCount
    let transportOversized = ScriptedBaiduHTTPTransport(
      handlers: [{ _ in throw BaiduHTTPTransportError.responseTooLarge(maximum: transportLimit) }]
    )
    await #expect(
      throws: BaiduRemoteBackupMetadataObservationError.responseTooLarge(
        maximum: transportLimit
      )
    ) {
      try await BaiduRemoteBackupMetadataObserver(transport: transportOversized)
        .observe(record: record, credential: self.credential(scope: record.accountScope))
    }

    let secret = "metadata.transport-secret"
    let secretTransport = ScriptedBaiduHTTPTransport(
      handlers: [{ _ in throw MetadataObserverTestError.secret(secret) }]
    )
    do {
      _ = try await BaiduRemoteBackupMetadataObserver(transport: secretTransport)
        .observe(record: record, credential: credential(scope: record.accountScope))
      Issue.record("Expected a normalized transport failure")
    } catch {
      #expect(error as? BaiduRemoteBackupMetadataObservationError == .transport)
      let rendered = [
        String(describing: error),
        String(reflecting: error),
        error.localizedDescription,
      ].joined(separator: " ")
      #expect(!rendered.contains(secret))
    }
  }

  @Test("Cancellation propagates and a pre-cancelled task sends no request")
  func cancellationPropagation() async throws {
    let record = try reconciliationRecord()
    let cancelledTransport = ScriptedBaiduHTTPTransport(
      handlers: [{ _ in throw URLError(.cancelled) }]
    )
    await #expect(throws: CancellationError.self) {
      try await BaiduRemoteBackupMetadataObserver(transport: cancelledTransport)
        .observe(record: record, credential: self.credential(scope: record.accountScope))
    }

    let gate = MetadataObserverStartGate()
    let untouchedTransport = ScriptedBaiduHTTPTransport(handlers: [])
    let observer = BaiduRemoteBackupMetadataObserver(transport: untouchedTransport)
    let credential = try credential(scope: record.accountScope)
    let task = Task {
      await gate.waitUntilOpened()
      return try await observer.observe(record: record, credential: credential)
    }
    task.cancel()
    await gate.open()
    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    #expect(await untouchedTransport.requestCount() == 0)
  }

  @Test("Target entries require bounded, typed metadata while unrelated details may be absent")
  func targetMetadataValidation() async throws {
    let record = try reconciliationRecord()
    let unrelated: [String: Any] = [
      "fs_id": 99,
      "path": "/apps/测试应用/unrelated",
    ]
    let unrelatedResponse = try Self.page(entries: [unrelated])
    let acceptableTransport = ScriptedBaiduHTTPTransport(
      handlers: [{ _ in unrelatedResponse }]
    )
    let notObserved = try await BaiduRemoteBackupMetadataObserver(
      transport: acceptableTransport
    ).observe(record: record, credential: credential(scope: record.accountScope))
    #expect(notObserved.observation == .notObservedAbsenceUnproven)

    let highFSID = UInt64(Int64.max) + 1
    let highFSIDResponse = try Self.page(entries: [
      Self.entry(for: record, fsID: highFSID)
    ])
    let highFSIDTransport = ScriptedBaiduHTTPTransport(
      handlers: [{ _ in highFSIDResponse }]
    )
    let highFSIDObservation = try await BaiduRemoteBackupMetadataObserver(
      transport: highFSIDTransport
    ).observe(record: record, credential: credential(scope: record.accountScope))
    guard
      case .exactMetadataMatchContentUnproven(let metadata) =
        highFSIDObservation.observation
    else {
      Issue.record("Expected a high unsigned file identifier to remain valid")
      return
    }
    #expect(metadata.fsID == highFSID)

    var malformedTarget = Self.entry(for: record)
    malformedTarget["md5"] = "NOT-A-CLOUD-HASH"
    let malformedResponse = try Self.page(entries: [malformedTarget])
    let malformedTransport = ScriptedBaiduHTTPTransport(
      handlers: [{ _ in malformedResponse }]
    )
    await #expect(throws: BaiduRemoteBackupMetadataObservationError.malformedResponse) {
      try await BaiduRemoteBackupMetadataObserver(transport: malformedTransport)
        .observe(record: record, credential: self.credential(scope: record.accountScope))
    }

    var invalidEntries: [[String: Any]] = []
    for (key, value) in [
      ("fs_id", 0),
      ("fs_id", -1),
      ("size", -1),
      ("isdir", 2),
    ] {
      var entry = Self.entry(for: record)
      entry[key] = value
      invalidEntries.append(entry)
    }
    var uppercaseMD5 = Self.entry(for: record)
    uppercaseMD5["md5"] = String(repeating: "A", count: 32)
    invalidEntries.append(uppercaseMD5)
    var missingFSID = Self.entry(for: record)
    missingFSID.removeValue(forKey: "fs_id")
    invalidEntries.append(missingFSID)

    for entry in invalidEntries {
      let response = try Self.page(entries: [entry])
      let transport = ScriptedBaiduHTTPTransport(handlers: [{ _ in response }])
      await #expect(throws: BaiduRemoteBackupMetadataObservationError.malformedResponse) {
        try await BaiduRemoteBackupMetadataObserver(transport: transport)
          .observe(record: record, credential: self.credential(scope: record.accountScope))
      }
    }

    let excessiveEntries = (0...BaiduRemoteBackupMetadataObserver.pageSize).map { index in
      ["path": "/apps/测试应用/excess-\(index)"]
    }
    let excessiveResponse = try Self.page(entries: excessiveEntries)
    let excessiveTransport = ScriptedBaiduHTTPTransport(
      handlers: [{ _ in excessiveResponse }]
    )
    await #expect(throws: BaiduRemoteBackupMetadataObservationError.malformedResponse) {
      try await BaiduRemoteBackupMetadataObserver(transport: excessiveTransport)
        .observe(record: record, credential: self.credential(scope: record.accountScope))
    }
  }

  @Test("Every observation leaves the reconciliation WAL byte-for-byte unchanged")
  func observationsNeverMutateWAL() async throws {
    let record = try reconciliationRecord()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "InkNotesMetadataObserver-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = BaiduUploadReconciliationRepository(rootURL: root)
    let admission = try await repository.admit(record)
    let lease = try #require(admission.createdLease)
    lease.release()
    let recordURL =
      root
      .appendingPathComponent(
        BaiduUploadReconciliationRepository.reconciliationDirectoryName,
        isDirectory: true
      )
      .appendingPathComponent(
        BaiduUploadReconciliationRepository.recordFilename(
          accountScope: record.accountScope,
          backupID: record.backupID
        )
      )
    let originalData = try Data(contentsOf: recordURL)
    let reconciliationDirectoryURL = recordURL.deletingLastPathComponent()
    let originalDirectoryEntries = try FileManager.default.contentsOfDirectory(
      atPath: reconciliationDirectoryURL.path
    ).sorted()
    let originalAttributes = try FileManager.default.attributesOfItem(
      atPath: recordURL.path
    )
    let originalSystemNumber = try #require(
      originalAttributes[.systemNumber] as? NSNumber
    )
    let originalFileNumber = try #require(
      originalAttributes[.systemFileNumber] as? NSNumber
    )

    func expectWALUnchanged() async throws {
      #expect(try Data(contentsOf: recordURL) == originalData)
      #expect(
        try FileManager.default.contentsOfDirectory(
          atPath: reconciliationDirectoryURL.path
        ).sorted() == originalDirectoryEntries
      )
      let attributes = try FileManager.default.attributesOfItem(atPath: recordURL.path)
      #expect(try #require(attributes[.systemNumber] as? NSNumber) == originalSystemNumber)
      #expect(try #require(attributes[.systemFileNumber] as? NSNumber) == originalFileNumber)
      #expect(
        try await repository.load(
          accountScope: record.accountScope,
          backupID: record.backupID
        ) == record
      )
    }

    let responses = try [
      Self.page(entries: [Self.entry(for: record)]),
      Self.page(entries: [
        Self.entry(for: record, size: Int64(record.localByteCount) + 1)
      ]),
      Self.page(entries: []),
      Self.page(entries: [
        Self.entry(for: record, fsID: 10),
        Self.entry(for: record, fsID: 11),
      ]),
    ]
    for response in responses {
      let transport = ScriptedBaiduHTTPTransport(handlers: [{ _ in response }])
      _ = try await BaiduRemoteBackupMetadataObserver(transport: transport)
        .observe(record: record, credential: credential(scope: record.accountScope))
      try await expectWALUnchanged()
    }

    let errorResponse = Self.response(body: #"{"errno":31034,"list":[]}"#)
    let errorTransport = ScriptedBaiduHTTPTransport(handlers: [{ _ in errorResponse }])
    await #expect(throws: BaiduRemoteBackupMetadataObservationError.api(31_034)) {
      try await BaiduRemoteBackupMetadataObserver(transport: errorTransport)
        .observe(record: record, credential: self.credential(scope: record.accountScope))
    }
    try await expectWALUnchanged()

    let malformedTransport = ScriptedBaiduHTTPTransport(
      handlers: [{ _ in Self.response(body: #"{"errno":0}"#) }]
    )
    await #expect(throws: BaiduRemoteBackupMetadataObservationError.malformedResponse) {
      try await BaiduRemoteBackupMetadataObserver(transport: malformedTransport)
        .observe(record: record, credential: self.credential(scope: record.accountScope))
    }
    try await expectWALUnchanged()

    let failedTransport = ScriptedBaiduHTTPTransport(
      handlers: [{ _ in throw BaiduHTTPTransportError.unavailable }]
    )
    await #expect(throws: BaiduRemoteBackupMetadataObservationError.transport) {
      try await BaiduRemoteBackupMetadataObserver(transport: failedTransport)
        .observe(record: record, credential: self.credential(scope: record.accountScope))
    }
    try await expectWALUnchanged()

    let cancelledTransport = ScriptedBaiduHTTPTransport(
      handlers: [{ _ in throw CancellationError() }]
    )
    await #expect(throws: CancellationError.self) {
      try await BaiduRemoteBackupMetadataObserver(transport: cancelledTransport)
        .observe(record: record, credential: self.credential(scope: record.accountScope))
    }
    try await expectWALUnchanged()
  }

  private func expectIdentity(
    _ result: BaiduRemoteBackupMetadataObservationResult,
    for record: BaiduUploadReconciliationRecord
  ) {
    #expect(result.accountScope == record.accountScope)
    #expect(result.attemptID == record.attemptID)
    #expect(result.backupID == record.backupID)
  }

  private func reconciliationRecord(
    folderName: String = "测试应用"
  ) throws -> BaiduUploadReconciliationRecord {
    let scope = try BaiduAccountScope(
      brokerBindingID: UUID(uuidString: "B7000000-0000-0000-0000-000000000010")!
    )
    let directory = try BaiduNetdiskAppDirectory(folderName: folderName)
    return BaiduUploadReconciliationRecord(
      accountScope: scope,
      attemptID: UUID(uuidString: "B7000000-0000-0000-0000-000000000020")!,
      backupID: backupID,
      archiveSHA256: String(repeating: "a", count: 64),
      localMD5: String(repeating: "b", count: 32),
      localByteCount: 2_048,
      requestedPath: directory.backupPath(backupID: backupID)
    )
  }

  private func credential(
    scope: BaiduAccountScope,
    token: String = "metadata.test-token",
    expiresAt: Date = .distantFuture
  ) throws -> BaiduAccountBoundCredential {
    try BaiduAccountBoundCredential.testingOnly(
      accountScope: scope,
      accessToken: BaiduAccessToken(token),
      expiresAt: expiresAt
    )
  }

  private static func entry(
    for record: BaiduUploadReconciliationRecord,
    fsID: UInt64 = 1,
    size: Int64? = nil,
    md5: String? = nil,
    serverFilename: String? = nil,
    isdir: Int = 0
  ) -> [String: Any] {
    entry(
      path: record.requestedPath,
      fsID: fsID,
      size: size ?? Int64(record.localByteCount),
      md5: md5 ?? record.localMD5,
      serverFilename: serverFilename,
      isdir: isdir
    )
  }

  private static func entry(
    path: String,
    fsID: UInt64,
    size: Int64,
    md5: String,
    serverFilename: String? = nil,
    isdir: Int = 0
  ) -> [String: Any] {
    [
      "fs_id": fsID,
      "path": path,
      "server_filename": serverFilename ?? String(path.split(separator: "/").last ?? ""),
      "size": size,
      "isdir": isdir,
      "md5": md5,
    ]
  }

  private static func page(entries: [[String: Any]]) throws -> BaiduHTTPResponse {
    let body = try JSONSerialization.data(
      withJSONObject: ["errno": 0, "list": entries],
      options: [.sortedKeys]
    )
    return response(data: body)
  }

  private static func response(
    statusCode: Int = 200,
    body: String
  ) -> BaiduHTTPResponse {
    response(statusCode: statusCode, data: Data(body.utf8))
  }

  private static func response(
    statusCode: Int = 200,
    data: Data
  ) -> BaiduHTTPResponse {
    BaiduHTTPResponse(
      statusCode: statusCode,
      headers: ["content-type": "application/json"],
      body: data
    )
  }

  private static func queryItems(_ request: URLRequest) throws -> [String: String] {
    let url = try #require(request.url)
    let components = try #require(
      URLComponents(url: url, resolvingAgainstBaseURL: false)
    )
    let items = try #require(components.queryItems)
    return Dictionary(
      uniqueKeysWithValues: try items.map { item in
        (item.name, try #require(item.value))
      }
    )
  }
}

extension BaiduRemoteBackupMetadataObservationResult {
  fileprivate var isContentUnprovenMatch: Bool {
    if case .exactMetadataMatchContentUnproven = observation { return true }
    return false
  }
}

private enum MetadataObserverTestError: Error, Sendable {
  case secret(String)
}

private actor MetadataObserverStartGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func waitUntilOpened() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending {
      waiter.resume()
    }
  }
}

private actor FullMetadataPageTransport: BaiduHTTPTransport {
  private let pageSize: Int
  private var capturedRequestCount = 0

  init(pageSize: Int) {
    self.pageSize = pageSize
  }

  func send(_ request: URLRequest) async throws -> BaiduHTTPResponse {
    capturedRequestCount += 1
    let entries: [[String: Any]] = (0..<pageSize).map { index in
      [
        "fs_id": UInt64(capturedRequestCount * pageSize + index + 1),
        "path": "/apps/测试应用/unrelated-\(capturedRequestCount)-\(index)",
      ]
    }
    let body = try JSONSerialization.data(
      withJSONObject: ["errno": 0, "list": entries],
      options: [.sortedKeys]
    )
    return BaiduHTTPResponse(statusCode: 200, headers: [:], body: body)
  }

  func requestCount() -> Int {
    capturedRequestCount
  }
}
