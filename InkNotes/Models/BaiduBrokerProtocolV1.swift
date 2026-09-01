import CryptoKit
import Foundation
import Security

enum BaiduBrokerProtocolV1Error: Error, Equatable, Sendable {
  case randomnessUnavailable
  case invalidOpaqueValue
  case inputTooLarge
  case invalidQuery
  case invalidJSON
  case unsupportedSchema
  case invalidFixedError
  case invalidExpiration
  case noActiveAttempt
  case activeAttemptExists
  case entropyCollision
  case generationExhausted
  case attemptExpired
  case exchangeWindowExpired
  case stateMismatch
  case attemptMismatch
  case invalidTicket
  case ticketReplay
  case ticketReplayCapacityReached
  case attemptBindingReplay
  case attemptBindingCapacityReached
  case monotonicClockInvalid
  case callbackAlreadyConsumed
  case ticketAlreadyDispatched
  case exchangeNotDispatched
  case cancelled
  case lateResponse
}

private enum BaiduBrokerSchemaV1 {
  static let authorizationStart = "inknotes.baidu-broker.authorization-start.v1"
  static let callback = "inknotes.baidu-broker.callback.v1"
  static let exchangeRequest = "inknotes.baidu-broker.exchange-request.v1"
  static let credentialResponse = "inknotes.baidu-broker.credential-response.v1"
  static let exchangeError = "inknotes.baidu-broker.exchange-error.v1"
}

private enum BaiduBrokerOpaqueValueV1 {
  static let byteCount = 32

  static func secureRandomData() throws -> Data {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    let status = bytes.withUnsafeMutableBytes { buffer in
      guard let baseAddress = buffer.baseAddress else { return errSecAllocate }
      return SecRandomCopyBytes(kSecRandomDefault, byteCount, baseAddress)
    }
    guard status == errSecSuccess else {
      throw BaiduBrokerProtocolV1Error.randomnessUnavailable
    }
    return Data(bytes)
  }

  static func generate(using entropy: () throws -> Data) throws -> String {
    let data = try entropy()
    guard data.count == byteCount else {
      throw BaiduBrokerProtocolV1Error.invalidOpaqueValue
    }
    return canonicalEncoding(data)
  }

  static func validate(_ encoded: String) throws -> String {
    guard encoded.utf8.count == 43,
      encoded.unicodeScalars.allSatisfy({ scalar in
        switch scalar.value {
        case 45, 48...57, 65...90, 95, 97...122:
          true
        default:
          false
        }
      })
    else {
      throw BaiduBrokerProtocolV1Error.invalidOpaqueValue
    }

    var base64 = encoded.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64.append("=")
    guard let decoded = Data(base64Encoded: base64),
      decoded.count == byteCount,
      canonicalEncoding(decoded) == encoded
    else {
      throw BaiduBrokerProtocolV1Error.invalidOpaqueValue
    }
    return encoded
  }

  static func matches(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for index in left.indices {
      difference |= left[index] ^ right[index]
    }
    return difference == 0
  }

  static func decodedData(_ encoded: String) throws -> Data {
    var base64 = encoded.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64.append("=")
    guard let data = Data(base64Encoded: base64), data.count == byteCount else {
      throw BaiduBrokerProtocolV1Error.invalidOpaqueValue
    }
    return data
  }

  static func canonicalEncoding(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

struct BaiduBrokerStateV1: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  fileprivate let encoded: String

  private init(encoded: String) throws {
    self.encoded = try BaiduBrokerOpaqueValueV1.validate(encoded)
  }

  fileprivate static func generate(using entropy: () throws -> Data) throws -> Self {
    try Self(encoded: BaiduBrokerOpaqueValueV1.generate(using: entropy))
  }

  fileprivate static func parse(_ encoded: String) throws -> Self {
    try Self(encoded: encoded)
  }

  fileprivate func matches(_ other: Self) -> Bool {
    BaiduBrokerOpaqueValueV1.matches(encoded, other.encoded)
  }

  var description: String { "<redacted>" }
  var debugDescription: String { "<redacted>" }
  var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }

  #if SWIFT_PACKAGE
    static func testingOnly(encoded: String) throws -> Self { try Self(encoded: encoded) }
    var testingOnlyEncoded: String { encoded }
  #endif
}

struct BaiduBrokerTicketV1: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  fileprivate let encoded: String

  private init(encoded: String) throws {
    self.encoded = try BaiduBrokerOpaqueValueV1.validate(encoded)
  }

  fileprivate static func parse(_ encoded: String) throws -> Self {
    try Self(encoded: encoded)
  }

  var description: String { "<redacted>" }
  var debugDescription: String { "<redacted>" }
  var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }

  #if SWIFT_PACKAGE
    static func testingOnly(encoded: String) throws -> Self { try Self(encoded: encoded) }
    var testingOnlyEncoded: String { encoded }
  #endif
}

struct BaiduBrokerVerifierV1: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  fileprivate let encoded: String

  private init(encoded: String) throws {
    self.encoded = try BaiduBrokerOpaqueValueV1.validate(encoded)
  }

  fileprivate static func generate(using entropy: () throws -> Data) throws -> Self {
    try Self(encoded: BaiduBrokerOpaqueValueV1.generate(using: entropy))
  }

  var description: String { "<redacted>" }
  var debugDescription: String { "<redacted>" }
  var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }

  #if SWIFT_PACKAGE
    static func testingOnly(encoded: String) throws -> Self { try Self(encoded: encoded) }
    var testingOnlyEncoded: String { encoded }
  #endif
}

