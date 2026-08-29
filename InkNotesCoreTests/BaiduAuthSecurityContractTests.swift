import Foundation
import Testing

@Suite("Baidu OAuth release boundary")
struct BaiduAuthSecurityContractTests {
  @Test("Shipping inputs contain no client secret, direct OAuth endpoint, or placeholder broker")
  func shippingInputsRemainFailClosed() throws {
    let rootURL = try repositoryRootURL()
    let inputURLs = try shippingInputURLs(repositoryRoot: rootURL)

    for inputURL in inputURLs {
      let contents = try String(contentsOf: inputURL, encoding: .utf8)
      let findings = securityFindings(in: contents)
      if !findings.isEmpty {
        let path = relativePath(inputURL, repositoryRoot: rootURL)
        Issue.record(
          "Forbidden OAuth release input \(findings.map(\.rawValue).sorted()) in \(path)"
        )
      }
    }
  }

  @Test("Source metadata registers no callback scheme or background transfer capability")
  func sourceMetadataHasNoUnapprovedCapabilities() throws {
    let rootURL = try repositoryRootURL()
    let plistURL = rootURL.appendingPathComponent("InkNotes/Info.plist")
    let plistData = try Data(contentsOf: plistURL)
    let plist = try #require(
      try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
        as? [String: Any]
    )

