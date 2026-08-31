import Foundation
import PencilKit
import Testing

@testable import InkNotesCore

@Suite("Segmented drawing codec")
struct SegmentedDrawingCodecTests {
  @Test("Segments preserve stroke order across distant writing regions")
  func roundTripPreservesStrokeOrder() throws {
    let pageID = UUID(uuidString: "11000000-0000-0000-0000-000000000001")!
    let source = try makeDrawingAcrossRegions()
    let sourceData = source.dataRepresentation()
    let snapshot = try SegmentedDrawingCodec.makeSnapshot(
      pageID: pageID,
      drawingData: sourceData
    )

    #expect(SegmentedDrawingCodec.isSegmentedAuthority(snapshot.authorityData))
    #expect(snapshot.authority.pageID == pageID)
    #expect(snapshot.authority.entries.map(\.sequenceIndex) == [0, 1, 2])
    #expect(snapshot.authority.entries.map(\.regionIndex) == [1, 0, 2])

    let decodedAuthority = try SegmentedDrawingCodec.decodeAuthority(
      snapshot.authorityData,
      expectedPageID: pageID
    )
    let reconstructedData = try SegmentedDrawingCodec.reconstructDrawingData(
      authority: decodedAuthority
    ) { entry in
      try #require(snapshot.blobsBySHA256[entry.sha256])
    }
    let reconstructed = try PKDrawing(data: reconstructedData)

    #expect(reconstructed.strokes.count == source.strokes.count)
    #expect(reconstructed.strokes.map(\.renderBounds) == source.strokes.map(\.renderBounds))
    let exactSourceData = try SegmentedDrawingCodec.reconstructSourceDrawingData(
      authority: decodedAuthority
    ) { chunk in
      try #require(snapshot.blobsBySHA256[chunk.sha256])
    }
    #expect(exactSourceData == sourceData)
  }

  @Test("An empty drawing needs no blobs and still round-trips")
  func emptyDrawingRoundTrip() throws {
    let pageID = UUID(uuidString: "11000000-0000-0000-0000-000000000002")!
    let snapshot = try SegmentedDrawingCodec.makeSnapshot(
      pageID: pageID,
      drawingData: Data()
    )

    #expect(snapshot.authority.entries.isEmpty)
    #expect(snapshot.blobsBySHA256.isEmpty)
    let authority = try SegmentedDrawingCodec.decodeAuthority(
      snapshot.authorityData,
      expectedPageID: pageID
    )
    let data = try SegmentedDrawingCodec.reconstructDrawingData(authority: authority) { entry in
      throw SegmentedDrawingError.missingSegment(entry.sha256)
    }
    #expect(try PKDrawing(data: data).strokes.isEmpty)
  }

  @Test("Authority tampering and page substitution fail closed")
  func tamperingFailsClosed() throws {
    let pageID = UUID(uuidString: "11000000-0000-0000-0000-000000000003")!
    let snapshot = try SegmentedDrawingCodec.makeSnapshot(
      pageID: pageID,
      drawingData: try makeDrawingAcrossRegions().dataRepresentation()
    )
    var tampered = snapshot.authorityData
    tampered[tampered.count - 1] ^= 0x01

    #expect(throws: SegmentedDrawingError.invalidAuthority) {
      try SegmentedDrawingCodec.decodeAuthority(tampered, expectedPageID: pageID)
    }
    #expect(throws: SegmentedDrawingError.invalidAuthority) {
      try SegmentedDrawingCodec.decodeAuthority(
        snapshot.authorityData,
        expectedPageID: UUID()
      )
    }
  }

  @Test("A previous app cannot mistake segmented authority for PencilKit strokes")
  func segmentedAuthorityFailsClosedInLegacyDecoder() throws {
    let snapshot = try SegmentedDrawingCodec.makeSnapshot(
      pageID: UUID(),
      drawingData: try makeDrawingAcrossRegions().dataRepresentation()
    )

    var legacyDecoderAcceptedAuthority = false
    do {
      _ = try PKDrawing(data: snapshot.authorityData)
      legacyDecoderAcceptedAuthority = true
    } catch {}
    #expect(!legacyDecoderAcceptedAuthority)
  }

  @Test("Missing or modified blobs never produce a partial drawing")
  func blobIntegrityFailsClosed() throws {
    let pageID = UUID(uuidString: "11000000-0000-0000-0000-000000000004")!
    let snapshot = try SegmentedDrawingCodec.makeSnapshot(
      pageID: pageID,
      drawingData: try makeDrawingAcrossRegions().dataRepresentation()
    )
    let authority = try SegmentedDrawingCodec.decodeAuthority(
      snapshot.authorityData,
      expectedPageID: pageID
    )

    #expect(throws: SegmentedDrawingError.missingSegment(authority.entries[0].sha256)) {
      try SegmentedDrawingCodec.reconstructDrawingData(authority: authority) { entry in
        guard entry.sequenceIndex != 0 else {
          throw SegmentedDrawingError.missingSegment(entry.sha256)
        }
        return try #require(snapshot.blobsBySHA256[entry.sha256])
      }
    }

    #expect(throws: SegmentedDrawingError.segmentChecksumMismatch) {
      try SegmentedDrawingCodec.reconstructDrawingData(authority: authority) { entry in
        var data = try #require(snapshot.blobsBySHA256[entry.sha256])
        if entry.sequenceIndex == 0 {
          data[data.count - 1] ^= 0x01
        }
        return data
      }
    }
  }

  private func makeDrawingAcrossRegions() throws -> PKDrawing {
    let fixtureURL = try #require(
      Bundle.module.url(
        forResource: "single-stroke-v1",
        withExtension: "pkdrawing",
        subdirectory: "Fixtures/BackupV1"
      )
    )
    let fixture = try PKDrawing(data: Data(contentsOf: fixtureURL))
    var drawing = fixture.transformed(
      using: CGAffineTransform(translationX: 0, y: 5_000)
    )
    drawing.append(fixture)
    drawing.append(
      fixture.transformed(using: CGAffineTransform(translationX: 0, y: 9_000))
    )
    return drawing
  }
}
