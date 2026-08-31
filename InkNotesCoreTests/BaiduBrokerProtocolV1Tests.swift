import CryptoKit
import Foundation
import Testing

@testable import InkNotesCore

@Suite("Baidu broker protocol v1 offline boundary")
struct BaiduBrokerProtocolV1Tests {
  @Test("Opaque values, challenge, and sealed start request are canonical and redacted")
  func startRequestAndRedaction() async throws {
    let environment = BrokerTestEnvironment(wallNow: Self.now)
    let session = environment.session()
    let attempt = try await session.begin()
    let verifierData = Self.decode(attempt.testingOnlyVerifier.testingOnlyEncoded)
    let expectedChallenge = Self.canonical(Data(SHA256.hash(data: verifierData)))
    #expect(attempt.testingOnlyChallenge.testingOnlyEncoded == expectedChallenge)

    let expectedStart = Data(
      (#"{"schema":"inknotes.baidu-broker.authorization-start.v1","attempt":""#
        + attempt.testingOnlyAttemptID.testingOnlyEncoded
        + #"","state":""# + attempt.testingOnlyState.testingOnlyEncoded
        + #"","challenge":""# + expectedChallenge + #""}"#).utf8
    )
    #expect(attempt.testingOnlyStartRequest.testingOnlyBody == expectedStart)
    #expect(
      Set([
        attempt.testingOnlyAttemptID.testingOnlyEncoded,
        attempt.testingOnlyState.testingOnlyEncoded,
        attempt.testingOnlyVerifier.testingOnlyEncoded,
      ]).count == 3
    )

    let ticketText = Self.ticket(7)
    let ticket = try BaiduBrokerTicketV1.testingOnly(encoded: ticketText)
    let callbackQuery = Self.callbackQuery(
      attempt: attempt.testingOnlyAttemptID.testingOnlyEncoded,
      state: attempt.testingOnlyState.testingOnlyEncoded,
      ticket: ticketText
    )
    let parsedCallback = try BaiduBrokerUntrustedParsedCallbackV1.parse(
      rawASCIIQuery: callbackQuery
    )
    let wrappedCallback = try BaiduBrokerOriginBoundCallbackV1.testingOnly(
      rawASCIIQuery: callbackQuery
    )

    let parsedResponse = try BaiduBrokerUntrustedParsedExchangeResponseV1.parse(
      data: Self.credentialResponse(
        attempt: attempt.testingOnlyAttemptID.testingOnlyEncoded,
        state: attempt.testingOnlyState.testingOnlyEncoded,
        token: "presentation-secret",
        expiresAt: "2026-08-31T00:10:00Z"
      )
    )
    let wrappedResponse = try BaiduBrokerOriginBoundExchangeResponseV1.testingOnly(
      data: Self.credentialResponse(
        attempt: attempt.testingOnlyAttemptID.testingOnlyEncoded,
        state: attempt.testingOnlyState.testingOnlyEncoded,
        token: "presentation-secret",
        expiresAt: "2026-08-31T00:10:00Z"
      )
    )
    let values: [Any] = [
      attempt.testingOnlyAttemptID,
      attempt.testingOnlyState,
      attempt.testingOnlyVerifier,
      attempt.testingOnlyChallenge,
      ticket,
      attempt,
      attempt.testingOnlyStartRequest,
      parsedCallback,
      wrappedCallback,
      parsedResponse,
      wrappedResponse,
    ]
    for value in values {
      #expect(String(describing: value) == "<redacted>")
      #expect(String(reflecting: value) == "<redacted>")
      #expect(Array(Mirror(reflecting: value).children).isEmpty)
      var rendered = ""
      dump(value, to: &rendered)
      #expect(!rendered.contains("presentation-secret"))
      #expect(!rendered.contains(attempt.testingOnlyState.testingOnlyEncoded))
      #expect(!rendered.contains(ticketText))
    }
  }

