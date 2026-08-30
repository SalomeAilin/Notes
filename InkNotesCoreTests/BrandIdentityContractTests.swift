import Foundation
import Testing

@Suite("Internal brand identity contract")
struct BrandIdentityContractTests {
  private let expectedDisplayName = "InkNotes Dev"
  private let expectedBundleIdentifier = "com.salomeailin.InkNotes"
  private let retiredDisplayNames = ["墨记", "墨記", "墨计", "墨計"]

  @Test("The buildable app uses a neutral internal display name")
  func internalDisplayNameIsExplicit() throws {
    let plistURL = repositoryRootURL().appendingPathComponent("InkNotes/Info.plist")
    let plistData = try Data(contentsOf: plistURL)
    let plist = try #require(
      try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
        as? [String: Any]
    )

    #expect(plist["CFBundleDisplayName"] as? String == expectedDisplayName)
    #expect(!retiredDisplayNames.contains(expectedDisplayName))
  }

  @Test("The existing app bundle identity stays unchanged")
  func bundleIdentifierRemainsStable() throws {
    let projectURL = repositoryRootURL().appendingPathComponent(
      "InkNotes.xcodeproj/project.pbxproj"
    )
    let projectData = try Data(contentsOf: projectURL)
    let project = try #require(
      try PropertyListSerialization.propertyList(from: projectData, options: [], format: nil)
        as? [String: Any]
    )
    let configurations = try mainAppBuildConfigurations(in: project)

    #expect(configurations.map(\.name).sorted() == ["Debug", "Release"])
    #expect(configurations.allSatisfy { $0.bundleIdentifier == expectedBundleIdentifier })
  }

  @Test("Shipping inputs contain no retired display-name aliases")
  func shippingInputsContainNoRetiredNames() throws {
    let shippingRoot = repositoryRootURL().appendingPathComponent("InkNotes", isDirectory: true)
    let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]
    let enumerator = try #require(
      FileManager.default.enumerator(
        at: shippingRoot,
        includingPropertiesForKeys: Array(resourceKeys),
        options: [.skipsHiddenFiles]
      )
    )
    let encodings: [String.Encoding] = [.utf8, .utf16LittleEndian, .utf16BigEndian]

    for case let fileURL as URL in enumerator {
      let values = try fileURL.resourceValues(forKeys: resourceKeys)
      guard values.isRegularFile == true else { continue }
      let data = try Data(contentsOf: fileURL)
      for name in retiredDisplayNames {
        for encoding in encodings {
          let marker = try #require(name.data(using: encoding))
          #expect(
            data.range(of: marker) == nil,
            "Retired display name found in \(fileURL.lastPathComponent)"
          )
        }
      }
    }
  }

  @Test("The retired-name scanner recognizes every protected encoding")
  func retiredNameScannerNegativeControls() throws {
    let encodings: [String.Encoding] = [.utf8, .utf16LittleEndian, .utf16BigEndian]

    for name in retiredDisplayNames {
      for encoding in encodings {
        let marker = try #require(name.data(using: encoding))
        var fixture = Data([0x00, 0xFF])
        fixture.append(marker)
        fixture.append(contentsOf: [0xFF, 0x00])
        #expect(fixture.range(of: marker) != nil)
      }
    }
  }

  private func repositoryRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private struct AppBuildConfiguration: Equatable {
    let name: String
    let bundleIdentifier: String?
  }

  private enum ProjectContractError: Error, Equatable {
    case malformedProjectGraph
    case mainAppTargetCount(Int)
    case duplicateConfiguration(String)
  }

  private func mainAppBuildConfigurations(
    in project: [String: Any]
  ) throws -> [AppBuildConfiguration] {
    guard let rootObjectID = project["rootObject"] as? String,
      let objects = project["objects"] as? [String: Any],
      let rootProject = objects[rootObjectID] as? [String: Any],
      rootProject["isa"] as? String == "PBXProject",
      let targetIDs = rootProject["targets"] as? [String]
    else {
      throw ProjectContractError.malformedProjectGraph
    }

    let mountedTargets = try targetIDs.map { targetID in
      guard let target = objects[targetID] as? [String: Any] else {
        throw ProjectContractError.malformedProjectGraph
      }
      return target
    }
    let mainAppTargets = mountedTargets.filter {
      $0["isa"] as? String == "PBXNativeTarget"
        && $0["name"] as? String == "InkNotes"
        && $0["productType"] as? String == "com.apple.product-type.application"
    }
    guard mainAppTargets.count == 1, let mainAppTarget = mainAppTargets.first else {
      throw ProjectContractError.mainAppTargetCount(mainAppTargets.count)
    }
    guard let configurationListID = mainAppTarget["buildConfigurationList"] as? String,
      let configurationList = objects[configurationListID] as? [String: Any],
      configurationList["isa"] as? String == "XCConfigurationList",
      let configurationIDs = configurationList["buildConfigurations"] as? [String],
      !configurationIDs.isEmpty
    else {
      throw ProjectContractError.malformedProjectGraph
    }

    var names = Set<String>()
    return try configurationIDs.map { configurationID in
      guard let configuration = objects[configurationID] as? [String: Any],
        configuration["isa"] as? String == "XCBuildConfiguration",
        let name = configuration["name"] as? String,
        let settings = configuration["buildSettings"] as? [String: Any]
      else {
        throw ProjectContractError.malformedProjectGraph
      }
      guard names.insert(name).inserted else {
        throw ProjectContractError.duplicateConfiguration(name)
      }
      return AppBuildConfiguration(
        name: name,
        bundleIdentifier: settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String
      )
    }
  }
}
