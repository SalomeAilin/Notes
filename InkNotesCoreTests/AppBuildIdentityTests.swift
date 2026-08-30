import Foundation
import Testing

@testable import InkNotesCore

@Suite("App build identity")
struct AppBuildIdentityTests {
  @Test("Version and build are trimmed and formatted together")
  func completeIdentity() {
    let identity = AppBuildIdentity(infoDictionary: [
      "CFBundleShortVersionString": " 0.2.0 ",
      "CFBundleVersion": " 3\n",
    ])

    #expect(identity.version == "0.2.0")
    #expect(identity.build == "3")
    #expect(identity.displayText == "版本 0.2.0（构建 3）")
  }

  @Test("Partial metadata remains useful")
  func partialIdentity() {
    #expect(
      AppBuildIdentity(
        infoDictionary: ["CFBundleShortVersionString": "0.2.0"]
      ).displayText == "版本 0.2.0"
    )
    #expect(
      AppBuildIdentity(
        infoDictionary: ["CFBundleVersion": "3"]
      ).displayText == "构建 3"
    )
  }

  @Test("Missing, blank, and non-string metadata fail to a neutral label")
  func unavailableIdentity() {
    let unavailableDictionaries: [[String: Any]?] = [
      nil,
      [:],
      ["CFBundleShortVersionString": " \n", "CFBundleVersion": "\t"],
      ["CFBundleShortVersionString": 2, "CFBundleVersion": 3],
    ]

    for dictionary in unavailableDictionaries {
      #expect(AppBuildIdentity(infoDictionary: dictionary).displayText == "版本信息不可用")
    }
  }
}
