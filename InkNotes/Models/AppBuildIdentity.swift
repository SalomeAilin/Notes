import Foundation

struct AppBuildIdentity: Equatable, Sendable {
  let version: String?
  let build: String?

  init(infoDictionary: [String: Any]?) {
    version = Self.normalized(infoDictionary?["CFBundleShortVersionString"] as? String)
    build = Self.normalized(infoDictionary?["CFBundleVersion"] as? String)
  }

  static func current(bundle: Bundle = .main) -> AppBuildIdentity {
    AppBuildIdentity(infoDictionary: bundle.infoDictionary)
  }

  var displayText: String {
    switch (version, build) {
    case (.some(let version), .some(let build)):
      "版本 \(version)（构建 \(build)）"
    case (.some(let version), .none):
      "版本 \(version)"
    case (.none, .some(let build)):
      "构建 \(build)"
    case (.none, .none):
      "版本信息不可用"
    }
  }

  private static func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }
}
