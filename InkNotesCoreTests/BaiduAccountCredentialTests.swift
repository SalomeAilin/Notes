import Foundation
import Testing

@testable import InkNotesCore

@Suite("Baidu account-bound credential")
struct BaiduAccountCredentialTests {
  @Test("Account scope has canonical persistence and fully redacted presentation")
  func scopePersistenceAndPresentationAreSafe() throws {
    let bindingID = UUID(uuidString: "D0000000-0000-0000-0000-000000000001")!
    let bindingText = bindingID.uuidString.lowercased()
    let secret = "credential-test-secret"
    let scope = try BaiduAccountScope(brokerBindingID: bindingID)
    let credential = BaiduAccountBoundCredential.testingOnly(
      accountScope: scope,
      accessToken: try BaiduAccessToken(secret)
    )

    #expect(try JSONEncoder().encode(scope) == Data("\"\(bindingText)\"".utf8))
    #expect(
      try JSONDecoder().decode(BaiduAccountScope.self, from: Data("\"\(bindingText)\"".utf8))
        == scope)
    #expect(String(describing: scope) == "<redacted>")
    #expect(String(reflecting: scope) == "<redacted>")
    #expect(String(describing: credential) == "<redacted>")
    #expect(String(reflecting: credential) == "<redacted>")
    #expect(Array(Mirror(reflecting: scope).children).isEmpty)
    #expect(Array(Mirror(reflecting: credential).children).isEmpty)

    var rendered = ""
    dump([scope], to: &rendered)
    dump(credential, to: &rendered)
    #expect(!rendered.contains(bindingText))
    #expect(!rendered.contains(secret))
  }

  @Test("Malformed, uppercase, and zero broker binding IDs fail closed")
  func invalidBindingIDsAreRejected() throws {
    let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    #expect(throws: BaiduAccountCredentialError.invalidBrokerBindingID) {
      try BaiduAccountScope(brokerBindingID: zeroUUID)
    }

    for encoded in [
      "\"D0000000-0000-0000-0000-000000000001\"",
      "\"00000000-0000-0000-0000-000000000000\"",
      "\"not-a-binding-id\"",
      "1",
    ] {
      #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(BaiduAccountScope.self, from: Data(encoded.utf8))
      }
    }
  }
}
