import CryptoKit
import Foundation
import PencilKit
import Testing

@testable import InkNotesCore

@Suite("InkNotes compatibility contract")
struct CompatibilityContractTests {
  private let expectedBundleIdentifier = "com.salomeailin.InkNotes"
  private let expectedInternalDisplayName = "InkNotes Dev"
  private let backupID = UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!
  private let notebookID = UUID(uuidString: "B2000000-0000-0000-0000-000000000001")!
  private let blankPageID = UUID(uuidString: "C3000000-0000-0000-0000-000000000001")!
  private let ruledPageID = UUID(uuidString: "C3000000-0000-0000-0000-000000000002")!
  private let gridPageID = UUID(uuidString: "C3000000-0000-0000-0000-000000000003")!

  @Test("Persisted identities remain independent from the display name")
  func persistedIdentityConstantsRemainStable() {
    #expect(DrawingRepository.persistedDirectoryName == "InkNotes")
    #expect(DrawingRepository.libraryFilename == "library.json")
    #expect(DrawingRepository.drawingsDirectoryName == "Drawings")
    #expect(DrawingRepository.drawingFileExtension == "drawing")
    #expect(DrawingRepository.restoreTransactionsDirectoryName == "RestoreTransactions")
    #expect(DrawingRepository.restoreTransactionFileExtension == "json")
    #expect(DrawingRepository.defaultRootURL()?.lastPathComponent == "InkNotes")
    #expect(BaiduUploadReconciliationRepository.persistedDirectoryName == "InkNotes")
    #expect(
      BaiduUploadReconciliationRepository.reconciliationDirectoryName
        == "UploadReconciliation"
    )
    #expect(BaiduUploadReconciliationRepository.recordFileExtension == "json")
    #expect(BaiduUploadReconciliationRepository.defaultRootURL()?.lastPathComponent == "InkNotes")

