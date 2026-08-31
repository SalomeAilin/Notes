import CryptoKit
import Foundation
import PencilKit

enum SegmentedDrawingLimits {
  static let segmentHeight = 4_096
  static let maximumStrokeCountPerShard = 256
  static let maximumSegmentByteCount = 4 * 1024 * 1024
  static let maximumAuthorityByteCount = 2 * 1024 * 1024
  static let maximumEntryCount = 20_000
  static let maximumReconstructedDrawingByteCount = 64 * 1024 * 1024
  static let activationDrawingByteCount = 1024 * 1024
  static let maximumSourceChunkCount =
    maximumReconstructedDrawingByteCount / maximumSegmentByteCount
}

struct DrawingSegmentEntry: Codable, Equatable, Sendable {
  let sequenceIndex: Int
  let regionIndex: Int
  let minimumY: Double
  let maximumY: Double
  let byteCount: UInt64
  let sha256: String
}

struct DrawingSourceChunk: Codable, Equatable, Sendable {
  let sequenceIndex: Int
  let byteCount: UInt64
  let sha256: String
}

struct SegmentedDrawingAuthority: Codable, Equatable, Sendable {
  static let currentVersion = 1

  let version: Int
  let pageID: UUID
  let segmentHeight: Int
  let sourceChunks: [DrawingSourceChunk]
  let entries: [DrawingSegmentEntry]

  init(
    version: Int = SegmentedDrawingAuthority.currentVersion,
    pageID: UUID,
    segmentHeight: Int = SegmentedDrawingLimits.segmentHeight,
    sourceChunks: [DrawingSourceChunk],
    entries: [DrawingSegmentEntry]
  ) {
    self.version = version
    self.pageID = pageID
    self.segmentHeight = segmentHeight
    self.sourceChunks = sourceChunks
    self.entries = entries
  }
}

struct SegmentedDrawingSnapshot: Equatable, Sendable {
  let authorityData: Data
  let authority: SegmentedDrawingAuthority
  let blobsBySHA256: [String: Data]
}

enum SegmentedDrawingError: LocalizedError, Equatable {
  case invalidDrawing
  case invalidAuthority
  case authorityTooLarge(actual: Int, maximum: Int)
  case tooManyEntries(actual: Int, maximum: Int)
  case segmentTooLarge(actual: Int, maximum: Int)
  case invalidSegmentDigest
  case missingSegment(String)
  case segmentByteCountMismatch
  case segmentChecksumMismatch
  case reconstructedDrawingTooLarge(actual: Int, maximum: Int)

  var errorDescription: String? {
    switch self {
    case .invalidDrawing:
      "这页笔迹暂时无法安全整理，原笔记没有改动。"
    case .invalidAuthority:
      "这页笔迹无法完整确认，已停止读取以保护原笔记。"
    case .authorityTooLarge:
      "这页笔迹的记录异常增大，已停止处理以保护原笔记。"
    case .tooManyEntries:
      "这页内容较多，当前版本已停止处理以保护原笔记。"
    case .segmentTooLarge:
      "这页的局部笔迹过于密集，当前版本无法安全整理，原笔记没有改动。"
    case .invalidSegmentDigest, .segmentByteCountMismatch, .segmentChecksumMismatch:
      "这页笔迹的局部内容未通过完整性检查，已停止读取。"
    case .missingSegment:
      "这页笔迹缺少局部内容，已停止读取以避免显示不完整笔记。"
    case .reconstructedDrawingTooLarge:
      "这页内容较多，当前版本无法一次完整打开，原笔记没有改动。"
    }
  }
}

enum SegmentedDrawingCodec {
  static let magic = Data([0x49, 0x4E, 0x4B, 0x53, 0x45, 0x47, 0x00, 0x01])
  static let headerByteCount = 44

  static func isSegmentedAuthority(_ data: Data) -> Bool {
    data.count >= magic.count && data.prefix(magic.count) == magic
  }

