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

  @Test("The Xcode app cannot enable the Swift Package test credential issuer")
  func xcodeProjectCannotCompileTestingCredentialIssuer() throws {
    let rootURL = try repositoryRootURL()
    let project = try String(
      contentsOf: rootURL.appendingPathComponent("InkNotes.xcodeproj/project.pbxproj"),
      encoding: .utf8
    )
    #expect(!project.contains("SWIFT_PACKAGE"))
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
      "InkNotes/Networking/BaiduRemoteBackupContentVerifier.swift",
      "InkNotes/Networking/BaiduRemoteBackupReconciliationAuthority.swift",
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

  @Test("Outbound data capabilities remain confined to the dormant Baidu implementation")
  func outboundDataCapabilitiesRemainQuarantined() throws {
    let rootURL = try repositoryRootURL()
    let expectedFindingsByPath: [String: Set<OutboundDataFinding>] = [
      "InkNotes/Networking/BaiduHTTPTransport.swift": [.networkPrimitive],
      "InkNotes/Networking/BaiduNetdiskAccountResolver.swift": [.networkPrimitive],
      "InkNotes/Networking/BaiduNetdiskBackupUploader.swift": [.networkPrimitive],
      "InkNotes/Networking/BaiduRemoteBackupContentVerifier.swift": [.networkPrimitive],
      "InkNotes/Networking/BaiduRemoteBackupMetadataObserver.swift": [.networkPrimitive],
    ]
    let expectedImportedModules = Set([
      "Combine",
      "CoreTransferable",
      "CryptoKit",
      "Darwin",
      "Foundation",
      "PencilKit",
      "SwiftUI",
      "UIKit",
      "UniformTypeIdentifiers",
    ])
    let expectedForeignSymbolsByPath = [
      "InkNotes/Persistence/BaiduUploadReconciliationRepository.swift": Set(["flock"])
    ]
    var findingsByPath: [String: Set<OutboundDataFinding>] = [:]
    var importedModules = Set<String>()
    var foreignSymbolsByPath: [String: Set<String>] = [:]

    for inputURL in try productionSwiftURLs(repositoryRoot: rootURL) {
      let path = relativePath(inputURL, repositoryRoot: rootURL)
      let contents = try String(contentsOf: inputURL, encoding: .utf8)
      let findings = outboundDataFindings(in: contents)
      importedModules.formUnion(shippingImportedModules(in: contents))
      let foreignSymbols = shippingForeignSymbolNames(in: contents)
      if !foreignSymbols.isEmpty {
        foreignSymbolsByPath[path] = foreignSymbols
      }
      if !findings.isEmpty {
        findingsByPath[path] = findings
      }
    }

    #expect(findingsByPath == expectedFindingsByPath)
    #expect(importedModules == expectedImportedModules)
    #expect(foreignSymbolsByPath == expectedForeignSymbolsByPath)
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

  @Test("Proofless upload responses cannot claim verified remote content")
  func prooflessUploadResponsesRemainContentUnproven() throws {
    let rootURL = try repositoryRootURL()
    let coordinator = try String(
      contentsOf: rootURL.appendingPathComponent(
        "InkNotes/Networking/BaiduBackupUploadCoordinator.swift"
      ),
      encoding: .utf8
    )

    #expect(coordinator.contains("createResponseMetadataMatchedContentUnproven"))
    #expect(coordinator.contains("case remoteContentVerified(BaiduVerifiedRemoteBackupReceipt)"))
    #expect(coordinator.contains("case .verified(let receipt)"))
    #expect(coordinator.contains("terminal: .remoteContentVerified(receipt)"))
    #expect(coordinator.contains("private var backupsAwaitingRemoteVerification:"))
    #expect(coordinator.contains("backupsAwaitingRemoteVerification[active.key] = active.receipt"))
    #expect(!coordinator.contains("case verifiedRemote"))
    #expect(!coordinator.contains("completedBackups"))
    #expect(!coordinator.contains("alreadyCompletedThisSession"))
    #expect(!coordinator.contains(".contentVerified("))
    #expect(!coordinator.contains("commitVerified"))
    #expect(!coordinator.contains("claimPending"))

    let allowedVerifiedClaimPaths = Set([
      "InkNotes/Networking/BaiduBackupUploadCoordinator.swift",
      "InkNotes/Networking/BaiduRemoteBackupContentVerifier.swift",
      "InkNotes/Networking/BaiduRemoteBackupReconciliationAuthority.swift",
      "InkNotes/Persistence/BaiduUploadReconciliationRepository.swift",
    ])
    for sourceURL in try productionSwiftURLs(repositoryRoot: rootURL) {
      let path = relativePath(sourceURL, repositoryRoot: rootURL)
      guard !allowedVerifiedClaimPaths.contains(path) else { continue }
      let contents = try String(contentsOf: sourceURL, encoding: .utf8).lowercased()
      for forbiddenClaim in ["verifiedremote", "contentverified"]
      where contents.contains(forbiddenClaim) {
        Issue.record("Unproven remote content claim \(forbiddenClaim) in \(path)")
      }
    }
  }

  @Test("Full-byte verification is isolated and cannot reconcile persistent records")
  func fullByteVerificationRemainsIsolated() throws {
    let rootURL = try repositoryRootURL()
    let verifier = try String(
      contentsOf: rootURL.appendingPathComponent(
        "InkNotes/Networking/BaiduRemoteBackupContentVerifier.swift"
      ),
      encoding: .utf8
    )

    #expect(verifier.contains("case contentVerified"))
    #expect(verifier.contains("streamSHA256"))
    #expect(verifier.contains("BaiduHTTPSOnlyRedirectDelegate"))
    #expect(verifier.contains("maximumArchiveByteCount"))
    #expect(!verifier.contains("BaiduUploadReconciliationStoring"))
    #expect(!verifier.contains("BaiduUploadReconciliationRepository"))
    #expect(!verifier.contains("removeOwned"))
    #expect(!verifier.contains("removeItem"))
    #expect(!verifier.contains("FileManager"))
    #expect(!verifier.contains("UserDefaults"))
    #expect(!verifier.contains("Keychain"))
    #expect(!verifier.contains("unlink"))
  }

  @Test("Only sealed full-byte proof plus a verification lease can commit a receipt")
  func verifiedReceiptAuthorityRemainsSealed() throws {
    let rootURL = try repositoryRootURL()
    let verifier = try String(
      contentsOf: rootURL.appendingPathComponent(
        "InkNotes/Networking/BaiduRemoteBackupContentVerifier.swift"
      ),
      encoding: .utf8
    )
    let authority = try String(
      contentsOf: rootURL.appendingPathComponent(
        "InkNotes/Networking/BaiduRemoteBackupReconciliationAuthority.swift"
      ),
      encoding: .utf8
    )
    let repository = try String(
      contentsOf: rootURL.appendingPathComponent(
        "InkNotes/Persistence/BaiduUploadReconciliationRepository.swift"
      ),
      encoding: .utf8
    )

    #expect(verifier.contains("struct BaiduVerifiedRemoteBackupContentProof"))
    #expect(verifier.contains("fileprivate init("))
    #expect(verifier.contains("let verificationChallenge: UUID"))
    #expect(verifier.contains("#if SWIFT_PACKAGE"))
    #expect(verifier.contains("static func testingOnly("))
    #expect(verifier.contains("init()"))

    #expect(authority.contains("private let repository: BaiduUploadReconciliationRepository"))
    #expect(authority.contains("private let verifier: BaiduRemoteBackupContentVerifier"))
    #expect(authority.contains("repository.claimPending("))
    #expect(authority.contains("repository.commitVerified(lease, proof: proof)"))
    #expect(authority.contains("verificationChallenge: lease.verificationChallenge"))
    #expect(!authority.contains("proof: BaiduVerifiedRemoteBackupContentProof"))
    #expect(!authority.contains("BaiduRemoteBackupContentVerificationResult,"))

    #expect(repository.contains("final class BaiduUploadReconciliationVerificationLease"))
    #expect(repository.contains("func commitVerified("))
    #expect(repository.contains("proof: BaiduVerifiedRemoteBackupContentProof"))
    #expect(repository.contains("proof.verificationChallenge == lease.verificationChallenge"))
    #expect(repository.contains("UInt32(RENAME_SWAP)"))
    #expect(repository.contains("case invalidProof"))

    var authorityTypePaths = Set<String>()
    var claimPendingCounts: [String: Int] = [:]
    var commitVerifiedCounts: [String: Int] = [:]
    for sourceURL in try productionSwiftURLs(repositoryRoot: rootURL) {
      let path = relativePath(sourceURL, repositoryRoot: rootURL)
      let code = SwiftSourceLexicalMasker.codeOnly(
        try String(contentsOf: sourceURL, encoding: .utf8)
      )
      if code.contains("BaiduRemoteBackupReconciliationAuthority") {
        authorityTypePaths.insert(path)
      }
      let claimCount = code.components(separatedBy: "claimPending(").count - 1
      if claimCount > 0 {
        claimPendingCounts[path] = claimCount
      }
      let commitCount = code.components(separatedBy: "commitVerified(").count - 1
      if commitCount > 0 {
        commitVerifiedCounts[path] = commitCount
      }
    }
    #expect(
      authorityTypePaths
        == Set(["InkNotes/Networking/BaiduRemoteBackupReconciliationAuthority.swift"])
    )
    #expect(
      claimPendingCounts
        == [
          "InkNotes/Networking/BaiduRemoteBackupReconciliationAuthority.swift": 1,
          "InkNotes/Persistence/BaiduUploadReconciliationRepository.swift": 1,
        ]
    )
    #expect(
      commitVerifiedCounts
        == [
          "InkNotes/Networking/BaiduRemoteBackupReconciliationAuthority.swift": 1,
          "InkNotes/Persistence/BaiduUploadReconciliationRepository.swift": 1,
        ]
    )
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
    #expect(credentialModel.contains("private let expiresAt"))
    #expect(credentialModel.contains("private init("))
    #expect(credentialModel.contains("func requestAccessToken(at now: Date) throws"))
    #expect(credentialModel.contains("#if SWIFT_PACKAGE"))
    #expect(credentialModel.contains("static func testingOnly("))
    #expect(!credentialModel.contains("var requestAccessToken"))
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

  @Test("Every bound-credential token read is expiry-gated and WAL stays credential-free")
  func credentialExpiryGateCallSitesRemainClosed() throws {
    let rootURL = try repositoryRootURL()
    let expectedCounts = [
      "InkNotes/Models/BaiduAccountCredential.swift": 1,
      "InkNotes/Networking/BaiduBackupUploadCoordinator.swift": 3,
      "InkNotes/Networking/BaiduRemoteBackupContentVerifier.swift": 4,
      "InkNotes/Networking/BaiduRemoteBackupMetadataObserver.swift": 1,
    ]
    var actualCounts: [String: Int] = [:]

    for sourceURL in try productionSwiftURLs(repositoryRoot: rootURL) {
      let contents = SwiftSourceLexicalMasker.codeOnly(
        try String(contentsOf: sourceURL, encoding: .utf8)
      )
      let count = contents.components(separatedBy: "requestAccessToken").count - 1
      if count > 0 {
        actualCounts[relativePath(sourceURL, repositoryRoot: rootURL)] = count
      }
    }
    #expect(actualCounts == expectedCounts)

    let reconciliationSource = try String(
      contentsOf: rootURL.appendingPathComponent(
        "InkNotes/Persistence/BaiduUploadReconciliationRepository.swift"
      ),
      encoding: .utf8
    )
    for forbidden in ["expiresAt", "expirationDate", "expires_at"] {
      #expect(!reconciliationSource.contains(forbidden))
    }
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
    #expect(outboundDataFindings(in: "URLSession.shared").contains(.networkPrimitive))
    #expect(
      outboundDataFindings(in: "SentrySDK.start()").contains(.analyticsOrTelemetrySDK)
    )
    #expect(outboundDataFindings(in: "socket(AF_INET, SOCK_STREAM, 0)").contains(.networkPrimitive))
    #expect(outboundDataFindings(in: "import NIOHTTP1").contains(.networkPrimitive))
    #expect(
      outboundDataFindings(in: "CKContainer.default().publicCloudDatabase")
        .contains(.developerAccessibleCloudService)
    )
    #expect(
      outboundDataFindings(in: "NSUbiquitousKeyValueStore.default")
        .contains(.developerAccessibleCloudService)
    )
    #expect(
      outboundDataFindings(in: "NSClassFromString(runtimeName)")
        .contains(.dynamicEgressReviewRequired)
    )
    #expect(outboundDataFindings(in: "Logger.app.info(\"local only\")").isEmpty)
    #expect(outboundDataFindings(in: "OSLog(subsystem: \"local\")").isEmpty)
    #expect(outboundDataFindings(in: "os_log(\"local only\")").isEmpty)
    #expect(outboundDataFindings(in: "// URLSession.shared").isEmpty)
    #expect(outboundDataFindings(in: "/* URLSession.shared */").isEmpty)
    #expect(outboundDataFindings(in: #"let label = "SentrySDK""#).isEmpty)
    #expect(
      outboundDataFindings(in: #"let label = "\(URLSession.shared)""#)
        .contains(.networkPrimitive)
    )
    #expect(shippingImportedModules(in: "import Foundation") == Set(["Foundation"]))
    #expect(shippingImportedModules(in: "// import CloudKit").isEmpty)
  }

  private enum OutboundDataFinding: Hashable {
    case analyticsOrTelemetrySDK
    case developerAccessibleCloudService
    case dynamicEgressReviewRequired
    case networkPrimitive
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

  private func outboundDataFindings(in contents: String) -> Set<OutboundDataFinding> {
    let code = SwiftSourceLexicalMasker.codeOnly(contents)
    let networkMarkers = [
      "URLSession",
      "URLRequest",
      "URLProtocol",
      "NSURLConnection",
      "CFNetwork",
      "NWConnection",
      "WKWebView",
      "ASWebAuthenticationSession",
      "SFSafariViewController",
      "CFReadStreamCreateForHTTPRequest",
      "CFStreamCreatePairWithSocketToHost",
      "import NIO",
      "AsyncHTTPClient",
    ]
    let analyticsOrTelemetryMarkers = [
      "import Sentry",
      "SentrySDK",
      "import Firebase",
      "FirebaseApp",
      "Crashlytics",
      "Datadog",
      "AppCenter",
      "Mixpanel",
      "Amplitude",
      "import Segment",
      "Bugsnag",
      "Instabug",
      "NewRelic",
      "OpenTelemetry",
    ]
    let developerAccessibleCloudMarkers = [
      "CKContainer",
      "CKDatabase",
      "CKRecord",
      "NSPersistentCloudKitContainer",
      "NSUbiquitousKeyValueStore",
      "forUbiquityContainerIdentifier",
      "ubiquityIdentityToken",
      "setUbiquitous",
      "startDownloadingUbiquitousItem",
      "isUbiquitousItemKey",
    ]
    let dynamicEgressMarkers = [
      "NSClassFromString",
      "NSSelectorFromString",
      "objc_msgSend",
      "dlopen",
      "dlsym",
    ]
    var findings = Set<OutboundDataFinding>()
    if networkMarkers.contains(where: code.contains)
      || regularExpressionMatches(
        #"(?<![A-Za-z0-9_])(?:socket|connect|send|sendto)\s*\("#,
        in: code
      )
    {
      findings.insert(.networkPrimitive)
    }
    if analyticsOrTelemetryMarkers.contains(where: code.contains) {
      findings.insert(.analyticsOrTelemetrySDK)
    }
    if developerAccessibleCloudMarkers.contains(where: code.contains) {
      findings.insert(.developerAccessibleCloudService)
    }
    if dynamicEgressMarkers.contains(where: code.contains) {
      findings.insert(.dynamicEgressReviewRequired)
    }
    return findings
  }

  private func shippingImportedModules(in contents: String) -> Set<String> {
    let code = SwiftSourceLexicalMasker.codeOnly(contents)
    let importPattern =
      #"^[ \t]*(?:@[_A-Za-z][_A-Za-z0-9]*(?:\([^)]*\))?[ \t]+)*(?:(?:public|internal|private|package|fileprivate)[ \t]+)?import[ \t]+(?:(?:typealias|struct|class|enum|protocol|let|var|func)[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)(?:\.[A-Za-z_][A-Za-z0-9_]*)*[ \t]*;?[ \t]*$"#
    guard let expression = try? NSRegularExpression(pattern: importPattern) else {
      Issue.record("Invalid shipping import inventory expression")
      return ["MANUAL_REVIEW_REQUIRED_FOR_IMPORT_SYNTAX"]
    }

    var modules = Set<String>()
    for lineSlice in code.split(whereSeparator: \Character.isNewline) {
      let line = String(lineSlice)
      guard line.range(of: #"\bimport\b"#, options: .regularExpression) != nil else {
        continue
      }
      let range = NSRange(line.startIndex..<line.endIndex, in: line)
      guard let match = expression.firstMatch(in: line, range: range),
        match.range == range,
        let moduleRange = Range(match.range(at: 1), in: line)
      else {
        modules.insert("MANUAL_REVIEW_REQUIRED_FOR_IMPORT_SYNTAX")
        continue
      }
      modules.insert(String(line[moduleRange]))
    }
    return modules
  }

  private func shippingForeignSymbolNames(in contents: String) -> Set<String> {
    let pattern = #"@_silgen_name\s*\(\s*"([A-Za-z_][A-Za-z0-9_]*)"\s*\)"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      Issue.record("Invalid foreign symbol inventory expression")
      return ["MANUAL_REVIEW_REQUIRED_FOR_FOREIGN_SYMBOL"]
    }
    let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
    return Set(
      expression.matches(in: contents, range: range).compactMap { match in
        guard let symbolRange = Range(match.range(at: 1), in: contents) else { return nil }
        return String(contents[symbolRange])
      })
  }

  private func regularExpressionMatches(_ pattern: String, in contents: String) -> Bool {
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      Issue.record("Invalid outbound data inventory expression")
      return false
    }
    return expression.firstMatch(
      in: contents,
      range: NSRange(contents.startIndex..<contents.endIndex, in: contents)
    ) != nil
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
        let path = relativePath($0, repositoryRoot: repositoryRoot)
        return $0.pathExtension.lowercased() == "swift" && path.hasPrefix("InkNotes/")
      }
  }

  private func relativePath(_ url: URL, repositoryRoot: URL) -> String {
    let rootPath = repositoryRoot.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
    return String(path.dropFirst(rootPath.count + 1))
  }
}
