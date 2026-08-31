import Foundation

enum BaiduAccountCredentialError: LocalizedError, Equatable, Sendable {
  case invalidBrokerBindingID
  case invalidExpiration
  case unavailableForRequest

  var errorDescription: String? {
    switch self {
    case .invalidBrokerBindingID:
      "百度网盘账号绑定标识无效，已停止上传。"
    case .invalidExpiration:
      "百度网盘访问凭据的到期信息无效，已停止操作。"
    case .unavailableForRequest:
      "百度网盘访问凭据已过期或剩余有效期不足，请重新连接。"
    }
  }
}

enum BaiduCredentialUsePolicy {
  /// Leaves room for the longest current request timeout plus scheduling and clock drift.
  static let minimumRequestRemainingLifetime: TimeInterval = 5 * 60
}

/// An opaque, non-secret capability issued and restored by the future credential broker.
///
/// This value deliberately has no initializer from an access token, token digest, UInfo `uk`,
/// account name, or avatar. A UUID cannot prove broker provenance inside this module, so App,
/// Views, and Stores remain forbidden from constructing this type by the security contract tests.
struct BaiduAccountScope: Hashable, Codable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  private static let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

  private let brokerBindingID: UUID

  init(brokerBindingID: UUID) throws {
    guard brokerBindingID != Self.zeroUUID else {
      throw BaiduAccountCredentialError.invalidBrokerBindingID
    }
    self.brokerBindingID = brokerBindingID
  }

  var persistenceKey: String {
    brokerBindingID.uuidString.lowercased()
  }

  var description: String { "<redacted>" }
  var debugDescription: String { "<redacted>" }
  var customMirror: Mirror {
    Mirror(self, children: EmptyCollection<Mirror.Child>())
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let encoded = try container.decode(String.self)
    guard let bindingID = UUID(uuidString: encoded),
      bindingID != Self.zeroUUID,
      encoded == bindingID.uuidString.lowercased()
    else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Invalid account scope"
      )
    }
    brokerBindingID = bindingID
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(persistenceKey)
  }
}

/// Keeps the short-lived access token inseparable from the broker-issued account scope.
struct BaiduAccountBoundCredential: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  let accountScope: BaiduAccountScope
  private let accessToken: BaiduAccessToken
  private let expiresAt: Date

  private init(
    accountScope: BaiduAccountScope,
    accessToken: BaiduAccessToken,
    expiresAt: Date
  ) throws {
    guard expiresAt.timeIntervalSinceReferenceDate.isFinite else {
      throw BaiduAccountCredentialError.invalidExpiration
    }
    self.accountScope = accountScope
    self.accessToken = accessToken
    self.expiresAt = expiresAt
  }

  #if SWIFT_PACKAGE
    /// Test-harness-only construction. The shipping Xcode target has no credential issuer.
    static func testingOnly(
      accountScope: BaiduAccountScope,
      accessToken: BaiduAccessToken,
      expiresAt: Date
    ) throws -> Self {
      try Self(
        accountScope: accountScope,
        accessToken: accessToken,
        expiresAt: expiresAt
      )
    }
  #endif

  func requestAccessToken(at now: Date) throws -> BaiduAccessToken {
    let nowValue = now.timeIntervalSinceReferenceDate
    let remainingLifetime = expiresAt.timeIntervalSince(now)
    guard nowValue.isFinite,
      remainingLifetime.isFinite,
      remainingLifetime > BaiduCredentialUsePolicy.minimumRequestRemainingLifetime
    else {
      throw BaiduAccountCredentialError.unavailableForRequest
    }
    return accessToken
  }

  var description: String { "<redacted>" }
  var debugDescription: String { "<redacted>" }
  var customMirror: Mirror {
    Mirror(self, children: EmptyCollection<Mirror.Child>())
  }
}