  static func shouldUseSegmentedStorage(drawingData: Data) throws -> Bool {
    let drawing: PKDrawing
    do {
      drawing = drawingData.isEmpty ? PKDrawing() : try PKDrawing(data: drawingData)
    } catch {
      throw SegmentedDrawingError.invalidDrawing
    }
    if drawingData.count >= SegmentedDrawingLimits.activationDrawingByteCount {
      return true
    }
    guard !drawing.strokes.isEmpty,
      !drawing.bounds.isNull,
      drawing.bounds.maxY.isFinite
    else {
      return false
    }
    return drawing.bounds.maxY >= Double(SegmentedDrawingLimits.segmentHeight)
  }

  static func makeSnapshot(pageID: UUID, drawingData: Data) throws -> SegmentedDrawingSnapshot {
    guard drawingData.count <= SegmentedDrawingLimits.maximumReconstructedDrawingByteCount else {
      throw SegmentedDrawingError.reconstructedDrawingTooLarge(
        actual: drawingData.count,
        maximum: SegmentedDrawingLimits.maximumReconstructedDrawingByteCount
      )
    }
    let drawing: PKDrawing
    do {
      drawing = drawingData.isEmpty ? PKDrawing() : try PKDrawing(data: drawingData)
    } catch {
      throw SegmentedDrawingError.invalidDrawing
    }

    let shards = try makeShards(from: drawing.strokes)
    let sourceChunks = makeSourceChunks(drawingData)
    var entries: [DrawingSegmentEntry] = []
    entries.reserveCapacity(shards.count)
    var blobsBySHA256: [String: Data] = [:]

    for chunk in sourceChunks {
      let rangeStart = chunk.sequenceIndex * SegmentedDrawingLimits.maximumSegmentByteCount
      let rangeEnd = rangeStart + Int(chunk.byteCount)
      blobsBySHA256[chunk.sha256] = drawingData.subdata(in: rangeStart..<rangeEnd)
    }

    for (sequenceIndex, shard) in shards.enumerated() {
      let data = PKDrawing(strokes: shard.strokes).dataRepresentation()
      guard data.count <= SegmentedDrawingLimits.maximumSegmentByteCount else {
        throw SegmentedDrawingError.segmentTooLarge(
          actual: data.count,
          maximum: SegmentedDrawingLimits.maximumSegmentByteCount
        )
      }
      let digest = sha256Hex(data)
      blobsBySHA256[digest] = data
      entries.append(
        DrawingSegmentEntry(
          sequenceIndex: sequenceIndex,
          regionIndex: shard.regionIndex,
          minimumY: shard.minimumY,
          maximumY: shard.maximumY,
          byteCount: UInt64(data.count),
          sha256: digest
        )
      )
    }

    guard entries.count <= SegmentedDrawingLimits.maximumEntryCount else {
      throw SegmentedDrawingError.tooManyEntries(
        actual: entries.count,
        maximum: SegmentedDrawingLimits.maximumEntryCount
      )
    }

    let authority = SegmentedDrawingAuthority(
      pageID: pageID,
      sourceChunks: sourceChunks,
      entries: entries
    )
    let manifestData = try encodeManifest(authority)
    let authorityData = try encodeAuthority(manifestData)
    return SegmentedDrawingSnapshot(
      authorityData: authorityData,
      authority: authority,
      blobsBySHA256: blobsBySHA256
    )
  }

  static func decodeAuthority(
    _ data: Data,
    expectedPageID: UUID
  ) throws -> SegmentedDrawingAuthority {
    guard data.count <= SegmentedDrawingLimits.maximumAuthorityByteCount else {
      throw SegmentedDrawingError.authorityTooLarge(
        actual: data.count,
        maximum: SegmentedDrawingLimits.maximumAuthorityByteCount
      )
    }
    guard data.count >= headerByteCount, isSegmentedAuthority(data) else {
      throw SegmentedDrawingError.invalidAuthority
    }

    let manifestByteCount = Int(readUInt32(data, at: magic.count))
    let (expectedByteCount, overflow) = headerByteCount.addingReportingOverflow(
      manifestByteCount
    )
    guard !overflow, expectedByteCount == data.count else {
      throw SegmentedDrawingError.invalidAuthority
    }
    let storedDigest = data.subdata(in: 12..<headerByteCount)
    let manifestData = data.suffix(from: headerByteCount)
    guard Data(SHA256.hash(data: manifestData)) == storedDigest else {
      throw SegmentedDrawingError.invalidAuthority
    }

    let authority: SegmentedDrawingAuthority
    do {
      authority = try makeDecoder().decode(
        SegmentedDrawingAuthority.self,
        from: manifestData
      )
      guard try encodeManifest(authority) == manifestData else {
        throw SegmentedDrawingError.invalidAuthority
      }
    } catch let error as SegmentedDrawingError {
      throw error
    } catch {
      throw SegmentedDrawingError.invalidAuthority
    }
    try validate(authority, expectedPageID: expectedPageID)
    return authority
  }