    #expect(BackupArchiveCodec.uniformTypeIdentifier == "com.salomeailin.notes.backup")
    #expect(BackupArchiveCodec.fileExtension == "notesbackup")
    #expect(BackupArchiveCodec.mimeType == "application/vnd.salomeailin.notes-backup")
    #expect(BackupArchiveCodec.magic == Data([0x49, 0x4E, 0x4B, 0x4E, 0x4F, 0x54, 0x45, 0x00]))
    #expect(BackupArchiveCodec.formatVersion == 1)
    #expect(BackupArchiveCodec.headerByteCount == 56)
    #expect(LibraryDocument.currentSchemaVersion == 1)
  }

  @Test("Repository writes the historical directory and filename layout")
  func historicalPersistenceLayoutRemainsStable() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: rootURL) }

    let pageID = UUID(uuidString: "ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB")!
    let page = NotePage(
      id: pageID,
      title: "兼容性路径",
      createdAt: Date(timeIntervalSince1970: 1_690_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_690_000_100)
    )
    let notebook = Notebook(
      id: notebookID,
      title: "兼容性测试",
      pages: [page],
      createdAt: page.createdAt,
      updatedAt: page.updatedAt
    )
    let repository = DrawingRepository(rootURL: rootURL)

    try await repository.saveLibrary(LibraryDocument(notebooks: [notebook]))
    try await repository.saveDrawing(Data([0x49, 0x4E, 0x4B]), pageID: pageID)

    let libraryURL = rootURL.appendingPathComponent("library.json", isDirectory: false)
    let drawingURL =
      rootURL
      .appendingPathComponent("Drawings", isDirectory: true)
      .appendingPathComponent("ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB.drawing")
    #expect(fileManager.fileExists(atPath: libraryURL.path))
    #expect(fileManager.fileExists(atPath: drawingURL.path))
  }

  @Test("Project metadata retains app and backup file identities")
  func projectMetadataRemainsCompatible() throws {
    let repositoryRoot = repositoryRootURL()
    let plistURL = repositoryRoot.appendingPathComponent("InkNotes/Info.plist")
    let plistData = try Data(contentsOf: plistURL)
    let plist = try #require(
      try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
        as? [String: Any]
    )
    let declarations = try #require(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
    let declaration = try #require(declarations.first)
    let tags = try #require(declaration["UTTypeTagSpecification"] as? [String: Any])
    let extensions = try #require(tags["public.filename-extension"] as? [String])

    #expect(declaration["UTTypeIdentifier"] as? String == BackupArchiveCodec.uniformTypeIdentifier)
    #expect(extensions == [BackupArchiveCodec.fileExtension])
    #expect(tags["public.mime-type"] as? String == BackupArchiveCodec.mimeType)

    let projectURL = repositoryRoot.appendingPathComponent("InkNotes.xcodeproj/project.pbxproj")
    let projectData = try Data(contentsOf: projectURL)
    let project = try #require(
      try PropertyListSerialization.propertyList(from: projectData, options: [], format: nil)
        as? [String: Any]
    )
    _ = try validateMainAppBundleIdentifiers(in: project)
  }

  @Test("Buildable product uses the explicit internal display name")
  func buildableProductUsesInternalDisplayName() throws {
    let plistURL = repositoryRootURL().appendingPathComponent("InkNotes/Info.plist")
    let plistData = try Data(contentsOf: plistURL)
    let plist = try #require(
      try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
        as? [String: Any]
    )
    let displayName = try #require(plist["CFBundleDisplayName"] as? String)

    #expect(displayName == expectedInternalDisplayName)
    #expect(displayName != "墨记")
  }

  @Test("Device signing stays local and the current build number is unambiguous")
  func deviceSigningConfigurationRemainsLocal() throws {
    let repositoryRoot = repositoryRootURL()
    let projectURL = repositoryRoot.appendingPathComponent("InkNotes.xcodeproj/project.pbxproj")
    let projectData = try Data(contentsOf: projectURL)
    let project = try #require(
      try PropertyListSerialization.propertyList(from: projectData, options: [], format: nil)
        as? [String: Any]
    )
    let configurations = try validateMainAppBundleIdentifiers(in: project)

    #expect(configurations.map(\.name) == ["Debug", "Release"])
    #expect(configurations.allSatisfy { $0.currentProjectVersion == "3" })
    #expect(configurations.allSatisfy { $0.marketingVersion == "0.2.0" })
    #expect(configurations.allSatisfy { $0.developmentTeam == "" })
    #expect(configurations.allSatisfy { $0.codeSignStyle == "Automatic" })

    let buildScript = try String(
      contentsOf: repositoryRoot.appendingPathComponent("scripts/build-signed-ipad-app.sh"),
      encoding: .utf8
    )
    let readinessScript = try String(
      contentsOf: repositoryRoot.appendingPathComponent("scripts/verify-ipad-readiness.sh"),
      encoding: .utf8
    )
    for script in [buildScript, readinessScript] {
      #expect(!script.contains("-allowProvisioningUpdates"))
      #expect(!script.contains("-allowProvisioningDeviceRegistration"))
    }
    #expect(buildScript.contains("TeamIdentifier.0"))
    #expect(buildScript.contains("git status --porcelain=v1"))
    #expect(buildScript.contains("git archive --format=tar \"$notes_source_commit\""))
    #expect(buildScript.contains("-project \"$notes_source_root/InkNotes.xcodeproj\""))
    #expect(!buildScript.contains("-project InkNotes.xcodeproj"))
    #expect(!buildScript.contains("PROVISIONING_PROFILE_SPECIFIER="))
    #expect(buildScript.contains("CODE_SIGN_STYLE=Automatic"))
    #expect(buildScript.contains("notes_actual_profile_uuid\" == \"$notes_selected_uuid"))
    #expect(buildScript.contains("notes_actual_profile_sha256\" == \"$notes_selected_sha256"))
    #expect(buildScript.contains("embeddedProfileSHA256"))
    #expect(buildScript.contains("notes_output_relative"))
    #expect(readinessScript.contains("codesign --verify --deep --strict"))
    #expect(readinessScript.contains("codesign -d --entitlements :-"))
    #expect(readinessScript.contains("com\\.apple\\.developer\\.team-identifier"))
    #expect(readinessScript.contains("ProvisionedDevices"))
    #expect(readinessScript.contains("embeddedProfileSHA256"))
    #expect(readinessScript.contains("notes_device_connection_state"))
    #expect(readinessScript.contains("devicectl.list.devices"))
    #expect(readinessScript.contains("com.apple.coredevice.feature.installapp"))
    #expect(
      readinessScript.components(separatedBy: "xcrun devicectl list devices").count - 1 == 1
    )
  }

  @Test("An orphan app target cannot hide a mounted main-app identifier drift")
  func orphanAppTargetCannotMaskMountedAppDrift() {
    let project = makeSyntheticProject(
      mountedDebugBundleIdentifier: "com.example.drifted",
      mountedReleaseBundleIdentifier: expectedBundleIdentifier,
      widgetBundleIdentifier: "com.example.widget",
      orphanBundleIdentifier: expectedBundleIdentifier
    )

    #expect(
      throws: PBXProjectContractError.bundleIdentifierMismatch(
        configuration: "Debug",
        actual: "com.example.drifted"
      )
    ) {
      try validateMainAppBundleIdentifiers(in: project)
    }
  }

  @Test("An attached widget may use its own bundle identifier")
  func attachedWidgetIdentifierDoesNotAffectMainAppContract() throws {
    let project = makeSyntheticProject(
      mountedDebugBundleIdentifier: expectedBundleIdentifier,
      mountedReleaseBundleIdentifier: expectedBundleIdentifier,
      widgetBundleIdentifier: "com.example.widget",
      orphanBundleIdentifier: "com.example.orphan"
    )

    let configurations = try validateMainAppBundleIdentifiers(in: project)
    #expect(configurations.map(\.name) == ["Debug", "Release"])
  }

  @Test("The committed v1 archive remains byte-for-byte readable and writable")
  func goldenVersionOneArchiveRemainsCompatible() async throws {
    let archiveURL = try fixtureURL(
      named: "reference-v1",
      extension: "notesbackup"
    )
    let drawingURL = try fixtureURL(
      named: "serialized-empty-v1",
      extension: "pkdrawing"
    )
    let strokeDrawingURL = try fixtureURL(
      named: "single-stroke-v1",
      extension: "pkdrawing"
    )
    let archive = try Data(contentsOf: archiveURL)
    let serializedDrawing = try Data(contentsOf: drawingURL)
    let serializedStrokeDrawing = try Data(contentsOf: strokeDrawingURL)

    try #require(archive.count == 1_571)
    #expect(
      sha256Hex(archive) == "1441724e2664ee6e77615442e6e95b510aca65472250f751322b3e82356b8a36")
    try #require(serializedDrawing.count == 42)
    #expect(
      sha256Hex(serializedDrawing)
        == "2374fdaf833647569ad2ce1e0048c61bc58cb414b8c9f2537ccf1c8c10b374db")
    try #require(serializedStrokeDrawing.count == 286)
    #expect(
      sha256Hex(serializedStrokeDrawing)
        == "a76b5cc7a9291ab26c19803dc7aad3d045fb636a79b4ce04db374e05a3aad217")
    #expect(Array(archive[0..<8]) == [0x49, 0x4E, 0x4B, 0x4E, 0x4F, 0x54, 0x45, 0x00])
    #expect(readUInt16(archive, at: 8) == 1)
    #expect(readUInt16(archive, at: 10) == 0)
    #expect(readUInt32(archive, at: 12) == 1_187)
    #expect(readUInt64(archive, at: 16) == 328)
    _ = try PKDrawing(data: serializedDrawing)
    let strokeDrawing = try PKDrawing(data: serializedStrokeDrawing)
    #expect(strokeDrawing.strokes.count == 1)

    let expectedLibrary = makeGoldenLibrary()
    let expectedDrawings = [
      blankPageID: Data(),
      ruledPageID: serializedDrawing,
      gridPageID: serializedStrokeDrawing,
    ]
    let decoded = try BackupArchiveCodec.decode(archive)
    #expect(decoded.backupID == backupID)
    #expect(decoded.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(decoded.sourceAppVersion == "0.2.0")
    #expect(decoded.sourceBuild == "2")
    #expect(decoded.library == expectedLibrary)
    #expect(decoded.drawings == expectedDrawings)

    let reencoded = try BackupArchiveCodec.encode(
      library: expectedLibrary,
      drawings: expectedDrawings,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      backupID: backupID,
      sourceAppVersion: "0.2.0",
      sourceBuild: "2"
    )
    #expect(reencoded == archive)

    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: rootURL) }
    let repository = DrawingRepository(rootURL: rootURL)
    let currentPage = NotePage(
      id: UUID(uuidString: "D4000000-0000-0000-0000-000000000001")!,
      title: "当前页面",
      createdAt: Date(timeIntervalSince1970: 1_710_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_710_000_100)
    )
    let currentNotebook = Notebook(
      id: UUID(uuidString: "D4000000-0000-0000-0000-000000000002")!,
      title: "当前笔记本",
      pages: [currentPage],
      createdAt: currentPage.createdAt,
      updatedAt: currentPage.updatedAt
    )
    let currentLibrary = LibraryDocument(notebooks: [currentNotebook])
    let currentDrawing = PKDrawing().dataRepresentation()

    let preview = try await repository.inspectBackup(archive)
    #expect(preview.notebookCount == 1)
    #expect(preview.pageCount == 3)
    let restoreResult = try await repository.restoreBackupAsCopy(
      archive,
      currentLibrary: currentLibrary,
      currentDrawingOverrides: [currentPage.id: currentDrawing],
      importedAt: Date(timeIntervalSince1970: 1_720_000_000)
    )
    #expect(restoreResult.importedNotebookCount == 1)
    #expect(restoreResult.importedPageCount == 3)
    #expect(restoreResult.repairedDrawingCount == 0)
    #expect(restoreResult.repairedPageIDs.isEmpty)
    #expect(restoreResult.selectedDrawingData.isEmpty)
    #expect(restoreResult.library.notebooks.count == 2)
    #expect(restoreResult.library.notebooks.first == currentNotebook)
    let restoredNotebook = try #require(restoreResult.library.notebooks.last)
    #expect(restoredNotebook.id != notebookID)
    #expect(restoredNotebook.title == "历史备份样本（导入）")
    #expect(restoredNotebook.pages.map(\.title) == ["空白页", "横线页", "方格页"])
    #expect(restoredNotebook.pages.map(\.background) == [.blank, .ruled, .grid])
    let sourcePageIDs = Set([blankPageID, ruledPageID, gridPageID])
    #expect(Set(restoredNotebook.pages.map(\.id)).isDisjoint(with: sourcePageIDs))
    let restoredStrokePage = try #require(restoredNotebook.pages.last)
    let restoredStrokeData = try #require(
      try await repository.loadDrawing(pageID: restoredStrokePage.id)
    )
    let persistedCurrentDrawing = try #require(
      try await repository.loadDrawing(pageID: currentPage.id)
    )
    #expect(persistedCurrentDrawing == currentDrawing)
    #expect(restoredStrokeData == serializedStrokeDrawing)
    #expect(try PKDrawing(data: restoredStrokeData).strokes.count == 1)
  }

  private func makeGoldenLibrary() -> LibraryDocument {
    let createdAt = Date(timeIntervalSince1970: 1_690_000_000)
    let updatedAt = Date(timeIntervalSince1970: 1_690_000_100)
    let pages = [
      NotePage(
        id: blankPageID,
        title: "空白页",
        background: .blank,
        createdAt: createdAt,
        updatedAt: updatedAt
      ),
      NotePage(
        id: ruledPageID,
        title: "横线页",
        background: .ruled,
        createdAt: createdAt,
        updatedAt: updatedAt
      ),
      NotePage(
        id: gridPageID,
        title: "方格页",
        background: .grid,
        createdAt: createdAt,
        updatedAt: updatedAt
      ),
    ]
    return LibraryDocument(
      notebooks: [
        Notebook(
          id: notebookID,
          title: "历史备份样本",
          pages: pages,
          createdAt: createdAt,
          updatedAt: updatedAt
        )
      ]
    )
  }

  private func fixtureURL(named name: String, extension fileExtension: String) throws -> URL {
    try #require(
      Bundle.module.url(
        forResource: name,
        withExtension: fileExtension,
        subdirectory: "Fixtures/BackupV1"
      )
    )
  }

  private func repositoryRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private struct AppBuildConfiguration: Equatable {
    let name: String
    let bundleIdentifier: String?
    let currentProjectVersion: String?
    let marketingVersion: String?
    let developmentTeam: String?
    let codeSignStyle: String?
  }

  private enum PBXProjectContractError: Error, Equatable {
    case malformedProjectGraph
    case mainAppTargetCount(Int)
    case duplicateConfiguration(String)
    case missingConfiguration(String)
    case bundleIdentifierMismatch(configuration: String, actual: String?)
  }

  private func validateMainAppBundleIdentifiers(
    in project: [String: Any]
  ) throws -> [AppBuildConfiguration] {
    guard let rootObjectID = project["rootObject"] as? String,
      let objects = project["objects"] as? [String: Any],
      let rootProject = objects[rootObjectID] as? [String: Any],
      rootProject["isa"] as? String == "PBXProject",
      let targetIDs = rootProject["targets"] as? [String]
    else {
      throw PBXProjectContractError.malformedProjectGraph
    }

    let mountedTargets = try targetIDs.map { targetID in
      guard let target = objects[targetID] as? [String: Any] else {
        throw PBXProjectContractError.malformedProjectGraph
      }
      return target
    }
    let appTargets = mountedTargets.filter {
      $0["isa"] as? String == "PBXNativeTarget"
        && $0["name"] as? String == "InkNotes"
        && $0["productType"] as? String == "com.apple.product-type.application"
    }
    guard appTargets.count == 1, let appTarget = appTargets.first else {
      throw PBXProjectContractError.mainAppTargetCount(appTargets.count)
    }
    guard let configurationListID = appTarget["buildConfigurationList"] as? String,
      let configurationList = objects[configurationListID] as? [String: Any],
      configurationList["isa"] as? String == "XCConfigurationList",
      let configurationIDs = configurationList["buildConfigurations"] as? [String],
      !configurationIDs.isEmpty
    else {
      throw PBXProjectContractError.malformedProjectGraph
    }

    var names = Set<String>()
    var configurations: [AppBuildConfiguration] = []
    configurations.reserveCapacity(configurationIDs.count)
    for configurationID in configurationIDs {
      guard let configuration = objects[configurationID] as? [String: Any],
        configuration["isa"] as? String == "XCBuildConfiguration",
        let name = configuration["name"] as? String,
        let buildSettings = configuration["buildSettings"] as? [String: Any]
      else {
        throw PBXProjectContractError.malformedProjectGraph
      }
      guard names.insert(name).inserted else {
        throw PBXProjectContractError.duplicateConfiguration(name)
      }
      configurations.append(
        AppBuildConfiguration(
          name: name,
          bundleIdentifier: buildSettings["PRODUCT_BUNDLE_IDENTIFIER"] as? String,
          currentProjectVersion: scalarString(buildSettings["CURRENT_PROJECT_VERSION"]),
          marketingVersion: scalarString(buildSettings["MARKETING_VERSION"]),
          developmentTeam: buildSettings["DEVELOPMENT_TEAM"] as? String,
          codeSignStyle: buildSettings["CODE_SIGN_STYLE"] as? String
        )
      )
    }

    for requiredName in ["Debug", "Release"] where !names.contains(requiredName) {
      throw PBXProjectContractError.missingConfiguration(requiredName)
    }
    for configuration in configurations
    where configuration.bundleIdentifier != expectedBundleIdentifier {
      throw PBXProjectContractError.bundleIdentifierMismatch(
        configuration: configuration.name,
        actual: configuration.bundleIdentifier
      )
    }
    return configurations
  }

  private func scalarString(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
  }

  private func makeSyntheticProject(
    mountedDebugBundleIdentifier: String,
    mountedReleaseBundleIdentifier: String,
    widgetBundleIdentifier: String,
    orphanBundleIdentifier: String
  ) -> [String: Any] {
    let objects: [String: Any] = [
      "ROOT": [
        "isa": "PBXProject",
        "targets": ["MOUNTED_APP", "WIDGET"],
      ],
      "MOUNTED_APP": [
        "isa": "PBXNativeTarget",
        "name": "InkNotes",
        "productType": "com.apple.product-type.application",
        "buildConfigurationList": "MOUNTED_APP_CONFIGURATIONS",
      ],
      "MOUNTED_APP_CONFIGURATIONS": [
        "isa": "XCConfigurationList",
        "buildConfigurations": ["MOUNTED_DEBUG", "MOUNTED_RELEASE"],
      ],
      "MOUNTED_DEBUG": [
        "isa": "XCBuildConfiguration",
        "name": "Debug",
        "buildSettings": ["PRODUCT_BUNDLE_IDENTIFIER": mountedDebugBundleIdentifier],
      ],
      "MOUNTED_RELEASE": [
        "isa": "XCBuildConfiguration",
        "name": "Release",
        "buildSettings": ["PRODUCT_BUNDLE_IDENTIFIER": mountedReleaseBundleIdentifier],
      ],
      "WIDGET": [
        "isa": "PBXNativeTarget",
        "name": "InkNotesWidget",
        "productType": "com.apple.product-type.app-extension",
        "buildConfigurationList": "WIDGET_CONFIGURATIONS",
      ],
      "WIDGET_CONFIGURATIONS": [
        "isa": "XCConfigurationList",
        "buildConfigurations": ["WIDGET_DEBUG", "WIDGET_RELEASE"],
      ],
      "WIDGET_DEBUG": [
        "isa": "XCBuildConfiguration",
        "name": "Debug",
        "buildSettings": ["PRODUCT_BUNDLE_IDENTIFIER": widgetBundleIdentifier],
      ],
      "WIDGET_RELEASE": [
        "isa": "XCBuildConfiguration",
        "name": "Release",
        "buildSettings": ["PRODUCT_BUNDLE_IDENTIFIER": widgetBundleIdentifier],
      ],
      "ORPHAN_APP": [
        "isa": "PBXNativeTarget",
        "name": "InkNotes",
        "productType": "com.apple.product-type.application",
        "buildConfigurationList": "ORPHAN_CONFIGURATIONS",
      ],
      "ORPHAN_CONFIGURATIONS": [
        "isa": "XCConfigurationList",
        "buildConfigurations": ["ORPHAN_DEBUG", "ORPHAN_RELEASE"],
      ],
      "ORPHAN_DEBUG": [
        "isa": "XCBuildConfiguration",
        "name": "Debug",
        "buildSettings": ["PRODUCT_BUNDLE_IDENTIFIER": orphanBundleIdentifier],
      ],
      "ORPHAN_RELEASE": [
        "isa": "XCBuildConfiguration",
        "name": "Release",
        "buildSettings": ["PRODUCT_BUNDLE_IDENTIFIER": orphanBundleIdentifier],
      ],
    ]
    return ["rootObject": "ROOT", "objects": objects]
  }

  private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
    (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
  }

  private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    var value: UInt32 = 0
    for index in 0..<4 {
      value = (value << 8) | UInt32(data[offset + index])
    }
    return value
  }

  private func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for index in 0..<8 {
      value = (value << 8) | UInt64(data[offset + index])
    }
    return value
  }
}