struct BaiduBrokerAttemptIDV1: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  fileprivate let encoded: String

  private init(encoded: String) throws {
    self.encoded = try BaiduBrokerOpaqueValueV1.validate(encoded)
  }

  fileprivate static func generate(using entropy: () throws -> Data) throws -> Self {
    try Self(encoded: BaiduBrokerOpaqueValueV1.generate(using: entropy))
  }

  fileprivate static func parse(_ encoded: String) throws -> Self {
    try Self(encoded: encoded)
  }

  fileprivate func matches(_ other: Self) -> Bool {
    BaiduBrokerOpaqueValueV1.matches(encoded, other.encoded)
  }

  var description: String { "<redacted>" }
  var debugDescription: String { "<redacted>" }
  var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }

  #if SWIFT_PACKAGE
    static func testingOnly(encoded: String) throws -> Self { try Self(encoded: encoded) }
    var testingOnlyEncoded: String { encoded }
  #endif
}

struct BaiduBrokerChallengeV1: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  fileprivate let encoded: String

  /// SHA-256 of the verifier's decoded canonical 32 raw bytes, re-encoded as base64url.
  fileprivate init(verifier: BaiduBrokerVerifierV1) throws {
    let verifierData = try BaiduBrokerOpaqueValueV1.decodedData(verifier.encoded)
    encoded = BaiduBrokerOpaqueValueV1.canonicalEncoding(
      Data(SHA256.hash(data: verifierData))
    )
  }

  var description: String { "<redacted>" }
  var debugDescription: String { "<redacted>" }
  var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }

  #if SWIFT_PACKAGE
    var testingOnlyEncoded: String { encoded }
  #endif
}

enum BaiduBrokerAuthorizationFixedErrorV1: String, Sendable {
  case authorizationDenied = "authorization_denied"
  case serverError = "server_error"
  case temporarilyUnavailable = "temporarily_unavailable"
}

enum BaiduBrokerExchangeFixedErrorV1: String, Sendable {
  case ticketInvalid = "ticket_invalid"
  case ticketExpired = "ticket_expired"
  case ticketReplayed = "ticket_replayed"
  case stateMismatch = "state_mismatch"
  case authorizationDenied = "authorization_denied"
  case serverError = "server_error"
  case temporarilyUnavailable = "temporarily_unavailable"
}

/// A small, stable set of outcomes that future UI can explain without exposing protocol details.
/// Suggested actions are labels only; this type never retries or starts a connection by itself.
enum BaiduConnectionFailureV1: Equatable, Sendable {
  case notAuthorized
  case connectionExpired
  case temporarilyUnavailable
  case connectionFailed

  init(authorizationError: BaiduBrokerAuthorizationFixedErrorV1) {
    switch authorizationError {
    case .authorizationDenied:
      self = .notAuthorized
    case .temporarilyUnavailable:
      self = .temporarilyUnavailable
    case .serverError:
      self = .connectionFailed
    }
  }

  init(exchangeError: BaiduBrokerExchangeFixedErrorV1) {
    switch exchangeError {
    case .ticketInvalid, .ticketExpired, .ticketReplayed, .stateMismatch:
      self = .connectionExpired
    case .authorizationDenied:
      self = .notAuthorized
    case .temporarilyUnavailable:
      self = .temporarilyUnavailable
    case .serverError:
      self = .connectionFailed
    }
  }

  var title: String {
    switch self {
    case .notAuthorized:
      "没有连接百度网盘"
    case .connectionExpired:
      "连接已过期"
    case .temporarilyUnavailable:
      "暂时无法连接"
    case .connectionFailed:
      "连接没有完成"
    }
  }

  var message: String {
    switch self {
    case .notAuthorized:
      "这次没有完成连接，笔记没有上传。需要时可以重新连接。"
    case .connectionExpired:
      "这次连接已经失效，笔记没有上传。请重新连接后再试。"
    case .temporarilyUnavailable:
      "百度网盘当前暂时不可用，笔记没有上传。请稍后再试。"
    case .connectionFailed:
      "这次连接没有完成，笔记没有上传。请稍后再试。"
    }
  }

  var suggestedActionTitle: String {
    switch self {
    case .notAuthorized, .connectionExpired:
      "重新连接"
    case .temporarilyUnavailable, .connectionFailed:
      "稍后再试"
    }
  }
}

/// A syntax-only callback parse. Parsing does not establish broker identity or message origin.
struct BaiduBrokerUntrustedParsedCallbackV1: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  fileprivate enum Payload: Sendable {
    case ticket(BaiduBrokerTicketV1)
    case fixedError(BaiduBrokerAuthorizationFixedErrorV1)
  }

  fileprivate let attemptID: BaiduBrokerAttemptIDV1
  fileprivate let state: BaiduBrokerStateV1
  fileprivate let payload: Payload

  static func parse(rawASCIIQuery: String) throws -> Self {
    let fields = try BaiduBrokerRawQueryParserV1.parse(rawASCIIQuery)
    guard fields["schema"] == BaiduBrokerSchemaV1.callback else {
      throw BaiduBrokerProtocolV1Error.unsupportedSchema
    }
    guard let attemptText = fields["attempt"], let stateText = fields["state"] else {
      throw BaiduBrokerProtocolV1Error.invalidQuery
    }
    let attemptID = try BaiduBrokerAttemptIDV1.parse(attemptText)
    let state = try BaiduBrokerStateV1.parse(stateText)

    if Set(fields.keys) == Set(["schema", "attempt", "state", "ticket"]),
      let ticketText = fields["ticket"]
    {
      return try Self(
        attemptID: attemptID,
        state: state,
        payload: .ticket(BaiduBrokerTicketV1.parse(ticketText))
      )
    }
    if Set(fields.keys) == Set(["schema", "attempt", "state", "error"]),
      let errorText = fields["error"]
    {
      guard let fixedError = BaiduBrokerAuthorizationFixedErrorV1(rawValue: errorText) else {
        throw BaiduBrokerProtocolV1Error.invalidFixedError
      }
      return Self(attemptID: attemptID, state: state, payload: .fixedError(fixedError))
    }
    throw BaiduBrokerProtocolV1Error.invalidQuery
  }

  private init(
    attemptID: BaiduBrokerAttemptIDV1,
    state: BaiduBrokerStateV1,
    payload: Payload
  ) {
    self.attemptID = attemptID
    self.state = state
    self.payload = payload
  }

  var description: String { "<redacted>" }
  var debugDescription: String { "<redacted>" }
  var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }
}