  static func reconstructDrawingData(
    authority: SegmentedDrawingAuthority,
    maximumByteCount: Int = SegmentedDrawingLimits.maximumReconstructedDrawingByteCount,
    blobProvider: (DrawingSegmentEntry) throws -> Data
  ) throws -> Data {
    try reconstructDrawingData(
      entries: authority.entries,
      maximumByteCount: maximumByteCount,
      blobProvider: blobProvider
    )
  }

  static func reconstructDrawingData(
    entries: [DrawingSegmentEntry],
    maximumByteCount: Int = SegmentedDrawingLimits.maximumReconstructedDrawingByteCount,
    blobProvider: (DrawingSegmentEntry) throws -> Data
  ) throws -> Data {
    var drawing = PKDrawing()
    var declaredBlobByteCount = 0

    for entry in entries {
      let (nextByteCount, overflow) = declaredBlobByteCount.addingReportingOverflow(
        Int(entry.byteCount)
      )
      guard !overflow, nextByteCount <= maximumByteCount else {
        throw SegmentedDrawingError.reconstructedDrawingTooLarge(
          actual: overflow ? Int.max : nextByteCount,
          maximum: maximumByteCount
        )
      }

      let data = try blobProvider(entry)
      guard data.count == Int(entry.byteCount) else {
        throw SegmentedDrawingError.segmentByteCountMismatch
      }
      guard sha256Hex(data) == entry.sha256 else {
        throw SegmentedDrawingError.segmentChecksumMismatch
      }
      let segmentDrawing: PKDrawing
      do {
        segmentDrawing = try PKDrawing(data: data)
      } catch {
        throw SegmentedDrawingError.invalidDrawing
      }
      drawing.append(segmentDrawing)
      declaredBlobByteCount = nextByteCount
    }

    let data = drawing.dataRepresentation()
    guard data.count <= maximumByteCount else {
      throw SegmentedDrawingError.reconstructedDrawingTooLarge(
        actual: data.count,
        maximum: maximumByteCount
      )
    }
    return data
  }

  static func reconstructSourceDrawingData(
    authority: SegmentedDrawingAuthority,
    maximumByteCount: Int = SegmentedDrawingLimits.maximumReconstructedDrawingByteCount,
    blobProvider: (DrawingSourceChunk) throws -> Data
  ) throws -> Data {
    var drawingData = Data()

    for chunk in authority.sourceChunks {
      let (nextByteCount, overflow) = drawingData.count.addingReportingOverflow(
        Int(chunk.byteCount)
      )
      guard !overflow, nextByteCount <= maximumByteCount else {
        throw SegmentedDrawingError.reconstructedDrawingTooLarge(
          actual: overflow ? Int.max : nextByteCount,
          maximum: maximumByteCount
        )
      }
      let data = try blobProvider(chunk)
      guard data.count == Int(chunk.byteCount) else {
        throw SegmentedDrawingError.segmentByteCountMismatch
      }
      guard sha256Hex(data) == chunk.sha256 else {
        throw SegmentedDrawingError.segmentChecksumMismatch
      }
      drawingData.append(data)
    }

    if !drawingData.isEmpty {
      do {
        _ = try PKDrawing(data: drawingData)
      } catch {
        throw SegmentedDrawingError.invalidDrawing
      }
    }
    return drawingData
  }