  @Test("Opaque values require canonical unpadded 32-byte base64url")
  func opaqueValueBoundaries() throws {
    let valid = Self.canonical(Data(repeating: 0xff, count: 32))
    #expect(valid.utf8.count == 43)
    #expect(try BaiduBrokerStateV1.testingOnly(encoded: valid).testingOnlyEncoded == valid)

    let invalid = [
      Self.canonical(Data(repeating: 0x11, count: 31)),
      Self.canonical(Data(repeating: 0x11, count: 33)),
      valid + "=",
      String(repeating: "A", count: 42),
      String(repeating: "A", count: 44),
      String(repeating: "A", count: 42) + "+",
      String(repeating: "B", count: 43),
    ]
    for encoded in invalid {
      #expect(throws: BaiduBrokerProtocolV1Error.invalidOpaqueValue) {
        try BaiduBrokerStateV1.testingOnly(encoded: encoded)
      }
    }
  }

  @Test("Callback schema is exact and cannot accept another phase")
  func callbackSchemaAndCrossFeed() async throws {
    let environment = BrokerTestEnvironment(wallNow: Self.now)
    let attempt = try await environment.session().begin()
    let attemptID = attempt.testingOnlyAttemptID.testingOnlyEncoded
    let state = attempt.testingOnlyState.testingOnlyEncoded
    let ticket = Self.ticket(1)
    _ = try BaiduBrokerUntrustedParsedCallbackV1.parse(
      rawASCIIQuery: Self.callbackQuery(attempt: attemptID, state: state, ticket: ticket)
    )
    for error in ["authorization_denied", "temporarily_unavailable", "server_error"] {
      _ = try BaiduBrokerUntrustedParsedCallbackV1.parse(
        rawASCIIQuery: Self.callbackErrorQuery(
          attempt: attemptID,
          state: state,
          error: error
        )
      )
    }

    for crossFedSchema in [
      "inknotes.baidu-broker.authorization-start.v1",
      "inknotes.baidu-broker.exchange-request.v1",
      "inknotes.baidu-broker.credential-response.v1",
      "inknotes.baidu-broker.exchange-error.v1",
    ] {
      #expect(throws: BaiduBrokerProtocolV1Error.unsupportedSchema) {
        try BaiduBrokerUntrustedParsedCallbackV1.parse(
          rawASCIIQuery: "schema=\(crossFedSchema)&attempt=\(attemptID)"
            + "&state=\(state)&ticket=\(ticket)"
        )
      }
    }

    let invalid = [
      "schema=inknotes.baidu-broker.exchange-request.v1&attempt=\(attemptID)&state=\(state)&ticket=\(ticket)",
      "schema=inknotes.baidu-broker.callback.v1&attempt=\(attemptID)&state=\(state)&state=\(state)",
      "schema=inknotes.baidu-broker.callback.v1&attempt=\(attemptID)&state=\(state)&ticket=\(ticket)&schema=inknotes.baidu-broker.callback.v1",
      "schema=inknotes.baidu-broker.callback.v1&attempt=\(attemptID)&state=\(state)&ticket=\(ticket)%20",
      "schema=inknotes.baidu-broker.callback.v1&attempt=\(attemptID)&state=\(state)&ticket=\(ticket)+",
      "schema=inknotes.baidu-broker.callback.v1&attempt=\(attemptID)&state=\(state)&ticket=\(ticket)#x",
      "schema=inknotes.baidu-broker.callback.v1&attempt=\(attemptID)&state=\(state)&ticket=",
      "Schema=inknotes.baidu-broker.callback.v1&attempt=\(attemptID)&state=\(state)&ticket=\(ticket)",
      Self.callbackErrorQuery(attempt: attemptID, state: state, error: "access_denied"),
      Self.callbackErrorQuery(attempt: attemptID, state: state, error: "Authorization_denied"),
      Self.callbackErrorQuery(attempt: attemptID, state: state, error: "authorization_denıed"),
    ]
    for query in invalid {
      #expect(throws: (any Error).self) {
        try BaiduBrokerUntrustedParsedCallbackV1.parse(rawASCIIQuery: query)
      }
    }
    #expect(throws: BaiduBrokerProtocolV1Error.inputTooLarge) {
      try BaiduBrokerUntrustedParsedCallbackV1.parse(
        rawASCIIQuery: String(repeating: "x", count: 1_025)
      )
    }
  }

  @Test("Five phase discriminators reject cross-fed JSON and malformed string objects")
  func strictJSONAndCrossFeed() async throws {
    let environment = BrokerTestEnvironment(wallNow: Self.now)
    let session = environment.session()
    let attempt = try await session.begin()
    let startBody = attempt.testingOnlyStartRequest.testingOnlyBody
    let callback = try Self.callback(for: attempt, ticket: Self.ticket(2))
    _ = try await session.acceptOriginBoundCallback(callback)
    let exchangeBody = try await session.makeExchangeRequest().testingOnlyBody
    let response = Self.credentialResponse(
      attempt: attempt.testingOnlyAttemptID.testingOnlyEncoded,
      state: attempt.testingOnlyState.testingOnlyEncoded,
      token: "token",
      expiresAt: "2026-08-31T00:10:00Z"
    )
    _ = try BaiduBrokerUntrustedParsedExchangeResponseV1.parse(data: response)
    let callbackShapedJSON = Data(
      (#"{"schema":"inknotes.baidu-broker.callback.v1","attempt":""#
        + attempt.testingOnlyAttemptID.testingOnlyEncoded
        + #"","state":""# + attempt.testingOnlyState.testingOnlyEncoded
        + #"","ticket":""# + Self.ticket(2) + #""}"#).utf8
    )
    let validSurrogatePair = Self.replacing(
      response,
      "\"accessToken\":\"token\"",
      with: "\"accessToken\":\"\\uD83D\\uDE00\""
    )
    _ = try BaiduBrokerUntrustedParsedExchangeResponseV1.parse(data: validSurrogatePair)

    for crossFed in [startBody, exchangeBody, callbackShapedJSON] {
      #expect(throws: BaiduBrokerProtocolV1Error.unsupportedSchema) {
        try BaiduBrokerUntrustedParsedExchangeResponseV1.parse(data: crossFed)
      }
    }
    let errorShapedAsCredential = Data(
      (#"{"schema":"inknotes.baidu-broker.credential-response.v1","attempt":""#
        + attempt.testingOnlyAttemptID.testingOnlyEncoded
        + #"","state":""# + attempt.testingOnlyState.testingOnlyEncoded
        + #"","error":"server_error"}"#).utf8
    )
    #expect(throws: BaiduBrokerProtocolV1Error.invalidJSON) {
      try BaiduBrokerUntrustedParsedExchangeResponseV1.parse(data: errorShapedAsCredential)
    }
    let credentialShapedAsError = Self.replacing(
      response,
      "inknotes.baidu-broker.credential-response.v1",
      with: "inknotes.baidu-broker.exchange-error.v1"
    )
    #expect(throws: BaiduBrokerProtocolV1Error.invalidJSON) {
      try BaiduBrokerUntrustedParsedExchangeResponseV1.parse(data: credentialShapedAsError)
    }

    let duplicateEscapedSchema = Data(
      (#"{"schema":"inknotes.baidu-broker.credential-response.v1","sch\u0065ma":"inknotes.baidu-broker.credential-response.v1","attempt":""#
        + attempt.testingOnlyAttemptID.testingOnlyEncoded
        + #"","state":""# + attempt.testingOnlyState.testingOnlyEncoded
        + #"","brokerBindingID":""# + Self.bindingID
        + #"","accessToken":"token","expiresAt":"2026-08-31T00:10:00Z"}"#).utf8
    )
    let malformed: [Data] = [
      duplicateEscapedSchema,
      Self.replacing(
        response,
        "\"expiresAt\":\"2026-08-31T00:10:00Z\"",
        with: "\"expiresAt\":\"2026-08-31T00:10:00Z\",\"extra\":\"x\""
      ),
      Self.replacing(
        response,
        ",\"expiresAt\":\"2026-08-31T00:10:00Z\"",
        with: ""
      ),
      Self.replacing(response, "\"accessToken\":\"token\"", with: "\"accessToken\":[]"),
      Self.replacing(response, "\"accessToken\":\"token\"", with: "\"accessToken\":1"),
      Self.replacing(response, "\"accessToken\":\"token\"", with: "\"accessToken\":null"),
      Self.replacing(response, "\"accessToken\":\"token\"", with: "\"accessToken\":true"),
      Self.replacing(
        response,
        "\"accessToken\":\"token\"",
        with: "\"accessToken\":{\"value\":\"token\"}"
      ),
      Data(#"{"schema":"\uD800"}"#.utf8),
      Data(#"{"schema":"\uDC00"}"#.utf8),
      Data(#"{"schema":"\uD800\u0041"}"#.utf8),
      Data("{\"schema\":\"bad\nvalue\"}".utf8),
      Data([0xef, 0xbb, 0xbf]) + response,
      Data([0xff, 0xfe]),
      response + Data("{}".utf8),
      Data("[]".utf8),
      Data("1".utf8),
      Data("null".utf8),
      Data("false".utf8),
      Data(#""string""#.utf8),
    ]
    for data in malformed {
      #expect(throws: (any Error).self) {
        try BaiduBrokerUntrustedParsedExchangeResponseV1.parse(data: data)
      }
    }
    let exactMaximum = response + Data(repeating: 0x20, count: 2_048 - response.count)
    _ = try BaiduBrokerUntrustedParsedExchangeResponseV1.parse(data: exactMaximum)
    #expect(throws: BaiduBrokerProtocolV1Error.inputTooLarge) {
      try BaiduBrokerUntrustedParsedExchangeResponseV1.parse(
        data: exactMaximum + Data([0x20])
      )
    }
  }

  @Test("Credential fields enforce UUIDv4, UTF-8 token bytes, and exact UTC seconds")
  func credentialFieldBoundaries() async throws {
    let attempt = Self.canonical(Data(repeating: 0x31, count: 32))
    let state = Self.canonical(Data(repeating: 0x32, count: 32))
    _ = try BaiduBrokerUntrustedParsedExchangeResponseV1.parse(
      data: Self.credentialResponse(
        attempt: attempt,
        state: state,
        token: String(repeating: "é", count: 128),
        expiresAt: "2026-08-31T00:10:00Z"
      )
    )
    for token in [
      String(repeating: "é", count: 128) + "x",
      String(repeating: "é", count: 129),
      "bad token",
      "bad\\nvalue",
    ] {
      #expect(throws: (any Error).self) {
        try BaiduBrokerUntrustedParsedExchangeResponseV1.parse(
          data: Self.credentialResponse(
            attempt: attempt,
            state: state,
            token: token,
            expiresAt: "2026-08-31T00:10:00Z"
          )
        )
      }
    }
    for bindingID in [
      Self.bindingID.uppercased(),
      "d0000000-0000-4000-7000-000000000001",
      "d0000000-0000-1000-8000-000000000001",
      "00000000-0000-0000-0000-000000000000",
    ] {
      #expect(throws: (any Error).self) {
        try BaiduBrokerUntrustedParsedExchangeResponseV1.parse(
          data: Self.credentialResponse(
            attempt: attempt,
            state: state,
            token: "token",
            bindingID: bindingID,
            expiresAt: "2026-08-31T00:10:00Z"
          )
        )
      }
    }
    for expiresAt in [
      "2026-08-31T00:10:00.000Z",
      "2026-08-31T00:10:00+00:00",
      "2026-08-31t00:10:00z",
      "2026-02-30T00:10:00Z",
    ] {
      #expect(throws: BaiduBrokerProtocolV1Error.invalidExpiration) {
        try BaiduBrokerUntrustedParsedExchangeResponseV1.parse(
          data: Self.credentialResponse(
            attempt: attempt,
            state: state,
            token: "token",
            expiresAt: expiresAt
          )
        )
      }
    }
  }

  @Test("Begin rejects overlap and fails atomically on repeated entropy")
  func beginIsAtomic() async throws {
    let environment = BrokerTestEnvironment(wallNow: Self.now)
    let session = environment.session()
    _ = try await session.begin()
    await #expect(throws: BaiduBrokerProtocolV1Error.activeAttemptExists) {
      try await session.begin()
    }
    #expect(await session.snapshot().phase == .awaitingOriginBoundCallback)

    let repeated = Data(repeating: 0x44, count: 32)
    let collisionEnvironment = BrokerTestEnvironment(
      wallNow: Self.now,
      entropy: [repeated, repeated, repeated]
    )
    let collisionSession = collisionEnvironment.session()
    await #expect(throws: BaiduBrokerProtocolV1Error.entropyCollision) {
      try await collisionSession.begin()
    }
    let snapshot = await collisionSession.snapshot()
    #expect(snapshot.phase == .terminal)
    #expect(snapshot.terminal == .protocolFailure)
    #expect(snapshot.generation == 0)

    let sharedAuthority = BaiduBrokerReplayAuthorityV1.testingOnly()
    let repeatedBinding = [
      Data(repeating: 0x11, count: 32),
      Data(repeating: 0x22, count: 32),
      Data(repeating: 0x33, count: 32),
    ]
    let firstEnvironment = BrokerTestEnvironment(
      wallNow: Self.now,
      entropy: repeatedBinding,
      replayAuthority: sharedAuthority
    )
    let firstSession = firstEnvironment.session()
    _ = try await firstSession.begin()
    await firstSession.cancel()
    let secondEnvironment = BrokerTestEnvironment(
      wallNow: Self.now,
      entropy: repeatedBinding,
      replayAuthority: sharedAuthority
    )
    let secondSession = secondEnvironment.session()
    await #expect(throws: BaiduBrokerProtocolV1Error.attemptBindingReplay) {
      try await secondSession.begin()
    }
    #expect(await secondSession.snapshot().terminal == .protocolFailure)
  }

  @Test("Shared attempt-binding memory is bounded and never evicts")
  func attemptBindingCapacity() async throws {
    let environment = BrokerTestEnvironment(wallNow: Self.now)
    let session = environment.session()
    for _ in 0..<512 {
      _ = try await session.begin()
      await session.cancel()
    }
    await #expect(throws: BaiduBrokerProtocolV1Error.attemptBindingCapacityReached) {
      try await session.begin()
    }
    #expect(await session.snapshot().terminal == .protocolFailure)
  }

  @Test("Exchange binds attempt, state, ticket, verifier, and accepts format-only response")
  func deterministicExchange() async throws {
    let environment = BrokerTestEnvironment(wallNow: Self.now)
    let session = environment.session()
    let attempt = try await session.begin()
    let ticket = Self.ticket(3)
    _ = try await session.acceptOriginBoundCallback(
      Self.callback(for: attempt, ticket: ticket)
    )
    let request = try await session.makeExchangeRequest()
    let expected = Data(
      (#"{"schema":"inknotes.baidu-broker.exchange-request.v1","attempt":""#
        + attempt.testingOnlyAttemptID.testingOnlyEncoded
        + #"","state":""# + attempt.testingOnlyState.testingOnlyEncoded
        + #"","ticket":""# + ticket
        + #"","verifier":""# + attempt.testingOnlyVerifier.testingOnlyEncoded + #""}"#).utf8
    )
    #expect(request.testingOnlyBody == expected)
    #expect(String(describing: request) == "<redacted>")
    #expect(Array(Mirror(reflecting: request).children).isEmpty)
    var renderedRequest = ""
    dump(request, to: &renderedRequest)
    #expect(!renderedRequest.contains(ticket))
    #expect(!renderedRequest.contains(attempt.testingOnlyVerifier.testingOnlyEncoded))
    await #expect(throws: BaiduBrokerProtocolV1Error.ticketAlreadyDispatched) {
      try await session.makeExchangeRequest()
    }

    let response = try Self.response(for: attempt, expiresAt: "2026-08-31T00:10:00Z")
    #expect(
      try await session.acceptOriginBoundExchangeResponse(response)
        == .parsedCredentialFormatAccepted
    )
    await #expect(throws: BaiduBrokerProtocolV1Error.lateResponse) {
      try await session.acceptOriginBoundExchangeResponse(response)
    }
  }

  @Test("Monotonic attempt, ticket, and response deadlines fail at exact boundaries")
  func monotonicDeadlines() async throws {
    let attemptEnvironment = BrokerTestEnvironment(wallNow: Self.now)
    let attemptSession = attemptEnvironment.session()
    let attempt = try await attemptSession.begin()
    attemptEnvironment.advance(seconds: 600)
    await #expect(throws: BaiduBrokerProtocolV1Error.attemptExpired) {
      try await attemptSession.acceptOriginBoundCallback(Self.callback(for: attempt))
    }
    #expect(await attemptSession.snapshot().terminal == .attemptExpired)
    await #expect(throws: BaiduBrokerProtocolV1Error.attemptExpired) {
      try await attemptSession.acceptOriginBoundCallback(Self.callback(for: attempt))
    }

    let ticketEnvironment = BrokerTestEnvironment(wallNow: Self.now)
    let ticketSession = ticketEnvironment.session()
    let ticketAttempt = try await ticketSession.begin()
    _ = try await ticketSession.acceptOriginBoundCallback(Self.callback(for: ticketAttempt))
    ticketEnvironment.advance(seconds: 60)
    await #expect(throws: BaiduBrokerProtocolV1Error.exchangeWindowExpired) {
      try await ticketSession.makeExchangeRequest()
    }
    #expect(await ticketSession.snapshot().terminal == .exchangeWindowExpired)
    await #expect(throws: BaiduBrokerProtocolV1Error.exchangeWindowExpired) {
      try await ticketSession.makeExchangeRequest()
    }

    let minimumEnvironment = BrokerTestEnvironment(wallNow: Self.now)
    let minimumSession = minimumEnvironment.session()
    let minimumAttempt = try await minimumSession.begin()
    minimumEnvironment.advance(seconds: 550)
    _ = try await minimumSession.acceptOriginBoundCallback(Self.callback(for: minimumAttempt))
    minimumEnvironment.advance(seconds: 50)
    await #expect(throws: BaiduBrokerProtocolV1Error.exchangeWindowExpired) {
      try await minimumSession.makeExchangeRequest()
    }

    let responseEnvironment = BrokerTestEnvironment(wallNow: Self.now)
    let responseSession = responseEnvironment.session()
    let responseAttempt = try await Self.advanceToExchange(responseSession)
    let response = try Self.response(
      for: responseAttempt,
      expiresAt: "2026-08-31T00:10:00Z"
    )
    responseEnvironment.advance(seconds: 60)
    await #expect(throws: BaiduBrokerProtocolV1Error.exchangeWindowExpired) {
      try await responseSession.acceptOriginBoundExchangeResponse(response)
    }
  }

  @Test("Wall-clock rollback cannot extend credential acceptance")
  func wallClockRollbackDoesNotExtend() async throws {
    let environment = BrokerTestEnvironment(wallNow: Self.now)
    let session = environment.session()
    let attempt = try await session.begin()
    _ = try await session.acceptOriginBoundCallback(Self.callback(for: attempt))
    environment.setWall(Self.now.addingTimeInterval(600))
    _ = try await session.makeExchangeRequest()
    environment.setWall(Self.now)
    let response = try Self.response(for: attempt, expiresAt: "2026-08-31T00:13:20Z")
    await #expect(throws: BaiduBrokerProtocolV1Error.invalidExpiration) {
      try await session.acceptOriginBoundExchangeResponse(response)
    }
    #expect(await session.snapshot().terminal == .protocolFailure)

    let projectedEnvironment = BrokerTestEnvironment(wallNow: Self.now)
    let projectedSession = projectedEnvironment.session()
    let projectedAttempt = try await projectedSession.begin()
    projectedEnvironment.advance(seconds: 540)
    projectedEnvironment.setWall(Self.now.addingTimeInterval(1))
    _ = try await projectedSession.acceptOriginBoundCallback(
      Self.callback(for: projectedAttempt, ticket: Self.ticket(102))
    )
    _ = try await projectedSession.makeExchangeRequest()
    let projectedResponse = try Self.response(
      for: projectedAttempt,
      expiresAt: "2026-08-31T00:10:00Z"
    )
    await #expect(throws: BaiduBrokerProtocolV1Error.invalidExpiration) {
      try await projectedSession.acceptOriginBoundExchangeResponse(projectedResponse)
    }

    let backwardEnvironment = BrokerTestEnvironment(wallNow: Self.now)
    let backwardSession = backwardEnvironment.session()
    let backwardAttempt = try await backwardSession.begin()
    backwardEnvironment.advance(seconds: -1)
    await #expect(throws: BaiduBrokerProtocolV1Error.monotonicClockInvalid) {
      try await backwardSession.acceptOriginBoundCallback(Self.callback(for: backwardAttempt))
    }
    #expect(await backwardSession.snapshot().terminal == .protocolFailure)

    let partialRegressionEnvironment = BrokerTestEnvironment(wallNow: Self.now)
    let partialRegressionSession = partialRegressionEnvironment.session()
    let partialRegressionAttempt = try await partialRegressionSession.begin()
    partialRegressionEnvironment.advance(seconds: 100)
    _ = try await partialRegressionSession.acceptOriginBoundCallback(
      Self.callback(for: partialRegressionAttempt, ticket: Self.ticket(103))
    )
    partialRegressionEnvironment.advance(seconds: -50)
    await #expect(throws: BaiduBrokerProtocolV1Error.monotonicClockInvalid) {
      try await partialRegressionSession.makeExchangeRequest()
    }
    #expect(await partialRegressionSession.snapshot().terminal == .protocolFailure)
  }

  @Test("Authorization fixed errors terminate without opening exchange")
  func authorizationFixedErrorsTerminate() async throws {
    for error in ["authorization_denied", "temporarily_unavailable", "server_error"] {
      let environment = BrokerTestEnvironment(wallNow: Self.now)
      let session = environment.session()
      let attempt = try await session.begin()
      let callback = try BaiduBrokerOriginBoundCallbackV1.testingOnly(
        rawASCIIQuery: Self.callbackErrorQuery(
          attempt: attempt.testingOnlyAttemptID.testingOnlyEncoded,
          state: attempt.testingOnlyState.testingOnlyEncoded,
          error: error
        )
      )
      #expect(try await session.acceptOriginBoundCallback(callback) == .endedWithFixedError)
      #expect(await session.snapshot().terminal == .authorizationFixedError)
      await #expect(throws: BaiduBrokerProtocolV1Error.lateResponse) {
        try await session.acceptOriginBoundCallback(callback)
      }
    }
  }

  @Test("Old callbacks and responses do not destroy the current generation")
  func staleGenerationPreservesCurrentAttempt() async throws {
    let callbackEnvironment = BrokerTestEnvironment(wallNow: Self.now)
    let callbackSession = callbackEnvironment.session()
    let oldAttempt = try await callbackSession.begin()
    await callbackSession.cancel()
    let currentAttempt = try await callbackSession.begin()
    await #expect(throws: BaiduBrokerProtocolV1Error.attemptMismatch) {
      try await callbackSession.acceptOriginBoundCallback(Self.callback(for: oldAttempt))
    }
    #expect(await callbackSession.snapshot().phase == .awaitingOriginBoundCallback)
    #expect(
      try await callbackSession.acceptOriginBoundCallback(Self.callback(for: currentAttempt))
        == .exchangeReady
    )

    let responseEnvironment = BrokerTestEnvironment(wallNow: Self.now)
    let oldResponseSession = responseEnvironment.session()
    let oldResponseAttempt = try await Self.advanceToExchange(oldResponseSession)
    let oldResponse = try Self.response(
      for: oldResponseAttempt,
      expiresAt: "2026-08-31T00:10:00Z"
    )
    await oldResponseSession.cancel()
    let newResponseSession = responseEnvironment.session()
    let newAttempt = try await newResponseSession.begin()
    await #expect(throws: BaiduBrokerProtocolV1Error.attemptMismatch) {
      try await newResponseSession.acceptOriginBoundExchangeResponse(oldResponse)
    }
    #expect(await newResponseSession.snapshot().phase == .awaitingOriginBoundCallback)
    #expect(
      try await newResponseSession.acceptOriginBoundCallback(
        Self.callback(for: newAttempt, ticket: Self.ticket(101))
      )
        == .exchangeReady
    )
  }

  @Test("Ticket collision, replay, and bounded-memory exhaustion fail closed")
  func ticketReplayDefense() async throws {
    for reserved: (BaiduBrokerAuthorizationAttemptV1) -> String in [
      { $0.testingOnlyAttemptID.testingOnlyEncoded },
      { $0.testingOnlyState.testingOnlyEncoded },
      { $0.testingOnlyVerifier.testingOnlyEncoded },
      { $0.testingOnlyChallenge.testingOnlyEncoded },
    ] {
      let environment = BrokerTestEnvironment(wallNow: Self.now)
      let session = environment.session()
      let attempt = try await session.begin()
      await #expect(throws: BaiduBrokerProtocolV1Error.invalidTicket) {
        try await session.acceptOriginBoundCallback(
          Self.callback(for: attempt, ticket: reserved(attempt))
        )
      }
    }

    let replayEnvironment = BrokerTestEnvironment(wallNow: Self.now)
    let firstReplaySession = replayEnvironment.session()
    let first = try await firstReplaySession.begin()
    let replayedTicket = Self.ticket(40)
    _ = try await firstReplaySession.acceptOriginBoundCallback(
      Self.callback(for: first, ticket: replayedTicket)
    )
    await firstReplaySession.cancel()
    let secondReplaySession = replayEnvironment.session()
    let second = try await secondReplaySession.begin()
    await #expect(throws: BaiduBrokerProtocolV1Error.ticketReplay) {
      try await secondReplaySession.acceptOriginBoundCallback(
        Self.callback(for: second, ticket: replayedTicket)
      )
    }

    let capacityEnvironment = BrokerTestEnvironment(wallNow: Self.now)
    let capacitySession = capacityEnvironment.session()
    for index in 0..<256 {
      let attempt = try await capacitySession.begin()
      _ = try await capacitySession.acceptOriginBoundCallback(
        Self.callback(for: attempt, ticket: Self.ticket(1_000 + index))
      )
      await capacitySession.cancel()
    }
    let overflowAttempt = try await capacitySession.begin()
    await #expect(throws: BaiduBrokerProtocolV1Error.ticketReplayCapacityReached) {
      try await capacitySession.acceptOriginBoundCallback(
        Self.callback(for: overflowAttempt, ticket: Self.ticket(2_000))
      )
    }
  }

  @Test("Cancellation fails late work in callback, ticket, and dispatched phases")
  func cancellationAtEveryPhase() async throws {
    let callbackEnvironment = BrokerTestEnvironment(wallNow: Self.now)
    let callbackSession = callbackEnvironment.session()
    let callbackAttempt = try await callbackSession.begin()
    await callbackSession.cancel()
    await #expect(throws: BaiduBrokerProtocolV1Error.cancelled) {
      try await callbackSession.acceptOriginBoundCallback(Self.callback(for: callbackAttempt))
    }

    let ticketEnvironment = BrokerTestEnvironment(wallNow: Self.now)
    let ticketSession = ticketEnvironment.session()
    let ticketAttempt = try await ticketSession.begin()
    _ = try await ticketSession.acceptOriginBoundCallback(Self.callback(for: ticketAttempt))
    await ticketSession.cancel()
    await #expect(throws: BaiduBrokerProtocolV1Error.cancelled) {
      try await ticketSession.makeExchangeRequest()
    }

    let dispatchedEnvironment = BrokerTestEnvironment(wallNow: Self.now)
    let dispatchedSession = dispatchedEnvironment.session()
    let dispatchedAttempt = try await Self.advanceToExchange(dispatchedSession)
    let response = try Self.response(
      for: dispatchedAttempt,
      expiresAt: "2026-08-31T00:10:00Z"
    )
    await dispatchedSession.cancel()
    await #expect(throws: BaiduBrokerProtocolV1Error.cancelled) {
      try await dispatchedSession.acceptOriginBoundExchangeResponse(response)
    }
  }

  @Test("Credential lifetime is checked against internal wall time at 300 and 900 seconds")
  func credentialLifetimeBoundaries() async throws {
    for (expiresAt, accepted) in [
      ("2026-08-31T00:05:00Z", false),
      ("2026-08-31T00:05:01Z", true),
      ("2026-08-31T00:15:00Z", true),
      ("2026-08-31T00:15:01Z", false),
    ] {
      let environment = BrokerTestEnvironment(wallNow: Self.now)
      let session = environment.session()
      let attempt = try await Self.advanceToExchange(session)
      let response = try Self.response(for: attempt, expiresAt: expiresAt)
      if accepted {
        #expect(
          try await session.acceptOriginBoundExchangeResponse(response)
            == .parsedCredentialFormatAccepted
        )
      } else {
        await #expect(throws: BaiduBrokerProtocolV1Error.invalidExpiration) {
          try await session.acceptOriginBoundExchangeResponse(response)
        }
      }
    }
  }

  @Test("All seven frozen exchange errors parse and terminate without credential output")
  func frozenExchangeErrors() async throws {
    let errors = [
      "ticket_invalid", "ticket_expired", "ticket_replayed", "state_mismatch",
      "authorization_denied", "temporarily_unavailable", "server_error",
    ]
    for error in errors {
      let environment = BrokerTestEnvironment(wallNow: Self.now)
      let session = environment.session()
      let attempt = try await Self.advanceToExchange(session)
      let response = try BaiduBrokerOriginBoundExchangeResponseV1.testingOnly(
        data: Self.exchangeErrorResponse(for: attempt, error: error)
      )
      #expect(
        try await session.acceptOriginBoundExchangeResponse(response) == .endedWithFixedError
      )
      #expect(await session.snapshot().terminal == .exchangeFixedError)
    }
    let environment = BrokerTestEnvironment(wallNow: Self.now)
    let attempt = try await environment.session().begin()
    for invalidError in [
      "expired_ticket", "Ticket_invalid", "ticket-invalid", "ticket_invalıd",
    ] {
      #expect(throws: BaiduBrokerProtocolV1Error.invalidFixedError) {
        try BaiduBrokerUntrustedParsedExchangeResponseV1.parse(
          data: Self.exchangeErrorResponse(for: attempt, error: invalidError)
        )
      }
    }
  }

  @Test("Matching attempt with wrong state terminates while concurrent one-shot has one winner")
  func stateMismatchAndConcurrency() async throws {
    let mismatchEnvironment = BrokerTestEnvironment(wallNow: Self.now)
    let mismatchSession = mismatchEnvironment.session()
    let mismatchAttempt = try await Self.advanceToExchange(mismatchSession)
    let wrongStateResponse = try BaiduBrokerOriginBoundExchangeResponseV1.testingOnly(
      data: Self.credentialResponse(
        attempt: mismatchAttempt.testingOnlyAttemptID.testingOnlyEncoded,
        state: Self.ticket(9_999),
        token: "token",
        expiresAt: "2026-08-31T00:10:00Z"
      )
    )
    await #expect(throws: BaiduBrokerProtocolV1Error.stateMismatch) {
      try await mismatchSession.acceptOriginBoundExchangeResponse(wrongStateResponse)
    }
    #expect(await mismatchSession.snapshot().terminal == .protocolFailure)

    let concurrentEnvironment = BrokerTestEnvironment(wallNow: Self.now)
    let concurrentSession = concurrentEnvironment.session()
    let concurrentAttempt = try await concurrentSession.begin()
    let callback = try Self.callback(for: concurrentAttempt)
    let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
      for _ in 0..<2 {
        group.addTask {
          do {
            _ = try await concurrentSession.acceptOriginBoundCallback(callback)
            return true
          } catch {
            return false
          }
        }
      }
      var values: [Bool] = []
      for await value in group { values.append(value) }
      return values
    }
    #expect(results.filter { $0 }.count == 1)
  }

  private static let bindingID = "d0000000-0000-4000-8000-000000000001"
  private static let now = Date(timeIntervalSince1970: 1_788_134_400)

  private static func canonical(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func decode(_ encoded: String) -> Data {
    var base64 = encoded.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64.append("=")
    return Data(base64Encoded: base64)!
  }

  private static func ticket(_ value: Int) -> String {
    var bytes = [UInt8](repeating: 0x99, count: 32)
    var remaining = UInt64(value)
    for index in stride(from: 31, through: 24, by: -1) {
      bytes[index] = UInt8(remaining & 0xff)
      remaining >>= 8
    }
    return canonical(Data(bytes))
  }

  private static func callbackQuery(attempt: String, state: String, ticket: String) -> String {
    "schema=inknotes.baidu-broker.callback.v1&attempt=\(attempt)&state=\(state)&ticket=\(ticket)"
  }

  private static func callbackErrorQuery(
    attempt: String,
    state: String,
    error: String
  ) -> String {
    "schema=inknotes.baidu-broker.callback.v1&attempt=\(attempt)&state=\(state)&error=\(error)"
  }

  private static func callback(
    for attempt: BaiduBrokerAuthorizationAttemptV1,
    ticket: String = ticket(100)
  ) throws -> BaiduBrokerOriginBoundCallbackV1 {
    try BaiduBrokerOriginBoundCallbackV1.testingOnly(
      rawASCIIQuery: callbackQuery(
        attempt: attempt.testingOnlyAttemptID.testingOnlyEncoded,
        state: attempt.testingOnlyState.testingOnlyEncoded,
        ticket: ticket
      )
    )
  }

  private static func advanceToExchange(
    _ session: BaiduBrokerAuthorizationSessionV1
  ) async throws -> BaiduBrokerAuthorizationAttemptV1 {
    let attempt = try await session.begin()
    _ = try await session.acceptOriginBoundCallback(callback(for: attempt))
    _ = try await session.makeExchangeRequest()
    return attempt
  }

  private static func credentialResponse(
    attempt: String,
    state: String,
    token: String,
    bindingID: String = bindingID,
    expiresAt: String
  ) -> Data {
    Data(
      (#"{"schema":"inknotes.baidu-broker.credential-response.v1","attempt":""#
        + attempt
        + #"","state":""# + state
        + #"","brokerBindingID":""# + bindingID
        + #"","accessToken":""# + token
        + #"","expiresAt":""# + expiresAt + #""}"#).utf8
    )
  }

  private static func response(
    for attempt: BaiduBrokerAuthorizationAttemptV1,
    expiresAt: String
  ) throws -> BaiduBrokerOriginBoundExchangeResponseV1 {
    try BaiduBrokerOriginBoundExchangeResponseV1.testingOnly(
      data: credentialResponse(
        attempt: attempt.testingOnlyAttemptID.testingOnlyEncoded,
        state: attempt.testingOnlyState.testingOnlyEncoded,
        token: "response-token",
        expiresAt: expiresAt
      )
    )
  }

  private static func exchangeErrorResponse(
    for attempt: BaiduBrokerAuthorizationAttemptV1,
    error: String
  ) -> Data {
    Data(
      (#"{"schema":"inknotes.baidu-broker.exchange-error.v1","attempt":""#
        + attempt.testingOnlyAttemptID.testingOnlyEncoded
        + #"","state":""# + attempt.testingOnlyState.testingOnlyEncoded
        + #"","error":""# + error + #""}"#).utf8
    )
  }

  private static func replacing(_ data: Data, _ target: String, with replacement: String) -> Data {
    Data(
      String(decoding: data, as: UTF8.self)
        .replacingOccurrences(of: target, with: replacement).utf8
    )
  }
}

private final class BrokerTestEnvironment: @unchecked Sendable {
  private let lock = NSLock()
  private let baseInstant = ContinuousClock().now
  private var offset: Duration = .zero
  private var wall: Date
  private var entropyValues: [Data]
  private var entropyCounter: UInt64 = 0
  private let replayAuthority: BaiduBrokerReplayAuthorityV1

  init(
    wallNow: Date,
    entropy: [Data] = [],
    replayAuthority: BaiduBrokerReplayAuthorityV1 = .testingOnly()
  ) {
    wall = wallNow
    entropyValues = entropy
    self.replayAuthority = replayAuthority
  }

  func session() -> BaiduBrokerAuthorizationSessionV1 {
    BaiduBrokerAuthorizationSessionV1(
      testingOnlyMonotonicNow: { [self] in monotonicNow() },
      testingOnlyWallNow: { [self] in wallNow() },
      testingOnlyEntropy: { [self] in nextEntropy() },
      testingOnlyReplayAuthority: replayAuthority
    )
  }

  func advance(seconds: Int64) {
    lock.lock()
    offset += .seconds(seconds)
    lock.unlock()
  }

  func setWall(_ date: Date) {
    lock.lock()
    wall = date
    lock.unlock()
  }

  private func monotonicNow() -> ContinuousClock.Instant {
    lock.lock()
    let instant = baseInstant.advanced(by: offset)
    lock.unlock()
    return instant
  }

  private func wallNow() -> Date {
    lock.lock()
    let date = wall
    lock.unlock()
    return date
  }

  private func nextEntropy() -> Data {
    lock.lock()
    defer { lock.unlock() }
    if !entropyValues.isEmpty {
      return entropyValues.removeFirst()
    }
    entropyCounter += 1
    var bytes = [UInt8](repeating: 0, count: 32)
    var remaining = entropyCounter
    for index in stride(from: 31, through: 24, by: -1) {
      bytes[index] = UInt8(remaining & 0xff)
      remaining >>= 8
    }
    return Data(bytes)
  }
}