private enum BaiduBrokerRawQueryParserV1 {
  static let maximumByteCount = 1_024

  static func parse(_ rawQuery: String) throws -> [String: String] {
    let bytes = Array(rawQuery.utf8)
    guard !bytes.isEmpty, bytes.count <= maximumByteCount else {
      throw bytes.count > maximumByteCount
        ? BaiduBrokerProtocolV1Error.inputTooLarge
        : BaiduBrokerProtocolV1Error.invalidQuery
    }
    guard bytes.allSatisfy({ (0x21...0x7e).contains($0) }),
      !bytes.contains(UInt8(ascii: "%")),
      !bytes.contains(UInt8(ascii: "+")),
      !bytes.contains(UInt8(ascii: "#")),
      !bytes.contains(UInt8(ascii: "?"))
    else {
      throw BaiduBrokerProtocolV1Error.invalidQuery
    }

    let pairs = rawQuery.split(separator: "&", omittingEmptySubsequences: false)
    guard pairs.count == 4 else { throw BaiduBrokerProtocolV1Error.invalidQuery }
    var result: [String: String] = [:]
    for pair in pairs {
      let components = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard components.count == 2, !components[0].isEmpty, !components[1].isEmpty else {
        throw BaiduBrokerProtocolV1Error.invalidQuery
      }
      let key = String(components[0])
      guard result.updateValue(String(components[1]), forKey: key) == nil else {
        throw BaiduBrokerProtocolV1Error.invalidQuery
      }
    }
    return result
  }
}

/// Deterministic start bytes bind the local attempt, state, and verifier challenge.
/// This is a format contract only; atomic server-side binding awaits the real broker design.
struct BaiduBrokerAuthorizationStartRequestV1: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  private let body: Data

  fileprivate init(
    attemptID: BaiduBrokerAttemptIDV1,
    state: BaiduBrokerStateV1,
    challenge: BaiduBrokerChallengeV1
  ) {
    body = Data(
      (#"{"schema":""# + BaiduBrokerSchemaV1.authorizationStart
        + #"","attempt":""# + attemptID.encoded
        + #"","state":""# + state.encoded
        + #"","challenge":""# + challenge.encoded + #""}"#).utf8
    )
  }

  var description: String { "<redacted>" }
  var debugDescription: String { "<redacted>" }
  var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }

  #if SWIFT_PACKAGE
    var testingOnlyBody: Data { body }
  #endif
}

/// Deterministic request bytes are sealed here; shipping code currently has no transport getter.
struct BaiduBrokerExchangeRequestV1: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  private let body: Data

  fileprivate init(
    attemptID: BaiduBrokerAttemptIDV1,
    state: BaiduBrokerStateV1,
    ticket: BaiduBrokerTicketV1,
    verifier: BaiduBrokerVerifierV1
  ) {
    body = Data(
      (#"{"schema":""# + BaiduBrokerSchemaV1.exchangeRequest
        + #"","attempt":""# + attemptID.encoded
        + #"","state":""# + state.encoded
        + #"","ticket":""# + ticket.encoded
        + #"","verifier":""# + verifier.encoded + #""}"#).utf8
    )
  }

  var description: String { "<redacted>" }
  var debugDescription: String { "<redacted>" }
  var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }

  #if SWIFT_PACKAGE
    var testingOnlyBody: Data { body }
  #endif
}

/// A syntax-only response parse. Format checks do not establish broker identity or origin.
struct BaiduBrokerUntrustedParsedExchangeResponseV1: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  fileprivate struct CredentialPayload: Sendable {
    let attemptID: BaiduBrokerAttemptIDV1
    let state: BaiduBrokerStateV1
    let accountScope: BaiduAccountScope
    let accessToken: BaiduAccessToken
    let expiresAt: Date
  }

  fileprivate struct FixedErrorPayload: Sendable {
    let attemptID: BaiduBrokerAttemptIDV1
    let state: BaiduBrokerStateV1
    let error: BaiduBrokerExchangeFixedErrorV1
  }

  fileprivate enum Payload: Sendable {
    case credential(CredentialPayload)
    case fixedError(FixedErrorPayload)
  }

  fileprivate let payload: Payload

  static func parse(data: Data) throws -> Self {
    let fields = try BaiduBrokerStrictStringJSONObjectV1.parse(data)
    guard let schema = fields["schema"] else { throw BaiduBrokerProtocolV1Error.invalidJSON }

    if schema == BaiduBrokerSchemaV1.credentialResponse,
      Set(fields.keys)
        == Set(["schema", "attempt", "state", "brokerBindingID", "accessToken", "expiresAt"])
    {
      guard let attemptText = fields["attempt"],
        let stateText = fields["state"],
        let bindingText = fields["brokerBindingID"],
        let accessTokenText = fields["accessToken"],
        let expiresText = fields["expiresAt"]
      else {
        throw BaiduBrokerProtocolV1Error.invalidJSON
      }
      let attemptID = try BaiduBrokerAttemptIDV1.parse(attemptText)
      let state = try BaiduBrokerStateV1.parse(stateText)
      let bindingID = try BaiduBrokerUUIDV4V1.parse(bindingText)
      let accessToken = try BaiduAccessToken(accessTokenText)
      let expiresAt = try BaiduBrokerUTCSecondV1.parse(expiresText)
      return Self(
        payload: .credential(
          CredentialPayload(
            attemptID: attemptID,
            state: state,
            accountScope: try BaiduAccountScope(brokerBindingID: bindingID),
            accessToken: accessToken,
            expiresAt: expiresAt
          )
        )
      )
    }

    if schema == BaiduBrokerSchemaV1.exchangeError,
      Set(fields.keys) == Set(["schema", "attempt", "state", "error"]),
      let attemptText = fields["attempt"],
      let stateText = fields["state"],
      let errorText = fields["error"]
    {
      guard let fixedError = BaiduBrokerExchangeFixedErrorV1(rawValue: errorText) else {
        throw BaiduBrokerProtocolV1Error.invalidFixedError
      }
      return Self(
        payload: .fixedError(
          FixedErrorPayload(
            attemptID: try BaiduBrokerAttemptIDV1.parse(attemptText),
            state: try BaiduBrokerStateV1.parse(stateText),
            error: fixedError
          )
        )
      )
    }
    guard
      schema == BaiduBrokerSchemaV1.credentialResponse
        || schema == BaiduBrokerSchemaV1.exchangeError
    else {
      throw BaiduBrokerProtocolV1Error.unsupportedSchema
    }
    throw BaiduBrokerProtocolV1Error.invalidJSON
  }

  private init(payload: Payload) {
    self.payload = payload
  }

  var description: String { "<redacted>" }
  var debugDescription: String { "<redacted>" }
  var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }
}

