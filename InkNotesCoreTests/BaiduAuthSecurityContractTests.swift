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
      "InkNotes/Models/BaiduAccountCredential.swift",
      "InkNotes/Models/BaiduNetdiskAccount.swift",
      "InkNotes/Models/BaiduNetdiskBackup.swift",
      "InkNotes/Networking/BaiduBackupUploadCoordinator.swift",
      "InkNotes/Networking/BaiduHTTPTransport.swift",
      "InkNotes/Networking/BaiduNetdiskAccountResolver.swift",
      "InkNotes/Networking/BaiduNetdiskBackupUploader.swift",
      "InkNotes/Networking/BaiduRemoteBackupMetadataObserver.swift",
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

  @Test("Remote metadata observation remains read-only and cannot authorize reconciliation")
  func remoteMetadataObservationRemainsReadOnly() throws {
    let rootURL = try repositoryRootURL()
    let observer = try String(
      contentsOf: rootURL.appendingPathComponent(
        "InkNotes/Networking/BaiduRemoteBackupMetadataObserver.swift"
      ),
      encoding: .utf8
    )

    #expect(observer.contains("exactMetadataMatchContentUnproven"))
    #expect(observer.contains("case notObservedAbsenceUnproven"))
    #expect(observer.contains("case indeterminate"))
    #expect(!observer.contains("BaiduUploadReconciliationStoring"))
    #expect(!observer.contains("BaiduUploadReconciliationRepository"))
    #expect(!observer.contains("removeOwned"))
    #expect(!observer.contains("removeItem"))
    #expect(!observer.contains("FileManager"))
    #expect(!observer.contains("unlink"))
    #expect(!observer.contains("filemetas"))
    #expect(!observer.contains("dlink"))
    #expect(!observer.contains("verifiedRemote"))

    for sourceURL in try productionSwiftURLs(repositoryRoot: rootURL) {
      let path = relativePath(sourceURL, repositoryRoot: rootURL)
      guard path != "InkNotes/Networking/BaiduRemoteBackupMetadataObserver.swift" else {
        continue
      }
      let contents = try String(contentsOf: sourceURL, encoding: .utf8)
      #expect(!contents.contains("BaiduRemoteBackupMetadataObservation"))
      #expect(!contents.contains("BaiduRemoteBackupMetadataObserver("))
      #expect(!contents.contains("exactMetadataMatchContentUnproven"))
      #expect(!contents.contains("notObservedAbsenceUnproven"))
    }
  }

  @Test("Account scope is broker-bound, redacted, and never derived from token or UInfo")
  func accountScopeCapabilityRemainsOpaque() throws {
    let rootURL = try repositoryRootURL()
    let credentialModel = try String(
      contentsOf: rootURL.appendingPathComponent(
        "InkNotes/Models/BaiduAccountCredential.swift"
      ),
      encoding: .utf8
    )

    #expect(credentialModel.contains("init(brokerBindingID: UUID)"))
    #expect(credentialModel.contains("CustomReflectable"))
    #expect(credentialModel.contains("private let accessToken"))
    #expect(credentialModel.contains("private init(accountScope:"))
    #expect(credentialModel.contains("#if SWIFT_PACKAGE"))
    #expect(credentialModel.contains("static func testingOnly("))
    #expect(!credentialModel.contains("import CryptoKit"))
    #expect(!credentialModel.contains("BaiduAccountIdentity"))
    #expect(!credentialModel.contains("requestValue"))
    #expect(!credentialModel.contains("tokenHash"))
    #expect(!credentialModel.contains("init(accessToken:"))
    #expect(!credentialModel.contains("init(token:"))
    #expect(!credentialModel.contains("init(uk:"))
    #expect(!credentialModel.contains("SHA256"))
    #expect(!credentialModel.contains("MD5"))
    #expect(!credentialModel.contains("struct BaiduAccountBoundCredential: Codable"))
  }

  @Test("Account identity probe remains minimal, redacted, and storage-free")
  func accountIdentityProbeRemainsIsolated() throws {
    let rootURL = try repositoryRootURL()
    let model = try String(
      contentsOf: rootURL.appendingPathComponent("InkNotes/Models/BaiduNetdiskAccount.swift"),
      encoding: .utf8
    )
    let resolver = try String(
      contentsOf: rootURL.appendingPathComponent(
        "InkNotes/Networking/BaiduNetdiskAccountResolver.swift"
      ),
      encoding: .utf8
    )

    #expect(!model.contains("Codable"))
    #expect(model.contains("CustomReflectable"))
    #expect(resolver.contains("/rest/2.0/xpan/nas"))
    #expect(resolver.contains("URLQueryItem(name: \"method\", value: \"uinfo\")"))
    #expect(resolver.contains("URLQueryItem(name: \"vip_version\", value: \"v2\")"))
    for forbidden in [
      "baidu_name", "netdisk_name", "avatar_url", "UserDefaults", "Keychain", "FileManager",
    ] {
      #expect(!model.contains(forbidden))
      #expect(!resolver.contains(forbidden))
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
