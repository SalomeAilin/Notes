import CoreFoundation
import CryptoKit
import Foundation
import PencilKit
import Testing

@testable import InkNotesCore

@Suite("InkNotes compatibility contract")
struct CompatibilityContractTests {
  private let expectedBundleIdentifier = "com.salomeailin.InkNotes"
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
    #expect(DrawingRepository.pageSourcesDirectoryName == "PageSources")
    #expect(DrawingRepository.pageSourceFileExtension == "json")
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
    #expect(BackupArchiveCodec.legacyFormatVersion == 1)
    #expect(BackupArchiveCodec.currentFormatVersion == 2)
    #expect(BackupArchiveCodec.headerByteCount == 56)
    #expect(LibraryDocument.currentSchemaVersion == 1)
    #expect(PageSourceDocument.currentVersion == 1)
  }

  @Test("User-facing recovery messages explain outcomes without implementation jargon")
  func recoveryMessagesStayUserCentered() throws {
    let messages = [
      BackupArchiveError.archiveTooLarge(actual: 2, maximum: 1).localizedDescription,
      BackupArchiveError.unsupportedVersion(found: 2).localizedDescription,
      BackupArchiveError.manifestTooLarge(actual: 2, maximum: 1).localizedDescription,
      BackupArchiveError.invalidDrawingDigest(pageID: blankPageID).localizedDescription,
      BackupArchiveError.drawingTooLarge(
        pageID: blankPageID,
        actual: 2,
        maximum: 1
      ).localizedDescription,
      BackupSnapshotError.invalidDrawing.localizedDescription,
      BackupSnapshotError.backupIdentityConflict.localizedDescription,
      BackupFileReaderError.symbolicLink.localizedDescription,
      BackupFileReaderError.fileTooLarge(maximum: 1).localizedDescription,
      DrawingRepositoryError.unsupportedSchema(found: 2).localizedDescription,
      DurableFileWriterError.invalidStoreLayout.localizedDescription,
      SegmentedDrawingError.invalidAuthority.localizedDescription,
      SegmentedDrawingError.tooManyEntries(actual: 2, maximum: 1).localizedDescription,
    ]
    let implementationTerms = [
      "PencilKit", "UTF-8", "字节", "分段", "索引", "摘要", "符号链接", "沙盒", "HTTP", "SHA",
    ]
    for message in messages {
      #expect(!message.isEmpty)
      for term in implementationTerms {
        #expect(!message.localizedCaseInsensitiveContains(term))
      }
    }

    let repositoryRoot = repositoryRootURL()
    let storeSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent("InkNotes/Stores/LibraryStore.swift"),
      encoding: .utf8
    )
    let libraryViewSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent("InkNotes/Views/LibrarySplitView.swift"),
      encoding: .utf8
    )
    #expect(!storeSource.contains("名称过长：最多允许"))
    #expect(!libraryViewSource.contains("应用沙盒"))
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
    let conformingTypes = try #require(declaration["UTTypeConformsTo"] as? [String])
    let tags = try #require(declaration["UTTypeTagSpecification"] as? [String: Any])
    let extensions = try #require(tags["public.filename-extension"] as? [String])
    let documentTypes = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
    let documentType = try #require(documentTypes.first)
    let documentContentTypes = try #require(documentType["LSItemContentTypes"] as? [String])
    let sceneManifest = try #require(plist["UIApplicationSceneManifest"] as? [String: Any])
    let iPadOrientations = try #require(
      plist["UISupportedInterfaceOrientations~ipad"] as? [String]
    )

    #expect(declarations.count == 1)
    #expect(declaration["UTTypeIdentifier"] as? String == BackupArchiveCodec.uniformTypeIdentifier)
    #expect(Set(conformingTypes) == Set(["public.content", "public.data"]))
    #expect(extensions == [BackupArchiveCodec.fileExtension])
    #expect(tags["public.mime-type"] as? String == BackupArchiveCodec.mimeType)
    #expect(documentTypes.count == 1)
    #expect(documentType["CFBundleTypeName"] as? String == "笔记备份")
    #expect(documentType["CFBundleTypeRole"] as? String == "Viewer")
    #expect(documentType["LSHandlerRank"] as? String == "Alternate")
    #expect(documentContentTypes == [BackupArchiveCodec.uniformTypeIdentifier])
    #expect(plist["LSSupportsOpeningDocumentsInPlace"] as? Bool == false)
    #expect(isPropertyListBoolean(sceneManifest["UIApplicationSupportsMultipleScenes"]))
    #expect(sceneManifest["UIApplicationSupportsMultipleScenes"] as? Bool == false)
    #expect(isPropertyListBoolean(plist["UIApplicationSupportsIndirectInputEvents"]))
    #expect(plist["UIApplicationSupportsIndirectInputEvents"] as? Bool == true)
    #expect(plist["UIRequiresFullScreen"] == nil)
    #expect(
      iPadOrientations == [
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationPortraitUpsideDown",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
      ]
    )

    let projectURL = repositoryRoot.appendingPathComponent("InkNotes.xcodeproj/project.pbxproj")
    let projectData = try Data(contentsOf: projectURL)
    let project = try #require(
      try PropertyListSerialization.propertyList(from: projectData, options: [], format: nil)
        as? [String: Any]
    )
    _ = try validateMainAppBundleIdentifiers(in: project)
  }

  private func isPropertyListBoolean(_ value: Any?) -> Bool {
    guard let value else { return false }
    return CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
  }

  private func mainAppSourceRelativePaths(
    in project: [String: Any]
  ) throws -> [String] {
    guard let rootObjectID = project["rootObject"] as? String,
      let objects = project["objects"] as? [String: Any],
      let rootProject = objects[rootObjectID] as? [String: Any],
      rootProject["isa"] as? String == "PBXProject",
      let targetIDs = rootProject["targets"] as? [String],
      let mainGroupID = rootProject["mainGroup"] as? String
    else {
      throw PBXProjectContractError.malformedProjectGraph
    }

    let appTargets = try targetIDs.compactMap { targetID -> [String: Any]? in
      guard let target = objects[targetID] as? [String: Any] else {
        throw PBXProjectContractError.malformedProjectGraph
      }
      guard target["isa"] as? String == "PBXNativeTarget",
        target["name"] as? String == "InkNotes",
        target["productType"] as? String == "com.apple.product-type.application"
      else {
        return nil
      }
      return target
    }
    guard appTargets.count == 1, let appTarget = appTargets.first,
      let buildPhaseIDs = appTarget["buildPhases"] as? [String]
    else {
      throw PBXProjectContractError.mainAppTargetCount(appTargets.count)
    }

    let sourcePhases = try buildPhaseIDs.compactMap { phaseID -> [String: Any]? in
      guard let phase = objects[phaseID] as? [String: Any] else {
        throw PBXProjectContractError.malformedProjectGraph
      }
      return phase["isa"] as? String == "PBXSourcesBuildPhase" ? phase : nil
    }
    guard sourcePhases.count == 1, let sourcePhase = sourcePhases.first,
      let buildFileIDs = sourcePhase["files"] as? [String],
      !buildFileIDs.isEmpty
    else {
      throw PBXProjectContractError.malformedProjectGraph
    }

    let fileReferencePaths = try fileReferenceRelativePaths(
      objects: objects,
      mainGroupID: mainGroupID
    )
    var sourcePaths = Set<String>()
    for buildFileID in buildFileIDs {
      guard let buildFile = objects[buildFileID] as? [String: Any],
        buildFile["isa"] as? String == "PBXBuildFile",
        let fileReferenceID = buildFile["fileRef"] as? String,
        let fileReference = objects[fileReferenceID] as? [String: Any],
        fileReference["isa"] as? String == "PBXFileReference",
        fileReference["lastKnownFileType"] as? String == "sourcecode.swift",
        let relativePath = fileReferencePaths[fileReferenceID],
        relativePath.hasSuffix(".swift"),
        sourcePaths.insert(relativePath).inserted
      else {
        throw PBXProjectContractError.malformedProjectGraph
      }
    }
    return sourcePaths.sorted()
  }

  private func mainAppDependencyInventory(
    in project: [String: Any]
  ) throws -> AppDependencyInventory {
    guard let rootObjectID = project["rootObject"] as? String,
      let objects = project["objects"] as? [String: Any],
      let rootProject = objects[rootObjectID] as? [String: Any],
      rootProject["isa"] as? String == "PBXProject",
      let targetIDs = rootProject["targets"] as? [String]
    else {
      throw PBXProjectContractError.malformedProjectGraph
    }
    let appTargets = try targetIDs.compactMap { targetID -> [String: Any]? in
      guard let target = objects[targetID] as? [String: Any] else {
        throw PBXProjectContractError.malformedProjectGraph
      }
      guard target["isa"] as? String == "PBXNativeTarget",
        target["name"] as? String == "InkNotes",
        target["productType"] as? String == "com.apple.product-type.application"
      else {
        return nil
      }
      return target
    }
    guard appTargets.count == 1, let appTarget = appTargets.first,
      let buildPhaseIDs = appTarget["buildPhases"] as? [String]
    else {
      throw PBXProjectContractError.mainAppTargetCount(appTargets.count)
    }

    let buildPhases = try buildPhaseIDs.map { phaseID -> [String: Any] in
      guard let phase = objects[phaseID] as? [String: Any],
        phase["isa"] as? String != nil
      else {
        throw PBXProjectContractError.malformedProjectGraph
      }
      return phase
    }
    let frameworkPhases = buildPhases.filter {
      $0["isa"] as? String == "PBXFrameworksBuildPhase"
    }
    guard frameworkPhases.count == 1,
      let frameworkBuildFileIDs = frameworkPhases.first?["files"] as? [String]
    else {
      throw PBXProjectContractError.malformedProjectGraph
    }

    let remotePackageObjectCount = objects.values.reduce(into: 0) { count, value in
      guard let object = value as? [String: Any],
        let isa = object["isa"] as? String
      else {
        return
      }
      if isa == "XCRemoteSwiftPackageReference" || isa == "XCSwiftPackageProductDependency" {
        count += 1
      }
    }
    return AppDependencyInventory(
      projectPackageReferenceCount: (rootProject["packageReferences"] as? [String])?.count ?? 0,
      appPackageProductDependencyCount: (appTarget["packageProductDependencies"] as? [String])?
        .count ?? 0,
      appTargetDependencyCount: (appTarget["dependencies"] as? [String])?.count ?? 0,
      frameworkBuildFileCount: frameworkBuildFileIDs.count,
      remotePackageObjectCount: remotePackageObjectCount,
      buildPhaseKinds: try buildPhases.map { phase in
        guard let isa = phase["isa"] as? String else {
          throw PBXProjectContractError.malformedProjectGraph
        }
        return isa
      }.sorted()
    )
  }

  private func fileReferenceRelativePaths(
    objects: [String: Any],
    mainGroupID: String
  ) throws -> [String: String] {
    var paths: [String: String] = [:]
    var visitedGroups = Set<String>()

    func validatedComponents(_ path: String?) throws -> [String] {
      guard let path, !path.isEmpty else { return [] }
      let components = path.split(separator: "/", omittingEmptySubsequences: false)
        .map(String.init)
      guard !path.hasPrefix("/"),
        components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
      else {
        throw PBXProjectContractError.malformedProjectGraph
      }
      return components
    }

    func visitGroup(_ groupID: String, parentComponents: [String]) throws {
      guard visitedGroups.insert(groupID).inserted,
        let group = objects[groupID] as? [String: Any],
        group["isa"] as? String == "PBXGroup",
        group["sourceTree"] as? String == "<group>",
        let childIDs = group["children"] as? [String]
      else {
        throw PBXProjectContractError.malformedProjectGraph
      }
      let groupComponents = parentComponents + (try validatedComponents(group["path"] as? String))

      for childID in childIDs {
        guard let child = objects[childID] as? [String: Any],
          let isa = child["isa"] as? String
        else {
          throw PBXProjectContractError.malformedProjectGraph
        }
        if isa == "PBXGroup" {
          try visitGroup(childID, parentComponents: groupComponents)
          continue
        }
        guard isa == "PBXFileReference",
          child["sourceTree"] as? String == "<group>",
          let filePath = child["path"] as? String
        else {
          continue
        }
        let relativePath = (groupComponents + (try validatedComponents(filePath)))
          .joined(separator: "/")
        guard !relativePath.isEmpty, paths.updateValue(relativePath, forKey: childID) == nil else {
          throw PBXProjectContractError.malformedProjectGraph
        }
      }
    }

    try visitGroup(mainGroupID, parentComponents: [])
    return paths
  }

  private func requiredReasonAPIOccurrences(in contents: String) -> [String: Int] {
    let code = SwiftSourceLexicalMasker.codeOnly(contents)
    let patternsByCategory = [
      "NSPrivacyAccessedAPICategoryFileTimestamp": [
        #"(?<![A-Za-z0-9_])(?:Darwin\.)?(?:stat|fstat|fstatat|lstat)\s*\((?!\s*\))"#,
        #"\b(?:creationDate|modificationDate|fileModificationDate|contentModificationDateKey|creationDateKey)\b"#,
      ],
      "NSPrivacyAccessedAPICategorySystemBootTime": [
        #"\bsystemUptime\b"#,
        #"(?<![A-Za-z0-9_])mach_absolute_time\s*\("#,
      ],
      "NSPrivacyAccessedAPICategoryDiskSpace": [
        #"\b(?:volumeAvailableCapacityKey|volumeAvailableCapacityForImportantUsageKey|volumeAvailableCapacityForOpportunisticUsageKey|volumeTotalCapacityKey|systemFreeSize|systemSize)\b"#,
        #"(?<![A-Za-z0-9_])(?:Darwin\.)?(?:statfs|statvfs|fstatfs|fstatvfs)\s*\((?!\s*\))"#,
      ],
      "NSPrivacyAccessedAPICategoryActiveKeyboards": [
        #"\bactiveInputModes\b"#
      ],
      "NSPrivacyAccessedAPICategoryUserDefaults": [
        #"(?:\bUserDefaults\b|@AppStorage\b|\bNSUserDefaults\b)"#
      ],
    ]

    var result = patternsByCategory.reduce(into: [String: Int]()) { result, entry in
      let count = entry.value.reduce(0) { partialResult, pattern in
        partialResult + regularExpressionMatchCount(pattern, in: code)
      }
      if count > 0 {
        result[entry.key] = count
      }
    }
    let ambiguousFileMetadataCount = regularExpressionMatchCount(
      #"(?<![A-Za-z0-9_])(?:getattrlist|fgetattrlist|getattrlistbulk|getattrlistat)\s*\("#,
      in: code
    )
    if ambiguousFileMetadataCount > 0 {
      result["MANUAL_REVIEW_REQUIRED_FOR_GETATTRLIST"] = ambiguousFileMetadataCount
    }
    return result
  }

  private func regularExpressionMatchCount(_ pattern: String, in contents: String) -> Int {
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      Issue.record("Invalid required-reason API inventory expression")
      return 0
    }
    return expression.numberOfMatches(
      in: contents,
      range: NSRange(contents.startIndex..<contents.endIndex, in: contents)
    )
  }

  @Test("Privacy manifest is structurally exact and covers current required-reason APIs")
  func privacyManifestCoversCurrentRequiredReasonAPIs() throws {
    let repositoryRoot = repositoryRootURL()
    let manifestData = try Data(
      contentsOf: repositoryRoot.appendingPathComponent("InkNotes/PrivacyInfo.xcprivacy")
    )
    let manifest = try #require(
      try PropertyListSerialization.propertyList(
        from: manifestData,
        options: [],
        format: nil
      ) as? [String: Any]
    )

    #expect(
      Set(manifest.keys)
        == Set([
          "NSPrivacyTracking",
          "NSPrivacyCollectedDataTypes",
          "NSPrivacyAccessedAPITypes",
        ])
    )
    #expect(isPropertyListBoolean(manifest["NSPrivacyTracking"]))
    #expect(manifest["NSPrivacyTracking"] as? Bool == false)
    #expect((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)

    let accessedAPITypes = try #require(
      manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
    )
    var reasonsByAPIType: [String: Set<String>] = [:]
    for declaration in accessedAPITypes {
      #expect(
        Set(declaration.keys)
          == Set([
            "NSPrivacyAccessedAPIType",
            "NSPrivacyAccessedAPITypeReasons",
          ])
      )
      let apiType = try #require(declaration["NSPrivacyAccessedAPIType"] as? String)
      let reasons = try #require(
        declaration["NSPrivacyAccessedAPITypeReasons"] as? [String]
      )
      #expect(reasons.count == Set(reasons).count)
      #expect(reasonsByAPIType[apiType] == nil)
      reasonsByAPIType[apiType] = Set(reasons)
    }

    #expect(accessedAPITypes.count == 2)
    #expect(
      reasonsByAPIType == [
        "NSPrivacyAccessedAPICategoryFileTimestamp": Set(["C617.1", "3B52.1"]),
        "NSPrivacyAccessedAPICategoryUserDefaults": Set(["CA92.1"]),
      ]
    )

    let projectData = try Data(
      contentsOf: repositoryRoot.appendingPathComponent("InkNotes.xcodeproj/project.pbxproj")
    )
    let project = try #require(
      try PropertyListSerialization.propertyList(
        from: projectData,
        options: [],
        format: nil
      ) as? [String: Any]
    )
    #expect(
      try mainAppDependencyInventory(in: project)
        == AppDependencyInventory(
          projectPackageReferenceCount: 0,
          appPackageProductDependencyCount: 0,
          appTargetDependencyCount: 0,
          frameworkBuildFileCount: 0,
          remotePackageObjectCount: 0,
          buildPhaseKinds: [
            "PBXFrameworksBuildPhase",
            "PBXResourcesBuildPhase",
            "PBXSourcesBuildPhase",
          ]
        )
    )
    let appSourcePaths = try mainAppSourceRelativePaths(in: project)
    let reviewedInventoryData = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "InkNotesCoreTests/Fixtures/PrivacyReviewedSources.json"
      )
    )
    let reviewedInventory = try #require(
      try JSONSerialization.jsonObject(with: reviewedInventoryData) as? [String: Any]
    )
    #expect(Set(reviewedInventory.keys) == Set(["schemaVersion", "buildInputs", "sources"]))
    #expect(reviewedInventory["schemaVersion"] as? Int == 1)
    let reviewedBuildInputDigests = try #require(
      reviewedInventory["buildInputs"] as? [String: String]
    )
    #expect(
      Set(reviewedBuildInputDigests.keys)
        == Set([
          "InkNotes.xcodeproj/project.pbxproj",
          "InkNotes/Info.plist",
          "Package.swift",
        ])
    )
    for (relativePath, reviewedDigest) in reviewedBuildInputDigests {
      let inputURL = repositoryRoot.appendingPathComponent(relativePath).standardizedFileURL
      let values = try inputURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        Issue.record("Privacy-reviewed build input is not a regular file: \(relativePath)")
        continue
      }
      #expect(
        sha256Hex(try Data(contentsOf: inputURL)) == reviewedDigest,
        "Build input changed without a refreshed privacy review: \(relativePath)"
      )
    }
    let reviewedSourceDigests = try #require(
      reviewedInventory["sources"] as? [String: String]
    )
    #expect(Set(reviewedSourceDigests.keys) == Set(appSourcePaths))

    var usagePathsByCategory: [String: Set<String>] = [:]
    for sourcePath in appSourcePaths {
      let sourceURL = repositoryRoot.appendingPathComponent(sourcePath).standardizedFileURL
      let resolvedSourceURL = sourceURL.resolvingSymlinksInPath()
      guard resolvedSourceURL.path.hasPrefix(repositoryRoot.resolvingSymlinksInPath().path + "/")
      else {
        Issue.record("Main app source path escaped the repository: \(sourcePath)")
        continue
      }
      let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        Issue.record("Main app source is not a regular, non-symlink file: \(sourcePath)")
        continue
      }
      let sourceData = try Data(contentsOf: sourceURL)
      #expect(
        reviewedSourceDigests[sourcePath] == sha256Hex(sourceData),
        "Production source changed without a refreshed privacy review: \(sourcePath)"
      )
      let contents = try #require(String(data: sourceData, encoding: .utf8))
      for (category, occurrenceCount) in requiredReasonAPIOccurrences(in: contents)
      where occurrenceCount > 0 {
        usagePathsByCategory[category, default: []].insert(sourcePath)
      }
    }

    #expect(
      usagePathsByCategory == [
        "NSPrivacyAccessedAPICategoryFileTimestamp": Set([
          "InkNotes/Persistence/BackupFileReader.swift",
          "InkNotes/Persistence/BaiduUploadReconciliationRepository.swift",
          "InkNotes/Persistence/DrawingRepository.swift",
          "InkNotes/Persistence/DurableFileWriter.swift",
        ]),
        "NSPrivacyAccessedAPICategoryUserDefaults": Set([
          "InkNotes/Views/PageEditorView.swift"
        ]),
      ]
    )
    #expect(Set(reasonsByAPIType.keys) == Set(usagePathsByCategory.keys))

    let transferSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent("InkNotes/Views/BackupTransferView.swift"),
      encoding: .utf8
    )
    #expect(transferSource.contains("应用不会主动上传笔记"))
    #expect(transferSource.contains("包括 iCloud 备份"))
    #expect(!transferSource.contains("备份才会离开本机"))

    let packageSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent("Package.swift"),
      encoding: .utf8
    )

    #expect(packageSource.contains("\"PrivacyInfo.xcprivacy\""))
    #expect(!packageSource.contains(".package("))
    #expect(!packageSource.contains(".binaryTarget("))
    #expect(!packageSource.contains(".systemLibrary("))
  }

  @Test("Required-reason API inventory recognizes every Apple category")
  func requiredReasonAPIInventoryNegativeControls() {
    let samples = [
      (
        "Darwin.fstat(descriptor, &status)",
        "NSPrivacyAccessedAPICategoryFileTimestamp"
      ),
      (
        "ProcessInfo.processInfo.systemUptime",
        "NSPrivacyAccessedAPICategorySystemBootTime"
      ),
      (
        "URLResourceKey.volumeAvailableCapacityKey",
        "NSPrivacyAccessedAPICategoryDiskSpace"
      ),
      (
        "UITextInputMode.activeInputModes",
        "NSPrivacyAccessedAPICategoryActiveKeyboards"
      ),
      (
        "@AppStorage(\"preference\") var preference = true",
        "NSPrivacyAccessedAPICategoryUserDefaults"
      ),
    ]

    for (source, expectedCategory) in samples {
      #expect(requiredReasonAPIOccurrences(in: source) == [expectedCategory: 1])
    }
    #expect(
      requiredReasonAPIOccurrences(in: "getattrlist(path, attributes)")
        == ["MANUAL_REVIEW_REQUIRED_FOR_GETATTRLIST": 1]
    )
    #expect(requiredReasonAPIOccurrences(in: "var status = stat()").isEmpty)
    #expect(requiredReasonAPIOccurrences(in: "// UserDefaults.standard").isEmpty)
    #expect(requiredReasonAPIOccurrences(in: "/* UserDefaults.standard */").isEmpty)
    #expect(
      requiredReasonAPIOccurrences(
        in: "/* outer /* UserDefaults.standard */ comment */"
      ).isEmpty
    )
    #expect(requiredReasonAPIOccurrences(in: #"let label = "mach_absolute_time()""#).isEmpty)
    #expect(
      requiredReasonAPIOccurrences(
        in: #"let label = "\(UserDefaults.standard)""#
      ) == ["NSPrivacyAccessedAPICategoryUserDefaults": 1]
    )
    #expect(
      requiredReasonAPIOccurrences(
        in: ##"let label = #"UserDefaults.standard"#"##
      ).isEmpty
    )
    #expect(
      requiredReasonAPIOccurrences(
        in: ##"let label = #"\#(UserDefaults.standard)"#"##
      ) == ["NSPrivacyAccessedAPICategoryUserDefaults": 1]
    )
    let multilineLiteral = "let label = " + "\"\"\"" + "\nUserDefaults.standard\n" + "\"\"\""
    let multilineInterpolation =
      "let label = " + "\"\"\"" + "\n\\(UserDefaults.standard)\n" + "\"\"\""
    #expect(requiredReasonAPIOccurrences(in: multilineLiteral).isEmpty)
    #expect(
      requiredReasonAPIOccurrences(in: multilineInterpolation)
        == ["NSPrivacyAccessedAPICategoryUserDefaults": 1]
    )
  }

  @Test("External backup URLs route to validation before restore confirmation")
  func externalBackupRoutingRemainsPreviewOnly() throws {
    let repositoryRoot = repositoryRootURL()
    let appSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent("InkNotes/App/InkNotesApp.swift"),
      encoding: .utf8
    )
    let librarySource = try String(
      contentsOf: repositoryRoot.appendingPathComponent("InkNotes/Views/LibrarySplitView.swift"),
      encoding: .utf8
    )
    let transferSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent("InkNotes/Views/BackupTransferView.swift"),
      encoding: .utf8
    )
    let readerSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "InkNotes/Persistence/BackupFileReader.swift"
      ),
      encoding: .utf8
    )

    #expect(appSource.contains(".onOpenURL"))
    #expect(appSource.contains("BackupImportRequest(url: url, source: .externalOpen)"))
    #expect(appSource.contains("pendingBackupImports.enqueue(request)"))
    #expect(!appSource.contains("importBackupAsCopy"))
    #expect(librarySource.contains("BackupTransferView(importQueue:"))
    #expect(
      librarySource.contains(
        "handleBackupImportPresentationEvent(.presentationStateChanged)"
      )
    )
    #expect(librarySource.contains("handleBackupImportPresentationEvent(.queueChanged)"))
    #expect(librarySource.contains("hasQueuedImport: !pendingBackupImports.isEmpty"))
    #expect(!librarySource.contains("importBackupAsCopy"))
    #expect(transferSource.contains(".task(id: importQueue.current?.id)"))
    #expect(transferSource.contains("await handleQueuedImportRequest(request)"))
    #expect(transferSource.contains("BackupImportRequest(url: url, source: .fileImporter)"))
    #expect(
      transferSource.contains(
        "presentFilePickerFailure(error, action: \"导出备份失败\")"
      )
    )
    #expect(
      transferSource.contains(
        "presentFilePickerFailure(error, action: \"读取备份失败\")"
      )
    )
    #expect(
      transferSource.contains(
        "BackupFilePickerFailurePolicy.disposition(for: error) == .report"
      )
    )
    #expect(transferSource.contains("while !canInspectNewBackup"))
    #expect(transferSource.contains("canStartOperation && pendingImport == nil && notice == nil"))
    #expect(transferSource.contains("guard outcome == .consumed else { continue }"))
    #expect(transferSource.contains("!isImporterPresented && !isExporterPresented"))
    #expect(transferSource.contains("clearQueuedImportRequest(ifMatching: request.id)"))
    #expect(
      transferSource.contains(
        "inspectSelectedBackup(at: request.url, source: request.source)"
      )
    )
    #expect(transferSource.contains("BackupInboxCopyCleaner().removeIfInboxCopy"))
    #expect(transferSource.contains(".confirmationDialog("))
    #expect(transferSource.contains("Button(\"作为副本导入\")"))
    #expect(transferSource.contains(".interactiveDismissDisabled(isBusy)"))
    #expect(readerSource.contains("NSFileCoordinator(filePresenter: nil)"))
    #expect(readerSource.contains("O_RDONLY | O_CLOEXEC | O_NOFOLLOW"))
    #expect(readerSource.contains("Darwin.unlink(path)"))
  }

  @Test("File export and system sharing reuse one immutable backup artifact")
  func backupExportSurfacesShareOneArtifact() throws {
    let repositoryRoot = repositoryRootURL()
    let transferSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent("InkNotes/Views/BackupTransferView.swift"),
      encoding: .utf8
    )

    #expect(transferSource.contains("let artifact: BackupExportArtifact"))
    #expect(transferSource.contains("BackupTransferItem(artifact: artifact)"))
    #expect(
      transferSource.contains(
        """
        DataRepresentation(exportedContentType: .notesBackup) { item in
              item.artifact.data
            }
            .suggestedFileName { item in
              item.artifact.filename
            }
        """
      )
    )
    #expect(
      transferSource.contains(
        """
        .fileExporter(
              isPresented: $isExporterPresented,
              item: preparedBackup?.transferItem,
              contentTypes: [.notesBackup],
              defaultFilename: preparedBackup?.artifact.filename
        """
      )
    )
    #expect(
      transferSource.contains(
        """
        ShareLink(
                  item: preparedBackup.transferItem,
                  subject: Text("未加密的笔记备份"),
        """
      )
    )
    #expect(
      transferSource.contains(
        "exportedAs: BackupExportArtifact.uniformTypeIdentifier"
      )
    )
    #expect(transferSource.contains("此文件未加密，包含笔记名称和原始笔迹"))
    #expect(!transferSource.contains("BackupArchiveCodec.uniformTypeIdentifier"))
    #expect(!transferSource.contains("private func backupFilename"))
  }

  @Test("The running app version is Bundle-driven and included in both build graphs")
  func runtimeVersionIsVisible() throws {
    let repositoryRoot = repositoryRootURL()
    let modelSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "InkNotes/Models/AppBuildIdentity.swift"
      ),
      encoding: .utf8
    )
    let transferSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent("InkNotes/Views/BackupTransferView.swift"),
      encoding: .utf8
    )
    let projectSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent("InkNotes.xcodeproj/project.pbxproj"),
      encoding: .utf8
    )
    let packageSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent("Package.swift"),
      encoding: .utf8
    )

    #expect(modelSource.contains("CFBundleShortVersionString"))
    #expect(modelSource.contains("CFBundleVersion"))
    #expect(transferSource.contains("Section(\"应用信息\")"))
    #expect(transferSource.contains("Text(AppBuildIdentity.current().displayText)"))
    #expect(!transferSource.contains("版本 0.2.0"))
    #expect(projectSource.contains("AppBuildIdentity.swift in Sources"))
    #expect(packageSource.contains("\"Models/AppBuildIdentity.swift\""))
  }

  @Test("Buildable product derives one audited internal placeholder from stable identity")
  func buildableProductDerivesOneAuditedInternalPlaceholder() throws {
    let repositoryRoot = repositoryRootURL()
    let plistURL = repositoryRoot.appendingPathComponent("InkNotes/Info.plist")
    let plistData = try Data(contentsOf: plistURL)
    let plist = try #require(
      try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
        as? [String: Any]
    )
    let displayName = try #require(plist["CFBundleDisplayName"] as? String)
    let enforcementSourcePaths = [
      "InkNotesCoreTests/CompatibilityContractTests.swift",
      "scripts/verify-compatibility.sh",
      "scripts/build-signed-ipad-app.sh",
      "scripts/verify-ipad-readiness.sh",
      "scripts/install-ipad-app.sh",
      "scripts/internal-display-name-contract.zsh",
    ]

    #expect(isValidInternalDisplayName(displayName))
    for relativePath in enforcementSourcePaths {
      let source = try String(
        contentsOf: repositoryRoot.appendingPathComponent(relativePath),
        encoding: .utf8
      )
      #expect(!source.contains("\"\(displayName)\""))
      #expect(!source.contains("'\(displayName)'"))
    }

    for relativePath in enforcementSourcePaths.filter({ $0.hasPrefix("scripts/") }) {
      let source = try String(
        contentsOf: repositoryRoot.appendingPathComponent(relativePath),
        encoding: .utf8
      )
      if relativePath != "scripts/internal-display-name-contract.zsh" {
        #expect(source.contains("notes_read_internal_placeholder_display_name"))
      }
    }

    let displayNameContractSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "scripts/internal-display-name-contract.zsh"
      ),
      encoding: .utf8
    )
    #expect(displayNameContractSource.contains("notes_read_validated_display_name"))
    #expect(
      displayNameContractSource.contains("notes_read_internal_placeholder_display_name")
    )
    #expect(displayNameContractSource.contains("notes_expected_bundle_identifier##*."))

    let signedBuildSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent("scripts/build-signed-ipad-app.sh"),
      encoding: .utf8
    )
    let readinessSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent("scripts/verify-ipad-readiness.sh"),
      encoding: .utf8
    )
    let compatibilitySource = try String(
      contentsOf: repositoryRoot.appendingPathComponent("scripts/verify-compatibility.sh"),
      encoding: .utf8
    )
    #expect(signedBuildSource.contains("$notes_source_root/InkNotes/Info.plist"))
    #expect(readinessSource.contains("git cat-file blob"))
    #expect(readinessSource.contains(":InkNotes/Info.plist"))
    #expect(readinessSource.contains(":InkNotes/PrivacyInfo.xcprivacy"))
    #expect(
      readinessSource.contains(
        "Built privacy manifest does not match the provenance commit"
      )
    )
    #expect(compatibilitySource.contains("INFOPLIST_KEY_CFBundleDisplayName"))
    #expect(compatibilitySource.contains("INFOPLIST_PREPROCESS"))
    #expect(compatibilitySource.contains("notes_assert_no_localized_display_name_override"))
  }

  @Test("Internal display-name validation fails closed")
  func internalDisplayNameValidationFailsClosed() {
    #expect(isValidInternalDisplayName("Valid Internal Name"))

    let invalidDisplayNames = [
      "",
      "   ",
      " Valid Internal Name",
      "Valid Internal Name ",
      "\u{3000}Valid Internal Name",
      "Valid Internal Name\u{3000}",
      "Valid\nInternal Name",
      "Valid\tInternal Name",
      "Valid\u{200B}Internal Name",
      "Valid\u{202E}Internal Name",
      "Valid\u{2066}Internal Name",
      "$(",
      "${",
      "$(PRODUCT_NAME)",
      "${PRODUCT_NAME}",
      "prefix墨记suffix",
      "prefix墨記suffix",
      "prefix墨计suffix",
      "prefix墨計suffix",
    ]
    for displayName in invalidDisplayNames {
      #expect(!isValidInternalDisplayName(displayName))
    }
  }

  private func isValidInternalDisplayName(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
      return false
    }
    guard
      value.unicodeScalars.allSatisfy({
        !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
      })
    else {
      return false
    }
    guard !value.contains("$("), !value.contains("${") else { return false }
    return ["墨记", "墨記", "墨计", "墨計"].allSatisfy { !value.contains($0) }
  }

  @Test("The PencilKit tool picker belongs to the cross-page editor controller")
  func pencilToolPickerLifetimeRemainsCrossPage() throws {
    let repositoryRoot = repositoryRootURL()
    let canvasSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "InkNotes/Views/Canvas/PencilCanvas.swift"
      ),
      encoding: .utf8
    )
    let editorSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "InkNotes/Views/PageEditorView.swift"
      ),
      encoding: .utf8
    )
    let controllerStart = try #require(
      canvasSource.range(of: "final class PencilCanvasController")
    )
    let representableStart = try #require(
      canvasSource.range(of: "struct PencilCanvas: UIViewRepresentable")
    )
    let coordinatorStart = try #require(
      canvasSource.range(of: "final class Coordinator: NSObject, PKCanvasViewDelegate")
    )
    let controllerSource = String(
      canvasSource[controllerStart.lowerBound..<representableStart.lowerBound]
    )
    let coordinatorSource = String(canvasSource[coordinatorStart.lowerBound...])
    let detachStart = try #require(controllerSource.range(of: "func detach"))
    let visibilityStart = try #require(
      controllerSource.range(of: "func setToolPickerVisible")
    )
    let detachSource = String(
      controllerSource[detachStart.lowerBound..<visibilityStart.lowerBound]
    )
    let identityGuard = try #require(
      detachSource.range(of: "guard self.canvasHost === canvasHost")
    )
    let requiredPreGuardCleanup = [
      "toolPicker.setVisible(false, forFirstResponder: canvasView)",
      "canvasView.resignFirstResponder()",
      "toolPicker.removeObserver(canvasView)",
    ]

    #expect(canvasSource.components(separatedBy: "PKToolPicker()").count - 1 == 1)
    #expect(controllerSource.contains("private let toolPicker: PKToolPicker"))
    #expect(controllerSource.contains("toolPicker.addObserver(canvasHost.canvasView)"))
    #expect(controllerSource.contains("toolPicker.setVisible(isVisible"))
    for statement in requiredPreGuardCleanup {
      let cleanup = try #require(detachSource.range(of: statement))
      #expect(cleanup.upperBound <= identityGuard.lowerBound)
    }
    #expect(canvasSource.contains("controller.attach(canvasHost, pageID: pageID)"))
    #expect(canvasSource.contains("controller.setToolPickerVisible(isEditable, for: canvasHost)"))
    #expect(canvasSource.contains("controller.detach(canvasHost, pageID:"))
    #expect(!canvasSource.contains("context.coordinator.toolPicker"))
    #expect(!coordinatorSource.contains("PKToolPicker"))
    #expect(controllerSource.contains("viewports[pageID] = canvasHost.currentViewport"))
    #expect(editorSource.contains("@StateObject private var canvasController"))
    #expect(editorSource.contains(".id(page.id)"))
  }

  @Test("The writing surface grows as continuous paper without exposing storage details")
  func writingSurfaceRemainsUserLed() throws {
    let repositoryRoot = repositoryRootURL()
    let canvasSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "InkNotes/Views/Canvas/PencilCanvas.swift"
      ),
      encoding: .utf8
    )
    let editorSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "InkNotes/Views/PageEditorView.swift"
      ),
      encoding: .utf8
    )

    #expect(canvasSource.contains("final class ExpandablePencilCanvasView"))
    #expect(canvasSource.contains("ContinuousCanvasGeometry.requiredContentHeight"))
    #expect(canvasSource.contains("drawingMaximumY: canvasView.drawing.bounds.maxY"))
    #expect(canvasSource.contains("scrollView.minimumZoomScale = 0.65"))
    #expect(canvasSource.contains("scrollView.maximumZoomScale = 3"))
    #expect(canvasSource.contains("inputPolicy == .anyInput ? 2 : 1"))
    #expect(canvasSource.contains("contentView.addSubview(paperView)"))
    #expect(canvasSource.contains("contentView.addSubview(canvasView)"))
    #expect(editorSource.contains("pageID: page.id"))
    #expect(editorSource.contains("background: page.background"))
    #expect(!editorSource.contains("PageBackgroundView(background:"))
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
    let installScript = try String(
      contentsOf: repositoryRoot.appendingPathComponent("scripts/install-ipad-app.sh"),
      encoding: .utf8
    )
    let materializerScript = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "scripts/materialize-exact-git-source.zsh"
      ),
      encoding: .utf8
    )
    for script in [buildScript, readinessScript, installScript, materializerScript] {
      #expect(!script.contains("-allowProvisioningUpdates"))
      #expect(!script.contains("-allowProvisioningDeviceRegistration"))
    }
    #expect(buildScript.contains("TeamIdentifier.0"))
    #expect(buildScript.contains("notes_assert_clean_worktree initial"))
    #expect(buildScript.contains("status --porcelain=v1 --untracked-files=all"))
    #expect(buildScript.contains("scripts/materialize-exact-git-source.zsh"))
    #expect(buildScript.contains("--commit \"$notes_source_commit\""))
    #expect(buildScript.contains("cmp -s \"$notes_script_path\""))
    #expect(buildScript.contains("-project \"$notes_source_root/InkNotes.xcodeproj\""))
    #expect(!buildScript.contains("-project InkNotes.xcodeproj"))
    #expect(!buildScript.contains("PROVISIONING_PROFILE_SPECIFIER="))
    #expect(buildScript.contains("CODE_SIGN_STYLE=Automatic"))
    #expect(buildScript.contains("notes_actual_profile_uuid\" == \"$notes_selected_uuid"))
    #expect(buildScript.contains("notes_actual_profile_sha256\" == \"$notes_selected_sha256"))
    #expect(buildScript.contains("embeddedProfileSHA256"))
    #expect(buildScript.contains("notes_output_relative"))
    #expect(buildScript.contains("INKNOTES_READINESS_REPOSITORY_ROOT=\"$notes_repository_root\""))
    #expect(buildScript.contains("zsh \"$notes_committed_readiness_script\""))
    #expect(readinessScript.contains("codesign --verify --deep --strict"))
    #expect(readinessScript.contains("codesign -d --entitlements :-"))
    #expect(readinessScript.contains("com\\.apple\\.developer\\.team-identifier"))
    #expect(readinessScript.contains("ProvisionedDevices"))
    #expect(readinessScript.contains("embeddedProfileSHA256"))
    #expect(readinessScript.contains("/usr/bin/git --no-replace-objects"))
    #expect(readinessScript.contains("cmp -s \"$notes_script_path\""))
    #expect(readinessScript.contains("INKNOTES_READINESS_REPOSITORY_ROOT"))
    #expect(readinessScript.contains("notes_device_connection_state"))
    #expect(readinessScript.contains("devicectl.list.devices"))
    #expect(readinessScript.contains("com.apple.coredevice.feature.installapp"))
    #expect(readinessScript.contains("--device-handoff"))
    #expect(readinessScript.contains(".result.devices[0].identifier"))
    #expect(readinessScript.contains("/usr/bin/xcrun devicectl list devices"))
    let deviceCountClassification = [
      "  case \"$notes_device_count\" in",
      "    0) fail \"No device has the exact requested name\" ;;",
      "    1) ;;",
      "    <->) fail \"The requested device name is not unique\" ;;",
      "    *) fail \"Device count is invalid\" ;;",
      "  esac",
    ].joined(separator: "\n")
    #expect(readinessScript.contains(deviceCountClassification))
    #expect(
      readinessScript.contains("Returned device name does not exactly match the request")
    )
    #expect(
      !readinessScript.contains(
        "[[ \"$notes_device_count\" == \"1\" ]] || fail \"The requested device name is not unique\""
      )
    )
    #expect(
      readinessScript.components(separatedBy: "xcrun devicectl list devices").count - 1 == 1
    )
    #expect(installScript.contains("notes_should_launch=false"))
    #expect(installScript.contains("--launch)"))
    #expect(installScript.contains("notes_assert_clean_worktree"))
    #expect(installScript.contains("notes_exact_head_matches_provenance"))
    #expect(installScript.contains("cmp -s \"$notes_script_path\""))
    #expect(installScript.contains("zsh \"$notes_readiness_script\""))
    #expect(installScript.contains("--device-handoff \"$notes_device_handoff_path\""))
    #expect(installScript.contains("notes_device_selector"))
    #expect(installScript.contains("unset notes_device_name notes_device_name_lower"))
    #expect(
      installScript.components(separatedBy: "zsh \"$notes_readiness_script\"").count - 1
        == 1
    )
    #expect(
      installScript.components(separatedBy: "xcrun devicectl device install app").count - 1
        == 1
    )
    #expect(
      installScript.components(separatedBy: "xcrun devicectl device info apps").count - 1
        == 1
    )
    #expect(
      installScript.components(separatedBy: "xcrun devicectl device process launch").count - 1
        == 1
    )
    #expect(installScript.contains(".result.installedApplications | length == 1"))
    #expect(installScript.contains(".result.apps | length == 1"))
    #expect(installScript.contains(".result.apps[0].bundleIdentifier == $bundle"))
    #expect(installScript.contains(".result.apps[0].version == $version"))
    #expect(installScript.contains(".result.apps[0].bundleVersion == $build"))
    #expect(installScript.contains(".result.apps[0].name == $name"))
    #expect(installScript.contains("--launch-persistent-identifier"))
    #expect(installScript.contains("The user did not explicitly trust the provisioning profile"))
    #expect(
      !installScript.contains("|profile has not been explicitly trusted by the user")
    )
    #expect(
      installScript.components(separatedBy: "/usr/bin/xcrun devicectl").count - 1 == 3
    )
    #expect(!installScript.contains("\nxcrun devicectl"))
    #expect(
      installScript.components(separatedBy: "--device \"$notes_device_selector\"").count - 1
        == 3
    )
    #expect(
      installScript.components(separatedBy: "notes_exact_head_matches_provenance").count - 1
        == 4
    )
    #expect(installScript.contains("embedded development profile expires in"))
    #expect(installScript.contains("exit 7"))
    #expect(!installScript.contains("devicectl device uninstall"))
    #expect(!installScript.contains("devicectl device process terminate"))
    #expect(!installScript.contains("--terminate-existing"))
    #expect(!installScript.contains("--json-output -"))
    #expect(!installScript.contains("set -x"))
    for sensitiveMarker in ["serialNumber", "hardware.udid", "hardware.ecid"] {
      #expect(!installScript.contains(sensitiveMarker))
    }
    let readinessInvocation = try #require(
      installScript.range(of: "zsh \"$notes_readiness_script\"")
    )
    let installInvocation = try #require(
      installScript.range(of: "xcrun devicectl device install app")
    )
    let readbackInvocation = try #require(
      installScript.range(of: "xcrun devicectl device info apps")
    )
    let launchInvocation = try #require(
      installScript.range(of: "xcrun devicectl device process launch")
    )
    #expect(readinessInvocation.upperBound <= installInvocation.lowerBound)
    #expect(installInvocation.upperBound <= readbackInvocation.lowerBound)
    #expect(readbackInvocation.upperBound <= launchInvocation.lowerBound)
    #expect(materializerScript.contains("GIT_OBJECT_DIRECTORY=\"$notes_object_directory\""))
    #expect(materializerScript.contains("GIT_NO_REPLACE_OBJECTS=1"))
    #expect(materializerScript.contains("GIT_ATTR_NOSYSTEM=1"))
    #expect(materializerScript.contains("GIT_CONFIG_GLOBAL=/dev/null"))
    #expect(materializerScript.contains("core.attributesFile=/dev/null"))
    #expect(materializerScript.contains("ls-tree -rz --full-tree"))
    #expect(materializerScript.contains("hash-object --no-filters"))
    #expect(materializerScript.contains("$mode eq \"120000\" || $mode eq \"160000\""))
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

  private struct AppDependencyInventory: Equatable {
    let projectPackageReferenceCount: Int
    let appPackageProductDependencyCount: Int
    let appTargetDependencyCount: Int
    let frameworkBuildFileCount: Int
    let remotePackageObjectCount: Int
    let buildPhaseKinds: [String]
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