private enum BaiduBrokerUUIDV4V1 {
  static func parse(_ encoded: String) throws -> UUID {
    let bytes = Array(encoded.utf8)
    guard bytes.count == 36,
      encoded == encoded.lowercased(),
      bytes[14] == UInt8(ascii: "4"),
      [UInt8(ascii: "8"), UInt8(ascii: "9"), UInt8(ascii: "a"), UInt8(ascii: "b")]
        .contains(bytes[19]),
      let uuid = UUID(uuidString: encoded),
      uuid.uuidString.lowercased() == encoded
    else {
      throw BaiduBrokerProtocolV1Error.invalidJSON
    }
    return uuid
  }
}

private enum BaiduBrokerUTCSecondV1 {
  static func parse(_ encoded: String) throws -> Date {
    let bytes = Array(encoded.utf8)
    guard bytes.count == 20,
      bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
      bytes[10] == UInt8(ascii: "T"), bytes[13] == UInt8(ascii: ":"),
      bytes[16] == UInt8(ascii: ":"), bytes[19] == UInt8(ascii: "Z"),
      let year = digits(bytes, 0..<4),
      let month = digits(bytes, 5..<7),
      let day = digits(bytes, 8..<10),
      let hour = digits(bytes, 11..<13),
      let minute = digits(bytes, 14..<16),
      let second = digits(bytes, 17..<19),
      (1...9999).contains(year)
    else {
      throw BaiduBrokerProtocolV1Error.invalidExpiration
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = DateComponents(
      calendar: calendar,
      timeZone: calendar.timeZone,
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute,
      second: second
    )
    guard let date = calendar.date(from: components),
      calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        == DateComponents(
          year: year,
          month: month,
          day: day,
          hour: hour,
          minute: minute,
          second: second
        )
    else {
      throw BaiduBrokerProtocolV1Error.invalidExpiration
    }
    return date
  }

  static func validateCredentialLifetime(expiresAt: Date, now: Date) throws {
    let nowValue = now.timeIntervalSinceReferenceDate
    let remaining = expiresAt.timeIntervalSince(now)
    guard nowValue.isFinite, remaining.isFinite, remaining > 300, remaining <= 900 else {
      throw BaiduBrokerProtocolV1Error.invalidExpiration
    }
  }

  private static func digits(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
    var value = 0
    for index in range {
      guard (48...57).contains(bytes[index]) else { return nil }
      value = value * 10 + Int(bytes[index] - 48)
    }
    return value
  }
}

private enum BaiduBrokerStrictStringJSONObjectV1 {
  static let maximumByteCount = 2_048

  static func parse(_ data: Data) throws -> [String: String] {
    guard data.count <= maximumByteCount else {
      throw BaiduBrokerProtocolV1Error.inputTooLarge
    }
    guard !data.starts(with: [0xef, 0xbb, 0xbf]),
      let text = String(data: data, encoding: .utf8)
    else {
      throw BaiduBrokerProtocolV1Error.invalidJSON
    }
    var parser = Parser(text)
    return try parser.parseObject()
  }

  private struct Parser {
    private let scalars: String.UnicodeScalarView
    private var index: String.UnicodeScalarView.Index

    init(_ text: String) {
      scalars = text.unicodeScalars
      index = scalars.startIndex
    }

    mutating func parseObject() throws -> [String: String] {
      skipWhitespace()
      try consume("{")
      skipWhitespace()
      var result: [String: String] = [:]
      if consumeIfPresent("}") {
        skipWhitespace()
        guard index == scalars.endIndex else { throw BaiduBrokerProtocolV1Error.invalidJSON }
        return result
      }

      while true {
        let key = try parseString()
        skipWhitespace()
        try consume(":")
        skipWhitespace()
        let value = try parseString()
        guard result.updateValue(value, forKey: key) == nil else {
          throw BaiduBrokerProtocolV1Error.invalidJSON
        }
        skipWhitespace()
        if consumeIfPresent("}") { break }
        try consume(",")
        skipWhitespace()
      }
      skipWhitespace()
      guard index == scalars.endIndex else { throw BaiduBrokerProtocolV1Error.invalidJSON }
      return result
    }

