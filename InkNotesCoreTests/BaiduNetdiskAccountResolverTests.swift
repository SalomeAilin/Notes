import Foundation
import Testing

@testable import InkNotesCore

@Suite("Baidu Netdisk account identity probe")
struct BaiduNetdiskAccountResolverTests {
  @Test("UInfo request returns only a redacted positive account identity")
  func successfulIdentityResolution() async throws {
    let secret = "resolver.access-token+value%25"
    let transport = ScriptedBaiduHTTPTransport(
      handlers: [
        { request in
          let query = try Self.queryItems(request)
          #expect(request.httpMethod == "GET")
          #expect(request.httpBody == nil)
          #expect(request.url?.scheme == "https")
          #expect(request.url?.host == "pan.baidu.com")
          #expect(request.url?.path == "/rest/2.0/xpan/nas")
          #expect(query["method"] == "uinfo")
          #expect(query["vip_version"] == "v2")
          #expect(query["access_token"] == secret)
          #expect(Set(query.keys) == Set(["method", "vip_version", "access_token"]))
          #expect(request.value(forHTTPHeaderField: "User-Agent") == "pan.baidu.com")
          #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
          #expect(request.httpShouldHandleCookies == false)
          return Self.response(
            body:
              #"{"errno":0,"uk":7654321,"baidu_name":"private-name","netdisk_name":"private-disk","avatar_url":"https://private.invalid/avatar"}"#
          )
        }
      ]
    )
    let resolver = BaiduNetdiskAccountResolver(transport: transport)

    let identity = try await resolver.resolveAccountIdentity(
      accessToken: BaiduAccessToken(secret)
    )
    let expected = try #require(BaiduAccountIdentity(uk: 7_654_321))
    #expect(identity == expected)
    #expect(String(describing: identity) == "<redacted>")
    #expect(String(reflecting: identity) == "<redacted>")
    #expect(Array(Mirror(reflecting: identity).children).isEmpty)
    var dumpOutput = ""
    dump(identity, to: &dumpOutput)
    for forbidden in [secret, "7654321", "private-name", "private-disk", "private.invalid"] {
      #expect(!dumpOutput.contains(forbidden))
    }
    #expect(await transport.requestCount() == 1)
  }