  private struct DrawingShard {
    let regionIndex: Int
    let minimumY: Double
    let maximumY: Double
    let strokes: [PKStroke]
  }

  private static func makeSourceChunks(_ data: Data) -> [DrawingSourceChunk] {
    guard !data.isEmpty else { return [] }
    var chunks: [DrawingSourceChunk] = []
    chunks.reserveCapacity(
      (data.count + SegmentedDrawingLimits.maximumSegmentByteCount - 1)
        / SegmentedDrawingLimits.maximumSegmentByteCount
    )
    var offset = 0
    while offset < data.count {
      let end = min(offset + SegmentedDrawingLimits.maximumSegmentByteCount, data.count)
      let chunkData = data.subdata(in: offset..<end)
      chunks.append(
        DrawingSourceChunk(
          sequenceIndex: chunks.count,
          byteCount: UInt64(chunkData.count),
          sha256: sha256Hex(chunkData)
        )
      )
      offset = end
    }
    return chunks
  }

  private static func makeShards(from strokes: [PKStroke]) throws -> [DrawingShard] {
    var runs: [(regionIndex: Int, strokes: [PKStroke])] = []

    for stroke in strokes {
      let regionIndex = try regionIndex(for: stroke)
      if let lastIndex = runs.indices.last,
        runs[lastIndex].regionIndex == regionIndex,
        runs[lastIndex].strokes.count < SegmentedDrawingLimits.maximumStrokeCountPerShard
      {
        runs[lastIndex].strokes.append(stroke)
      } else {
        runs.append((regionIndex, [stroke]))
      }
    }

    var shards: [DrawingShard] = []
    for run in runs {
      for fittedStrokes in try splitToFit(run.strokes) {
        let verticalBounds = try verticalBounds(for: fittedStrokes)
        shards.append(
          DrawingShard(
            regionIndex: run.regionIndex,
            minimumY: verticalBounds.minimumY,
            maximumY: verticalBounds.maximumY,
            strokes: fittedStrokes
          )
        )
      }
    }
    return shards
  }

  private static func splitToFit(_ strokes: [PKStroke]) throws -> [[PKStroke]] {
    let byteCount = PKDrawing(strokes: strokes).dataRepresentation().count
    if byteCount <= SegmentedDrawingLimits.maximumSegmentByteCount {
      return [strokes]
    }
    guard strokes.count > 1 else {
      throw SegmentedDrawingError.segmentTooLarge(
        actual: byteCount,
        maximum: SegmentedDrawingLimits.maximumSegmentByteCount
      )
    }
    let midpoint = strokes.count / 2
    return try splitToFit(Array(strokes[..<midpoint]))
      + splitToFit(Array(strokes[midpoint...]))
  }

  private static func regionIndex(for stroke: PKStroke) throws -> Int {
    let bounds = stroke.renderBounds
    guard isFinite(bounds), !bounds.isNull else {
      throw SegmentedDrawingError.invalidDrawing
    }
    let middleY = max(0, bounds.midY)
    let rawIndex = floor(middleY / Double(SegmentedDrawingLimits.segmentHeight))
    guard rawIndex.isFinite, rawIndex >= 0, rawIndex <= Double(Int.max) else {
      throw SegmentedDrawingError.invalidDrawing
    }
    return Int(rawIndex)
  }

  private static func verticalBounds(
    for strokes: [PKStroke]
  ) throws -> (minimumY: Double, maximumY: Double) {
    guard let first = strokes.first else {
      throw SegmentedDrawingError.invalidDrawing
    }
    var bounds = first.renderBounds
    for stroke in strokes.dropFirst() {
      bounds = bounds.union(stroke.renderBounds)
    }
    guard isFinite(bounds), !bounds.isNull, bounds.minY <= bounds.maxY else {
      throw SegmentedDrawingError.invalidDrawing
    }
    return (Double(bounds.minY), Double(bounds.maxY))
  }