    private mutating func parseString() throws -> String {
      try consume("\"")
      var output = String.UnicodeScalarView()
      while index != scalars.endIndex {
        let scalar = scalars[index]
        index = scalars.index(after: index)
        if scalar == "\"" { return String(output) }
        guard scalar.value >= 0x20 else { throw BaiduBrokerProtocolV1Error.invalidJSON }
        if scalar != "\\" {
          output.append(scalar)
          continue
        }
        guard index != scalars.endIndex else { throw BaiduBrokerProtocolV1Error.invalidJSON }
        let escaped = scalars[index]
        index = scalars.index(after: index)
        switch escaped {
        case "\"", "\\", "/": output.append(escaped)
        case "b": output.append("\u{0008}")
        case "f": output.append("\u{000c}")
        case "n": output.append("\n")
        case "r": output.append("\r")
        case "t": output.append("\t")
        case "u":
          try appendUnicodeEscape(to: &output)
        default:
          throw BaiduBrokerProtocolV1Error.invalidJSON
        }
      }
      throw BaiduBrokerProtocolV1Error.invalidJSON
    }

    private mutating func appendUnicodeEscape(to output: inout String.UnicodeScalarView) throws {
      let first = try parseHexQuad()
      if (0xd800...0xdbff).contains(first) {
        try consume("\\")
        try consume("u")
        let second = try parseHexQuad()
        guard (0xdc00...0xdfff).contains(second),
          let scalar = UnicodeScalar(
            0x10000 + (UInt32(first - 0xd800) << 10) + UInt32(second - 0xdc00)
          )
        else {
          throw BaiduBrokerProtocolV1Error.invalidJSON
        }
        output.append(scalar)
      } else {
        guard !(0xdc00...0xdfff).contains(first), let scalar = UnicodeScalar(first) else {
          throw BaiduBrokerProtocolV1Error.invalidJSON
        }
        output.append(scalar)
      }
    }

    private mutating func parseHexQuad() throws -> UInt32 {
      var value: UInt32 = 0
      for _ in 0..<4 {
        guard index != scalars.endIndex,
          let digit = hexValue(scalars[index])
        else {
          throw BaiduBrokerProtocolV1Error.invalidJSON
        }
        value = value * 16 + digit
        index = scalars.index(after: index)
      }
      return value
    }

    private func hexValue(_ scalar: Unicode.Scalar) -> UInt32? {
      switch scalar.value {
      case 48...57: scalar.value - 48
      case 65...70: scalar.value - 55
      case 97...102: scalar.value - 87
      default: nil
      }
    }

    private mutating func skipWhitespace() {
      while index != scalars.endIndex,
        [" ", "\t", "\n", "\r"].contains(scalars[index])
      {
        index = scalars.index(after: index)
      }
    }

    private mutating func consume(_ expected: Unicode.Scalar) throws {
      guard consumeIfPresent(expected) else { throw BaiduBrokerProtocolV1Error.invalidJSON }
    }

    private mutating func consumeIfPresent(_ expected: Unicode.Scalar) -> Bool {
      guard index != scalars.endIndex, scalars[index] == expected else { return false }
      index = scalars.index(after: index)
      return true
    }
  }
}

/// The current shipping target has no constructor for this origin-bound wrapper.
/// A raw syntax parse alone must never be promoted into this type.
struct BaiduBrokerOriginBoundCallbackV1: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  fileprivate let parsed: BaiduBrokerUntrustedParsedCallbackV1

  private init(parsed: BaiduBrokerUntrustedParsedCallbackV1) {
    self.parsed = parsed
  }

  var description: String { "<redacted>" }
  var debugDescription: String { "<redacted>" }
  var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }

  #if SWIFT_PACKAGE
    static func testingOnly(rawASCIIQuery: String) throws -> Self {
      Self(parsed: try BaiduBrokerUntrustedParsedCallbackV1.parse(rawASCIIQuery: rawASCIIQuery))
    }
  #endif
}

/// The current shipping target has no constructor for this origin-bound wrapper.
/// A raw syntax parse alone must never be promoted into this type.
struct BaiduBrokerOriginBoundExchangeResponseV1: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  fileprivate let parsed: BaiduBrokerUntrustedParsedExchangeResponseV1

  private init(parsed: BaiduBrokerUntrustedParsedExchangeResponseV1) {
    self.parsed = parsed
  }

  var description: String { "<redacted>" }
  var debugDescription: String { "<redacted>" }
  var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }

  #if SWIFT_PACKAGE
    static func testingOnly(data: Data) throws -> Self {
      Self(parsed: try BaiduBrokerUntrustedParsedExchangeResponseV1.parse(data: data))
    }
  #endif
}

struct BaiduBrokerAuthorizationAttemptV1: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  fileprivate let attemptID: BaiduBrokerAttemptIDV1
  fileprivate let state: BaiduBrokerStateV1
  fileprivate let verifier: BaiduBrokerVerifierV1
  fileprivate let challenge: BaiduBrokerChallengeV1
  fileprivate let startRequest: BaiduBrokerAuthorizationStartRequestV1

  var description: String { "<redacted>" }
  var debugDescription: String { "<redacted>" }
  var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }

  #if SWIFT_PACKAGE
    var testingOnlyAttemptID: BaiduBrokerAttemptIDV1 { attemptID }
    var testingOnlyState: BaiduBrokerStateV1 { state }
    var testingOnlyVerifier: BaiduBrokerVerifierV1 { verifier }
    var testingOnlyChallenge: BaiduBrokerChallengeV1 { challenge }
    var testingOnlyStartRequest: BaiduBrokerAuthorizationStartRequestV1 { startRequest }
  #endif
}

enum BaiduBrokerAuthorizationPhaseV1: Equatable, Sendable {
  case idle
  case awaitingOriginBoundCallback
  case awaitingExchangeDispatch
  case awaitingOriginBoundExchangeResponse
  case terminal
}