  @Test("HTTP and API failures remain distinct and fail closed")
  func serviceFailures() async throws {
    let cases: [(BaiduHTTPResponse, BaiduNetdiskAccountResolutionError)] = [
      (Self.response(statusCode: 503, body: #"{"errno":0,"uk":1}"#), .httpStatus(503)),
      (Self.response(body: #"{"errno":31045,"uk":1}"#), .api(31_045)),
      (Self.response(body: #"{"uk":1}"#), .malformedResponse),
    ]

    for (serviceResponse, expectedError) in cases {
      let transport = ScriptedBaiduHTTPTransport(handlers: [{ _ in serviceResponse }])
      let resolver = BaiduNetdiskAccountResolver(transport: transport)
      await #expect(throws: expectedError) {
        try await resolver.resolveAccountIdentity(accessToken: self.accessToken())
      }
      #expect(await transport.requestCount() == 1)
    }
  }

  @Test("Missing, zero, and negative UK values never create an identity")
  func invalidAccountIdentities() async throws {
    let bodies = [
      #"{"errno":0}"#,
      #"{"errno":0,"uk":0}"#,
      #"{"errno":0,"uk":-1}"#,
    ]

    for body in bodies {
      let transport = ScriptedBaiduHTTPTransport(
        handlers: [{ _ in Self.response(body: body) }]
      )
      let resolver = BaiduNetdiskAccountResolver(transport: transport)
      await #expect(throws: BaiduNetdiskAccountResolutionError.invalidAccountIdentity) {
        try await resolver.resolveAccountIdentity(accessToken: self.accessToken())
      }
    }
  }

  @Test("Malformed and oversized responses are rejected without exposing their body")
  func malformedAndOversizedResponses() async throws {
    let secret = "resolver.malformed-secret-token"
    let malformedTransport = ScriptedBaiduHTTPTransport(
      handlers: [
        { _ in
          Self.response(
            body:
              #"{"errno":0,"uk":"private-uk","errmsg":"private-message","request_id":"private-request-id"}"#
          )
        }
      ]
    )
    let malformedResolver = BaiduNetdiskAccountResolver(transport: malformedTransport)
    do {
      _ = try await malformedResolver.resolveAccountIdentity(
        accessToken: BaiduAccessToken(secret)
      )
      Issue.record("Expected a malformed response error")
    } catch {
      #expect(error as? BaiduNetdiskAccountResolutionError == .malformedResponse)
      let rendered = [
        String(describing: error),
        String(reflecting: error),
        error.localizedDescription,
      ].joined(separator: " ")
      for forbidden in [
        secret, "private-uk", "private-message", "private-request-id", "errmsg", "request_id",
      ] {
        #expect(!rendered.contains(forbidden))
      }
    }

    let oversizedData = Data(
      repeating: 0x41,
      count: BaiduNetdiskAccountResolver.maximumJSONResponseByteCount + 1
    )
    let oversizedTransport = ScriptedBaiduHTTPTransport(
      handlers: [{ _ in Self.response(data: oversizedData) }]
    )
    let oversizedResolver = BaiduNetdiskAccountResolver(transport: oversizedTransport)
    await #expect(
      throws: BaiduNetdiskAccountResolutionError.responseTooLarge(
        maximum: BaiduNetdiskAccountResolver.maximumJSONResponseByteCount
      )
    ) {
      try await oversizedResolver.resolveAccountIdentity(accessToken: self.accessToken())
    }
  }

  @Test("Transport failures are normalized without leaking the access token")
  func transportFailuresAreRedacted() async throws {
    let secret = "resolver.secret-token-987"
    let transport = ScriptedBaiduHTTPTransport(
      handlers: [{ _ in throw TestError.transportFailure("remote-response-secret") }]
    )
    let resolver = BaiduNetdiskAccountResolver(transport: transport)

    do {
      _ = try await resolver.resolveAccountIdentity(accessToken: BaiduAccessToken(secret))
      Issue.record("Expected the transport failure")
    } catch {
      #expect(error as? BaiduNetdiskAccountResolutionError == .transport)
      let rendered = [
        String(describing: error),
        String(reflecting: error),
        error.localizedDescription,
      ].joined(separator: " ")
      #expect(!rendered.contains(secret))
      #expect(!rendered.contains("remote-response-secret"))
    }
  }

  @Test("Cancellation remains CancellationError")
  func cancellationPropagation() async throws {
    let transport = ScriptedBaiduHTTPTransport(
      handlers: [{ _ in throw CancellationError() }]
    )
    let resolver = BaiduNetdiskAccountResolver(transport: transport)

    await #expect(throws: CancellationError.self) {
      try await resolver.resolveAccountIdentity(accessToken: self.accessToken())
    }
    #expect(await transport.requestCount() == 1)
  }

  @Test("A task cancelled before resolution sends no request")
  func preCancelledTaskMakesNoRequest() async throws {
    let gate = ResolverStartGate()
    let transport = ScriptedBaiduHTTPTransport(
      handlers: [{ _ in Self.response(body: #"{"errno":0,"uk":1}"#) }]
    )
    let resolver = BaiduNetdiskAccountResolver(transport: transport)
    let task = Task {
      await gate.waitUntilOpened()
      return try await resolver.resolveAccountIdentity(accessToken: self.accessToken())
    }

    task.cancel()
    await gate.open()

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    #expect(await transport.requestCount() == 0)
  }

  @Test("Production transport errors map to the narrow account error surface")
  func productionTransportErrorMapping() async throws {
    let cases: [(any Error & Sendable, BaiduNetdiskAccountResolutionError)] = [
      (BaiduHTTPTransportError.invalidResponse, .invalidHTTPResponse),
      (
        BaiduHTTPTransportError.responseTooLarge(maximum: 7_777),
        .responseTooLarge(maximum: 7_777)
      ),
      (BaiduHTTPTransportError.network(.notConnectedToInternet), .transport),
      (BaiduHTTPTransportError.unavailable, .transport),
    ]

    for (transportError, expectedError) in cases {
      let transport = ScriptedBaiduHTTPTransport(
        handlers: [{ _ in throw transportError }]
      )
      let resolver = BaiduNetdiskAccountResolver(transport: transport)
      await #expect(throws: expectedError) {
        try await resolver.resolveAccountIdentity(accessToken: self.accessToken())
      }
      #expect(await transport.requestCount() == 1)
    }

    let cancelledTransport = ScriptedBaiduHTTPTransport(
      handlers: [{ _ in throw URLError(.cancelled) }]
    )
    await #expect(throws: CancellationError.self) {
      try await BaiduNetdiskAccountResolver(transport: cancelledTransport)
        .resolveAccountIdentity(accessToken: self.accessToken())
    }
  }

  @Test("A valid response may use exactly the 64 KiB local ceiling")
  func exactResponseSizeBoundary() async throws {
    var bodyBuilder = Data(#"{"errno":0,"uk":42}"#.utf8)
    bodyBuilder.append(
      Data(
        repeating: 0x20,
        count: BaiduNetdiskAccountResolver.maximumJSONResponseByteCount
          - bodyBuilder.count
      )
    )
    let boundaryBody = bodyBuilder
    #expect(boundaryBody.count == BaiduNetdiskAccountResolver.maximumJSONResponseByteCount)

    let boundaryTransport = ScriptedBaiduHTTPTransport(
      handlers: [{ _ in Self.response(data: boundaryBody) }]
    )
    let identity = try await BaiduNetdiskAccountResolver(transport: boundaryTransport)
      .resolveAccountIdentity(accessToken: accessToken())
    #expect(identity == BaiduAccountIdentity(uk: 42))

    let oversizedTransport = ScriptedBaiduHTTPTransport(
      handlers: [{ _ in Self.response(data: boundaryBody + Data([0x20])) }]
    )
    await #expect(
      throws: BaiduNetdiskAccountResolutionError.responseTooLarge(
        maximum: BaiduNetdiskAccountResolver.maximumJSONResponseByteCount
      )
    ) {
      try await BaiduNetdiskAccountResolver(transport: oversizedTransport)
        .resolveAccountIdentity(accessToken: self.accessToken())
    }
  }

  @Test("Wrong-type and overflowing UK fields fail closed")
  func malformedAccountIdentityTypes() async throws {
    let bodies = [
      #"{"errno":0,"uk":"42"}"#,
      #"{"errno":0,"uk":1.5}"#,
      #"{"errno":0,"uk":9223372036854775808}"#,
    ]

    for body in bodies {
      let transport = ScriptedBaiduHTTPTransport(
        handlers: [{ _ in Self.response(body: body) }]
      )
      await #expect(throws: BaiduNetdiskAccountResolutionError.malformedResponse) {
        try await BaiduNetdiskAccountResolver(transport: transport)
          .resolveAccountIdentity(accessToken: self.accessToken())
      }
    }
  }

  @Test("Concurrent account probes remain keyed to their own access token")
  func concurrentAccountResolutionDoesNotCrossAccounts() async throws {
    let firstToken = "resolver.concurrent-token-a"
    let secondToken = "resolver.concurrent-token-b"
    let transport = TokenKeyedBaiduHTTPTransport(accounts: [
      firstToken: 101,
      secondToken: 202,
    ])
    let resolver = BaiduNetdiskAccountResolver(transport: transport)

    async let first = resolver.resolveAccountIdentity(
      accessToken: BaiduAccessToken(firstToken)
    )
    async let second = resolver.resolveAccountIdentity(
      accessToken: BaiduAccessToken(secondToken)
    )
    let (firstIdentity, secondIdentity) = try await (first, second)

    #expect(firstIdentity == BaiduAccountIdentity(uk: 101))
    #expect(secondIdentity == BaiduAccountIdentity(uk: 202))
    #expect(firstIdentity != secondIdentity)
    #expect(await transport.requestCount() == 2)
  }

  private enum TestError: Error {
    case invalidRequest
    case transportFailure(String)
  }

  private func accessToken() throws -> BaiduAccessToken {
    try BaiduAccessToken("resolver.test-token")
  }

  private static func queryItems(_ request: URLRequest) throws -> [String: String] {
    guard let url = request.url,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let items = components.queryItems
    else {
      throw TestError.invalidRequest
    }
    return Dictionary(
      uniqueKeysWithValues: try items.map { item in
        guard let value = item.value else { throw TestError.invalidRequest }
        return (item.name, value)
      })
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
}

private actor ResolverStartGate {
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
    let pendingWaiters = waiters
    waiters.removeAll()
    for waiter in pendingWaiters {
      waiter.resume()
    }
  }
}

private actor TokenKeyedBaiduHTTPTransport: BaiduHTTPTransport {
  private let accounts: [String: Int64]
  private var capturedRequestCount = 0

  init(accounts: [String: Int64]) {
    self.accounts = accounts
  }

  func send(_ request: URLRequest) async throws -> BaiduHTTPResponse {
    capturedRequestCount += 1
    await Task.yield()
    guard
      let url = request.url,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let token = components.queryItems?.first(where: { $0.name == "access_token" })?.value,
      let uk = accounts[token]
    else {
      throw ScriptedBaiduHTTPTransportError.unexpectedRequest
    }
    return BaiduHTTPResponse(
      statusCode: 200,
      headers: ["content-type": "application/json"],
      body: Data(#"{"errno":0,"uk":\#(uk)}"#.utf8)
    )
  }

  func requestCount() -> Int {
    capturedRequestCount
  }
}