  private static func validate(
    _ authority: SegmentedDrawingAuthority,
    expectedPageID: UUID
  ) throws {
    guard authority.version == SegmentedDrawingAuthority.currentVersion,
      authority.pageID == expectedPageID,
      authority.segmentHeight == SegmentedDrawingLimits.segmentHeight,
      authority.sourceChunks.count <= SegmentedDrawingLimits.maximumSourceChunkCount,
      authority.entries.count <= SegmentedDrawingLimits.maximumEntryCount
    else {
      throw SegmentedDrawingError.invalidAuthority
    }

    for (expectedSequenceIndex, entry) in authority.entries.enumerated() {
      guard entry.sequenceIndex == expectedSequenceIndex,
        entry.regionIndex >= 0,
        entry.minimumY.isFinite,
        entry.maximumY.isFinite,
        entry.minimumY <= entry.maximumY,
        entry.byteCount > 0,
        entry.byteCount <= UInt64(SegmentedDrawingLimits.maximumSegmentByteCount),
        isValidSHA256Hex(entry.sha256)
      else {
        throw SegmentedDrawingError.invalidAuthority
      }
    }

    if !authority.entries.isEmpty, authority.sourceChunks.isEmpty {
      throw SegmentedDrawingError.invalidAuthority
    }
    var sourceByteCount = 0
    for (expectedSequenceIndex, chunk) in authority.sourceChunks.enumerated() {
      let isLast = expectedSequenceIndex == authority.sourceChunks.count - 1
      let (nextByteCount, overflow) = sourceByteCount.addingReportingOverflow(
        Int(chunk.byteCount)
      )
      guard chunk.sequenceIndex == expectedSequenceIndex,
        chunk.byteCount > 0,
        chunk.byteCount <= UInt64(SegmentedDrawingLimits.maximumSegmentByteCount),
        isLast || chunk.byteCount == UInt64(SegmentedDrawingLimits.maximumSegmentByteCount),
        !overflow,
        nextByteCount <= SegmentedDrawingLimits.maximumReconstructedDrawingByteCount,
        isValidSHA256Hex(chunk.sha256)
      else {
        throw SegmentedDrawingError.invalidAuthority
      }
      sourceByteCount = nextByteCount
    }
  }

  private static func encodeAuthority(_ manifestData: Data) throws -> Data {
    let (authorityByteCount, overflow) = headerByteCount.addingReportingOverflow(
      manifestData.count
    )
    guard !overflow,
      authorityByteCount <= SegmentedDrawingLimits.maximumAuthorityByteCount,
      manifestData.count <= Int(UInt32.max)
    else {
      throw SegmentedDrawingError.authorityTooLarge(
        actual: overflow ? Int.max : authorityByteCount,
        maximum: SegmentedDrawingLimits.maximumAuthorityByteCount
      )
    }

    var data = Data()
    data.reserveCapacity(authorityByteCount)
    data.append(magic)
    appendBigEndian(UInt32(manifestData.count), to: &data)
    data.append(Data(SHA256.hash(data: manifestData)))
    data.append(manifestData)
    return data
  }

  private static func encodeManifest(_ authority: SegmentedDrawingAuthority) throws -> Data {
    do {
      return try makeEncoder().encode(authority)
    } catch {
      throw SegmentedDrawingError.invalidAuthority
    }
  }

  private static func isFinite(_ rect: CGRect) -> Bool {
    rect.origin.x.isFinite && rect.origin.y.isFinite
      && rect.size.width.isFinite && rect.size.height.isFinite
  }

  private static func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    let digits = Array("0123456789abcdef".utf8)
    var bytes: [UInt8] = []
    bytes.reserveCapacity(SHA256.Digest.byteCount * 2)
    for byte in digest {
      bytes.append(digits[Int(byte >> 4)])
      bytes.append(digits[Int(byte & 0x0F)])
    }
    return String(decoding: bytes, as: UTF8.self)
  }

  static func isValidSHA256Hex(_ value: String) -> Bool {
    let bytes = value.utf8
    return bytes.count == 64
      && bytes.allSatisfy {
        ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
      }
  }

  private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
  }

  private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private static func makeDecoder() -> JSONDecoder {
    JSONDecoder()
  }
}