enum BaiduBrokerAuthorizationTerminalV1: Equatable, Sendable {
  case none
  case cancelled
  case attemptExpired
  case exchangeWindowExpired
  case authorizationFixedError(BaiduConnectionFailureV1)
  case exchangeFixedError(BaiduConnectionFailureV1)
  /// The payload passed local format checks only; broker authenticity remains out of scope.
  case parsedCredentialFormatAccepted
  case protocolFailure
}

struct BaiduBrokerAuthorizationSnapshotV1: Equatable, Sendable {
  let generation: UInt64
  let phase: BaiduBrokerAuthorizationPhaseV1
  let terminal: BaiduBrokerAuthorizationTerminalV1
}

enum BaiduBrokerCallbackAcceptanceV1: Equatable, Sendable {
  case exchangeReady
  case endedWithFixedError(BaiduConnectionFailureV1)
}

enum BaiduBrokerExchangeAcceptanceV1: Equatable, Sendable {
  /// The payload passed local format checks only; broker authenticity remains out of scope.
  case parsedCredentialFormatAccepted
  case endedWithFixedError(BaiduConnectionFailureV1)
}

/// Process-wide replay memory. It never evicts: reaching either bound fails closed.
/// Restart-safe replay prevention still requires atomic single-use enforcement by the broker.
final class BaiduBrokerReplayAuthorityV1: @unchecked Sendable {
  private static let maximumTicketFingerprintCount = 256
  private static let maximumAttemptBindingFingerprintCount = 512
  fileprivate static let production = BaiduBrokerReplayAuthorityV1()
  private static let attemptBindingDomain = Data(
    "inknotes.baidu-broker.attempt-binding.v1\u{0000}".utf8
  )

  private let lock = NSLock()
  private var ticketFingerprints = Set<Data>()
  private var attemptBindingFingerprints = Set<Data>()

  private init() {}

  fileprivate func registerTicket(_ ticket: BaiduBrokerTicketV1) throws {
    let fingerprint = Data(
      SHA256.hash(data: try BaiduBrokerOpaqueValueV1.decodedData(ticket.encoded))
    )
    lock.lock()
    defer { lock.unlock() }
    guard !ticketFingerprints.contains(fingerprint) else {
      throw BaiduBrokerProtocolV1Error.ticketReplay
    }
    guard ticketFingerprints.count < Self.maximumTicketFingerprintCount else {
      throw BaiduBrokerProtocolV1Error.ticketReplayCapacityReached
    }
    ticketFingerprints.insert(fingerprint)
  }

  fileprivate func registerAttemptBinding(
    attemptID: BaiduBrokerAttemptIDV1,
    state: BaiduBrokerStateV1,
    challenge: BaiduBrokerChallengeV1
  ) throws {
    var material = Self.attemptBindingDomain
    material.append(try BaiduBrokerOpaqueValueV1.decodedData(attemptID.encoded))
    material.append(try BaiduBrokerOpaqueValueV1.decodedData(state.encoded))
    material.append(try BaiduBrokerOpaqueValueV1.decodedData(challenge.encoded))
    let fingerprint = Data(SHA256.hash(data: material))

    lock.lock()
    defer { lock.unlock() }
    guard !attemptBindingFingerprints.contains(fingerprint) else {
      throw BaiduBrokerProtocolV1Error.attemptBindingReplay
    }
    guard attemptBindingFingerprints.count < Self.maximumAttemptBindingFingerprintCount else {
      throw BaiduBrokerProtocolV1Error.attemptBindingCapacityReached
    }
    attemptBindingFingerprints.insert(fingerprint)
  }

  #if SWIFT_PACKAGE
    static func testingOnly() -> BaiduBrokerReplayAuthorityV1 {
      BaiduBrokerReplayAuthorityV1()
    }
  #endif
}

