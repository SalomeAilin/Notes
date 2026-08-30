import Foundation
import Testing

@testable import InkNotesCore

@Suite("External backup import request")
struct BackupImportRequestTests {
  @Test("Only file URLs with the stable backup extension are accepted")
  func requestValidation() throws {
    let requestID = UUID(uuidString: "B5000000-0000-0000-0000-000000000001")!
    let acceptedURL = URL(fileURLWithPath: "/tmp/history.NOTESBACKUP")
    let request = try #require(
      BackupImportRequest(url: acceptedURL, source: .externalOpen, id: requestID)
    )

    #expect(request.id == requestID)
    #expect(request.url == acceptedURL)
    #expect(request.source == .externalOpen)
    #expect(BackupArchiveCodec.fileExtension == "notesbackup")

    let rejectedURLs = [
      URL(fileURLWithPath: "/tmp/history.zip"),
      URL(fileURLWithPath: "/tmp/history.notesbackup.txt"),
      try #require(URL(string: "https://example.invalid/history.notesbackup")),
    ]
    for url in rejectedURLs {
      #expect(BackupImportRequest(url: url, source: .externalOpen) == nil)
    }
  }

  @Test("Queued import sources remain FIFO and stale completions cannot remove a newer request")
  func queueOrdering() throws {
    let firstID = UUID(uuidString: "B5000000-0000-0000-0000-000000000002")!
    let secondID = UUID(uuidString: "B5000000-0000-0000-0000-000000000003")!
    let first = try #require(
      BackupImportRequest(
        url: URL(fileURLWithPath: "/tmp/first.notesbackup"),
        source: .externalOpen,
        id: firstID
      )
    )
    let second = try #require(
      BackupImportRequest(
        url: URL(fileURLWithPath: "/tmp/second.notesbackup"),
        source: .fileImporter,
        id: secondID
      )
    )
    var queue = BackupImportQueue()

    queue.enqueue(first)
    queue.enqueue(second)
    #expect(queue.current == first)
    #expect(queue.requests == [first, second])
    #expect(queue.requests.map(\.source) == [.externalOpen, .fileImporter])

    queue.removeCurrent(ifMatching: second.id)
    #expect(queue.current == first)
    queue.removeCurrent(ifMatching: first.id)
    #expect(queue.current == second)
    queue.removeCurrent(ifMatching: first.id)
    #expect(queue.current == second)
    queue.removeCurrent(ifMatching: second.id)
    #expect(queue.isEmpty)
  }
}