    #expect(plist["CFBundleURLTypes"] == nil)
    #expect(plist["CFBundleURLSchemes"] == nil)
    #expect(plist["UIBackgroundModes"] == nil)
    #expect(plist["BGTaskSchedulerPermittedIdentifiers"] == nil)
  }

  @Test("Baidu implementation remains quarantined from app, views, and stores")
  func uploadCoreRemainsQuarantined() throws {
    let rootURL = try repositoryRootURL()
    let allowedBaiduSwiftFiles = Set([
      "InkNotes/Models/BaiduNetdiskBackup.swift",
      "InkNotes/Networking/BaiduBackupUploadCoordinator.swift",
      "InkNotes/Networking/BaiduHTTPTransport.swift",
      "InkNotes/Networking/BaiduNetdiskBackupUploader.swift",
      "InkNotes/Persistence/BaiduUploadReconciliationRepository.swift",
    ])

    for inputURL in try productionSwiftURLs(repositoryRoot: rootURL) {
      let path = relativePath(inputURL, repositoryRoot: rootURL)
      let contents = try String(contentsOf: inputURL, encoding: .utf8)
      if containsBaiduIntegrationMarker(in: contents), !allowedBaiduSwiftFiles.contains(path) {
        Issue.record("Baidu integration escaped its quarantine into \(path)")
      }
    }
  }

  @Test("The scanner rejects representative unsafe release inputs")
  func scannerNegativeControls() {
    let samples: [(String, OAuthSecurityFinding)] = [
      ("let clientSecret = runtimeValue", .clientSecretMarker),
      ("https://openapi.baidu.com/oauth/2.0/token", .directOAuthControlPlane),
      ("INFOPLIST_KEY_CFBundleURLTypes = ()", .callbackRegistration),
      ("com.apple.developer.associated-domains = []", .callbackRegistration),
      ("<key>UIBackgroundModes</key>", .backgroundTransferCapability),
      (
        "URLSessionConfiguration.background(withIdentifier: identifier)",
        .backgroundTransferCapability
      ),
      ("import AuthenticationServices", .unapprovedOAuthConfiguration),
      ("ASWebAuthenticationSession", .unapprovedOAuthConfiguration),
      ("https://localhost/oauth/start", .placeholderBrokerHost),
      ("状态：已连接", .connectedClaim),
    ]

    for (sample, expectedFinding) in samples {
      #expect(securityFindings(in: sample).contains(expectedFinding))
    }
    #expect(containsBaiduIntegrationMarker(in: "https://pan.baidu.com/rest/2.0/xpan/file"))
    #expect(containsBaiduIntegrationMarker(in: "let baiduClient = service"))
  }

  private enum OAuthSecurityFinding: String, Hashable {
    case backgroundTransferCapability
    case callbackRegistration
    case clientSecretMarker
    case connectedClaim
    case directOAuthControlPlane
    case placeholderBrokerHost
    case unapprovedOAuthConfiguration
  }

  private enum OAuthSecurityContractError: Error {
    case repositoryRootNotFound
    case sourceEnumerationFailed
  }

  private func securityFindings(in contents: String) -> Set<OAuthSecurityFinding> {
    let lowercase = contents.lowercased()
    let compact = lowercase.unicodeScalars.filter(CharacterSet.alphanumerics.contains)
    let compactString = String(String.UnicodeScalarView(compact))
    var findings = Set<OAuthSecurityFinding>()

    if compactString.contains("clientsecret")
      || compactString.contains("secretkey")
      || compactString.contains("baiduappsecret")
    {
      findings.insert(.clientSecretMarker)
    }
    if lowercase.contains("openapi.baidu.com/oauth")
      || lowercase.contains("passport.baidu.com")
      || lowercase.contains("/oauth/2.0/")
    {
      findings.insert(.directOAuthControlPlane)
    }
    if compactString.contains("cfbundleurltypes")
      || compactString.contains("cfbundleurlschemes")
      || compactString.contains("associateddomains")
      || lowercase.contains("com.apple.developer.associated-domains")
      || lowercase.contains("applinks:")
    {
      findings.insert(.callbackRegistration)
    }
    if compactString.contains("uibackgroundmodes")
      || compactString.contains("bgtaskschedulerpermittedidentifiers")
      || compactString.contains("bgtaskscheduler")
      || compactString.contains("bgprocessingtask")
      || compactString.contains("bgapprefreshtask")
      || compactString.contains("backgroundwithidentifier")
    {
      findings.insert(.backgroundTransferCapability)
    }
    if compactString.contains("oauthbrokerurl")
      || compactString.contains("oauthcallback")
      || compactString.contains("baiduclientid")
      || compactString.contains("baiduappkey")
      || compactString.contains("authenticationservices")
      || compactString.contains("aswebauthenticationsession")
    {
      findings.insert(.unapprovedOAuthConfiguration)
    }
    if lowercase.contains("example.com")
      || lowercase.contains("example.net")
      || lowercase.contains("example.org")
      || lowercase.contains("example.invalid")
      || lowercase.contains("://localhost")
      || lowercase.contains("://127.0.0.1")
      || lowercase.contains("://[::1]")
    {
      findings.insert(.placeholderBrokerHost)
    }
    if contents.contains("已连接") {
      findings.insert(.connectedClaim)
    }
    return findings
  }

  private func containsBaiduIntegrationMarker(in contents: String) -> Bool {
    contents.lowercased().contains("baidu")
      || contents.contains("百度网盘")
      || contents.contains("已连接")
  }

  private func repositoryRootURL() throws -> URL {
    let fileManager = FileManager.default
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<8 {
      let packageURL = candidate.appendingPathComponent("Package.swift")
      let projectURL = candidate.appendingPathComponent("InkNotes.xcodeproj", isDirectory: true)
      if fileManager.fileExists(atPath: packageURL.path),
        fileManager.fileExists(atPath: projectURL.path)
      {
        return candidate.standardizedFileURL
      }
      candidate.deleteLastPathComponent()
    }
    throw OAuthSecurityContractError.repositoryRootNotFound
  }

  private func shippingInputURLs(repositoryRoot: URL) throws -> [URL] {
    let fileManager = FileManager.default
    guard
      let enumerator = fileManager.enumerator(
        at: repositoryRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else {
      throw OAuthSecurityContractError.sourceEnumerationFailed
    }

    var urls = Set<URL>()
    while let url = enumerator.nextObject() as? URL {
      let path = relativePath(url, repositoryRoot: repositoryRoot)
      let topLevelComponent = path.split(separator: "/").first.map(String.init)
      let values = try url.resourceValues(forKeys: [.isDirectoryKey])
      if values.isDirectory == true {
        if topLevelComponent == "InkNotesCoreTests" || topLevelComponent == "docs" {
          enumerator.skipDescendants()
        }
        continue
      }

      if path == "Package.swift"
        || path == "InkNotes.xcodeproj/project.pbxproj"
        || (url.pathExtension.lowercased() == "swift"
          && topLevelComponent != "InkNotesCoreTests" && topLevelComponent != "docs")
        || (path.hasPrefix("InkNotes/")
          && ["plist", "strings", "stringsdict", "xcstrings"]
            .contains(url.pathExtension.lowercased()))
        || ["xcconfig", "entitlements"].contains(url.pathExtension.lowercased())
      {
        urls.insert(url.standardizedFileURL)
      }
    }
    return urls.sorted { $0.path < $1.path }
  }

  private func productionSwiftURLs(repositoryRoot: URL) throws -> [URL] {
    try shippingInputURLs(repositoryRoot: repositoryRoot)
      .filter {
        $0.pathExtension.lowercased() == "swift"
          && relativePath($0, repositoryRoot: repositoryRoot) != "Package.swift"
      }
  }

  private func relativePath(_ url: URL, repositoryRoot: URL) -> String {
    let rootPath = repositoryRoot.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
    return String(path.dropFirst(rootPath.count + 1))
  }
}
