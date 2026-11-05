import AppKit
import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@Suite struct MarkdownViewTests {
  @Test func eachItemOfATopLevelListIsARowOfItsOwn() {
    let item = { (text: MarkdownText) in MarkdownBlock.Item(checked: nil, blocks: [.paragraph(text)]) }
    let rows = MarkdownView.rows(splitting: [
      .paragraph("intro"), .list(number: 3, items: [item("a"), item("b"), item("c")]), .rule,
    ])
    #expect(
      rows.map(\.block) == [
        .paragraph("intro"), .list(number: 3, items: [item("a")]), .list(number: 4, items: [item("b")]),
        .list(number: 5, items: [item("c")]), .rule,
      ])
    #expect(rows.map(\.gap) == [8, 8, 3, 3, 8])
  }

  @Test func onlyALocalImageLoadsWithoutAClick() {
    #expect(MarkdownImageLoader.loadsUnasked(URL(fileURLWithPath: "/tmp/a.png")))
    #expect(!MarkdownImageLoader.loadsUnasked(URL(string: "https://x.example/a.png")!))
  }

  @Test func aLocalImageLoadsOnlyFromARegularFileUnderTheLimit() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let png = folder.appendingPathComponent("a.png")
    let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { _ in
      NSColor.red.setFill()
      NSBezierPath.fill(NSRect(x: 0, y: 0, width: 4, height: 4))
      return true
    }
    let tiff = try #require(image.tiffRepresentation)
    try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])).write(to: png)
    let fifo = folder.appendingPathComponent("fifo").path
    #expect(mkfifo(fifo, 0o600) == 0)
    let link = folder.appendingPathComponent("zero.png")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/dev/zero")

    #expect(await MarkdownImageLoader.load(png) != nil)
    #expect(await MarkdownImageLoader.load(png, limit: 16) == nil)
    #expect(await MarkdownImageLoader.load(URL(fileURLWithPath: "/dev/zero")) == nil)
    #expect(await MarkdownImageLoader.load(link) == nil)
    #expect(await MarkdownImageLoader.load(URL(fileURLWithPath: fifo)) == nil)
    #expect(await MarkdownImageLoader.load(folder.appendingPathComponent("missing.png")) == nil)
  }
}