actor BaiduBrokerAuthorizationSessionV1 {
  private static let attemptLifetime: Duration = .seconds(600)
  private static let exchangeWindowLifetime: Duration = .seconds(60)

  private struct Context: Sendable {
    let attemptID: BaiduBrokerAttemptIDV1
    let state: BaiduBrokerStateV1
    let verifier: BaiduBrokerVerifierV1
    let challenge: BaiduBrokerChallengeV1
    let monotonicAnchor: ContinuousClock.Instant
    let wallAnchor: Date
    let attemptDeadline: ContinuousClock.Instant
  }

  private enum Active: Sendable {
    case awaitingCallback(Context)
    case awaitingExchange(
      Context,
      BaiduBrokerTicketV1,
      exchangeWindowDeadline: ContinuousClock.Instant,
      dispatched: Bool
    )
  }

  private let monotonicNow: @Sendable () -> ContinuousClock.Instant
  private let wallNow: @Sendable () -> Date
  private let entropy: @Sendable () throws -> Data
  private let replayAuthority: BaiduBrokerReplayAuthorityV1
  private var active: Active?
  private var generation: UInt64 = 0
  private var terminal: BaiduBrokerAuthorizationTerminalV1 = .none
  private var maximumObservedMonotonicInstant: ContinuousClock.Instant?
  private var maximumObservedWallTime: Date?

  init() {
    let clock = ContinuousClock()
    monotonicNow = { clock.now }
    wallNow = { Date() }
    entropy = { try BaiduBrokerOpaqueValueV1.secureRandomData() }
    replayAuthority = .production
  }

  #if SWIFT_PACKAGE
    init(
      testingOnlyMonotonicNow: @escaping @Sendable () -> ContinuousClock.Instant,
      testingOnlyWallNow: @escaping @Sendable () -> Date,
      testingOnlyEntropy: @escaping @Sendable () throws -> Data = {
        try BaiduBrokerOpaqueValueV1.secureRandomData()
      },
      testingOnlyReplayAuthority: BaiduBrokerReplayAuthorityV1
    ) {
      monotonicNow = testingOnlyMonotonicNow
      wallNow = testingOnlyWallNow
      entropy = testingOnlyEntropy
      replayAuthority = testingOnlyReplayAuthority
    }
  #endif

  func begin() throws -> BaiduBrokerAuthorizationAttemptV1 {
    guard active == nil else { throw BaiduBrokerProtocolV1Error.activeAttemptExists }

    do {
      let (nextGeneration, overflow) = generation.addingReportingOverflow(1)
      guard !overflow else { throw BaiduBrokerProtocolV1Error.generationExhausted }
      let startedAt = monotonicNow()
      let wallAnchor = try readRawWallTime()
      let attemptID = try BaiduBrokerAttemptIDV1.generate(using: entropy)
      let state = try BaiduBrokerStateV1.generate(using: entropy)
      let verifier = try BaiduBrokerVerifierV1.generate(using: entropy)
      guard Set([attemptID.encoded, state.encoded, verifier.encoded]).count == 3 else {
        throw BaiduBrokerProtocolV1Error.entropyCollision
      }
      let challenge = try BaiduBrokerChallengeV1(verifier: verifier)
      let startRequest = BaiduBrokerAuthorizationStartRequestV1(
        attemptID: attemptID,
        state: state,
        challenge: challenge
      )
      let context = Context(
        attemptID: attemptID,
        state: state,
        verifier: verifier,
        challenge: challenge,
        monotonicAnchor: startedAt,
        wallAnchor: wallAnchor,
        attemptDeadline: startedAt.advanced(by: Self.attemptLifetime)
      )
      try replayAuthority.registerAttemptBinding(
        attemptID: attemptID,
        state: state,
        challenge: challenge
      )

      generation = nextGeneration
      terminal = .none
      maximumObservedMonotonicInstant = startedAt
      maximumObservedWallTime = wallAnchor
      active = .awaitingCallback(context)
      return BaiduBrokerAuthorizationAttemptV1(
        attemptID: attemptID,
        state: state,
        verifier: verifier,
        challenge: challenge,
        startRequest: startRequest
      )
    } catch {
      failProtocol()
      throw error
    }
  }

  func cancel() {
    guard active != nil else { return }
    active = nil
    terminal = .cancelled
  }

  func snapshot() -> BaiduBrokerAuthorizationSnapshotV1 {
    let phase: BaiduBrokerAuthorizationPhaseV1
    switch active {
    case .none:
      phase = terminal == .none ? .idle : .terminal
    case .awaitingCallback:
      phase = .awaitingOriginBoundCallback
    case .awaitingExchange(_, _, _, let dispatched):
      phase = dispatched ? .awaitingOriginBoundExchangeResponse : .awaitingExchangeDispatch
    }
    return BaiduBrokerAuthorizationSnapshotV1(
      generation: generation,
      phase: phase,
      terminal: terminal
    )
  }

  func acceptOriginBoundCallback(
    _ callback: BaiduBrokerOriginBoundCallbackV1
  ) throws -> BaiduBrokerCallbackAcceptanceV1 {
    guard let current = active else { throw inactiveError() }
    guard case .awaitingCallback(let context) = current else {
      throw BaiduBrokerProtocolV1Error.callbackAlreadyConsumed
    }
    guard context.attemptID.matches(callback.parsed.attemptID) else {
      throw BaiduBrokerProtocolV1Error.attemptMismatch
    }
    let acceptedAt = monotonicNow()
    try requireAttemptOpen(context, at: acceptedAt)
    guard context.state.matches(callback.parsed.state) else {
      failProtocol()
      throw BaiduBrokerProtocolV1Error.stateMismatch
    }
    _ = try observeWallTimeOrFail(context: context, at: acceptedAt)

    switch callback.parsed.payload {
    case .ticket(let ticket):
      try register(ticket: ticket, for: context)
      let ticketDeadline = acceptedAt.advanced(by: Self.exchangeWindowLifetime)
      let exchangeWindowDeadline = min(context.attemptDeadline, ticketDeadline)
      active = .awaitingExchange(
        context,
        ticket,
        exchangeWindowDeadline: exchangeWindowDeadline,
        dispatched: false
      )
      return .exchangeReady
    case .fixedError(let error):
      let failure = BaiduConnectionFailureV1(authorizationError: error)
      active = nil
      terminal = .authorizationFixedError(failure)
      return .endedWithFixedError(failure)
    }
  }

  func makeExchangeRequest() throws -> BaiduBrokerExchangeRequestV1 {
    guard let current = active else { throw inactiveError() }
    guard
      case .awaitingExchange(
        let context,
        let ticket,
        let exchangeWindowDeadline,
        let dispatched
      ) = current
    else {
      throw BaiduBrokerProtocolV1Error.exchangeNotDispatched
    }
    let dispatchAt = monotonicNow()
    try requireExchangeWindowOpen(exchangeWindowDeadline, at: dispatchAt)
    _ = try observeWallTimeOrFail(context: context, at: dispatchAt)
    guard !dispatched else { throw BaiduBrokerProtocolV1Error.ticketAlreadyDispatched }
    let request = BaiduBrokerExchangeRequestV1(
      attemptID: context.attemptID,
      state: context.state,
      ticket: ticket,
      verifier: context.verifier
    )
    active = .awaitingExchange(
      context,
      ticket,
      exchangeWindowDeadline: exchangeWindowDeadline,
      dispatched: true
    )
    return request
  }

  func acceptOriginBoundExchangeResponse(
    _ response: BaiduBrokerOriginBoundExchangeResponseV1
  ) throws -> BaiduBrokerExchangeAcceptanceV1 {
    guard let current = active else { throw inactiveError() }
    let context = context(from: current)
    let binding = responseBinding(response)
    guard context.attemptID.matches(binding.attemptID) else {
      throw BaiduBrokerProtocolV1Error.attemptMismatch
    }
    guard context.state.matches(binding.state) else {
      failProtocol()
      throw BaiduBrokerProtocolV1Error.stateMismatch
    }
    guard
      case .awaitingExchange(_, _, let exchangeWindowDeadline, let dispatched) = current,
      dispatched
    else {
      failProtocol()
      throw BaiduBrokerProtocolV1Error.exchangeNotDispatched
    }
    let responseAt = monotonicNow()
    try requireExchangeWindowOpen(exchangeWindowDeadline, at: responseAt)
    let conservativeWallNow = try observeWallTimeOrFail(context: context, at: responseAt)

    switch response.parsed.payload {
    case .credential(let payload):
      do {
        try BaiduBrokerUTCSecondV1.validateCredentialLifetime(
          expiresAt: payload.expiresAt,
          now: conservativeWallNow
        )
      } catch {
        failProtocol()
        throw error
      }
      _ = payload.accountScope
      _ = payload.accessToken
      active = nil
      terminal = .parsedCredentialFormatAccepted
      return .parsedCredentialFormatAccepted
    case .fixedError(let payload):
      let failure = BaiduConnectionFailureV1(exchangeError: payload.error)
      active = nil
      terminal = .exchangeFixedError(failure)
      return .endedWithFixedError(failure)
    }
  }

  private func context(from active: Active) -> Context {
    switch active {
    case .awaitingCallback(let context): context
    case .awaitingExchange(let context, _, _, _): context
    }
  }

  private func responseBinding(
    _ response: BaiduBrokerOriginBoundExchangeResponseV1
  ) -> (attemptID: BaiduBrokerAttemptIDV1, state: BaiduBrokerStateV1) {
    switch response.parsed.payload {
    case .credential(let payload): (payload.attemptID, payload.state)
    case .fixedError(let payload): (payload.attemptID, payload.state)
    }
  }

  private func requireAttemptOpen(
    _ context: Context,
    at now: ContinuousClock.Instant
  ) throws {
    guard now < context.attemptDeadline else {
      active = nil
      terminal = .attemptExpired
      throw BaiduBrokerProtocolV1Error.attemptExpired
    }
  }

  private func requireExchangeWindowOpen(
    _ deadline: ContinuousClock.Instant,
    at now: ContinuousClock.Instant
  ) throws {
    guard now < deadline else {
      active = nil
      terminal = .exchangeWindowExpired
      throw BaiduBrokerProtocolV1Error.exchangeWindowExpired
    }
  }

  private func register(ticket: BaiduBrokerTicketV1, for context: Context) throws {
    let reservedValues = [
      context.attemptID.encoded,
      context.state.encoded,
      context.verifier.encoded,
      context.challenge.encoded,
    ]
    guard
      !reservedValues.contains(where: {
        BaiduBrokerOpaqueValueV1.matches(ticket.encoded, $0)
      })
    else {
      failProtocol()
      throw BaiduBrokerProtocolV1Error.invalidTicket
    }

    do {
      try replayAuthority.registerTicket(ticket)
    } catch {
      failProtocol()
      throw error
    }
  }

  /// Prevents rollback from extending expiry within this authorization session only.
  /// The absolute correctness of the initial wall anchor is not established here.
  private func observeWallTime(
    context: Context,
    at monotonicInstant: ContinuousClock.Instant
  ) throws -> Date {
    let rawWall = try readRawWallTime()
    let previousMonotonic = maximumObservedMonotonicInstant ?? context.monotonicAnchor
    guard monotonicInstant >= previousMonotonic else {
      throw BaiduBrokerProtocolV1Error.monotonicClockInvalid
    }
    let elapsed = context.monotonicAnchor.duration(to: monotonicInstant)
    guard elapsed >= .zero else {
      throw BaiduBrokerProtocolV1Error.monotonicClockInvalid
    }
    let components = elapsed.components
    let elapsedSeconds =
      Double(components.seconds)
      + Double(components.attoseconds) / 1_000_000_000_000_000_000
    guard elapsedSeconds.isFinite else {
      throw BaiduBrokerProtocolV1Error.monotonicClockInvalid
    }
    let projectedWall = context.wallAnchor.addingTimeInterval(elapsedSeconds)
    guard projectedWall.timeIntervalSinceReferenceDate.isFinite else {
      throw BaiduBrokerProtocolV1Error.monotonicClockInvalid
    }
    let previousMaximum = maximumObservedWallTime ?? context.wallAnchor
    let conservative = max(max(rawWall, previousMaximum), projectedWall)
    maximumObservedMonotonicInstant = monotonicInstant
    maximumObservedWallTime = conservative
    return conservative
  }

  private func readRawWallTime() throws -> Date {
    let observed = wallNow()
    guard observed.timeIntervalSinceReferenceDate.isFinite else {
      throw BaiduBrokerProtocolV1Error.invalidExpiration
    }
    return observed
  }

  private func observeWallTimeOrFail(
    context: Context,
    at monotonicInstant: ContinuousClock.Instant
  ) throws -> Date {
    do {
      return try observeWallTime(context: context, at: monotonicInstant)
    } catch {
      failProtocol()
      throw error
    }
  }

  private func failProtocol() {
    active = nil
    terminal = .protocolFailure
  }

  private func inactiveError() -> BaiduBrokerProtocolV1Error {
    switch terminal {
    case .none: .noActiveAttempt
    case .cancelled: .cancelled
    case .attemptExpired: .attemptExpired
    case .exchangeWindowExpired: .exchangeWindowExpired
    case .authorizationFixedError(_), .exchangeFixedError(_), .parsedCredentialFormatAccepted,
      .protocolFailure:
      .lateResponse
    }
  }
}
