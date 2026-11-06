import SwiftUI
import SwitchboardCore

/// Draws GitHub Flavored Markdown. `MarkdownBlock.parse` reads it, and this
/// draws each block. The top level is lazy, and so is each item of a list at
/// the top level, so a reply of thousands of lines lays out only what is in view.
struct MarkdownView: View {
  let text: String

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(Array(Self.rows(text).enumerated()), id: \.offset) { i, row in
        MarkdownBlocksView.view(row.block).padding(.top, i == 0 ? 0 : row.gap)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .textSelection(.enabled)
  }

  /// A top-level block, or one item of a top-level list, and the space above it.
  struct Row {
    var block: MarkdownBlock
    var gap: CGFloat
  }

  static func rows(splitting blocks: [MarkdownBlock]) -> [Row] {
    blocks.flatMap { block -> [Row] in
      guard case .list(let number, let items) = block else { return [Row(block: block, gap: 8)] }
      return items.enumerated().map { i, item in
        Row(block: .list(number: number.map { $0 + i }, items: [item]), gap: i == 0 ? 8 : 3)
      }
    }
  }

  /// SwiftUI asks for the body each time the model changes, so the rows of
  /// recent texts stay parsed. The cache limit counts each entry as its text's length in bytes.
  private static let cache: NSCache<NSString, Parsed> = {
    let cache = NSCache<NSString, Parsed>()
    cache.totalCostLimit = 8 << 20
    return cache
  }()

  private final class Parsed {
    let rows: [Row]
    init(_ rows: [Row]) { self.rows = rows }
  }

  private static func rows(_ text: String) -> [Row] {
    if let parsed = cache.object(forKey: text as NSString) { return parsed.rows }
    let rows = rows(splitting: MarkdownBlock.parse(text))
    cache.setObject(Parsed(rows), forKey: text as NSString, cost: text.utf8.count)
    return rows
  }
}

/// The blocks of a list item, quote, details element, or footnote.
private struct MarkdownBlocksView: View {
  let blocks: [MarkdownBlock]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        Self.view(block)
      }
    }
  }

  @ViewBuilder
  static func view(_ block: MarkdownBlock) -> some View {
    switch block {
    case .heading(let level, let text):
      Text(text.attributed).font(Self.headingFonts[min(level, Self.headingFonts.count) - 1]).padding(.top, 4)
    case .paragraph(let text):
      Text(text.attributed)
    case .images(let images):
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(images.enumerated()), id: \.offset) { MarkdownImageView(image: $1) }
      }
    case .list(let number, let items):
      VStack(alignment: .leading, spacing: 3) {
        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            marker(number.map { "\($0 + i)." } ?? (item.checked == nil ? "•" : nil), checked: item.checked)
            MarkdownBlocksView(blocks: item.blocks)
          }
        }
      }
      .padding(.leading, 6)
    case .code(_, let text):
      ScrollView(.horizontal) {
        Text(verbatim: text).font(.callout.monospaced()).padding(8).fixedSize(horizontal: true, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
    case .quote(let blocks):
      HStack(spacing: 8) {
        Rectangle().fill(.secondary.opacity(0.5)).frame(width: 3)
        MarkdownBlocksView(blocks: blocks).foregroundStyle(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)
    case .table(let header, let alignments, let rows):
      ScrollView(.horizontal) {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
          GridRow {
            ForEach(Array(header.enumerated()), id: \.offset) { c, cell in
              tableCell(cell, alignments[c], header: true).gridColumnAlignment(alignments[c].horizontal)
            }
          }
          Divider()
          ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            GridRow {
              ForEach(Array(row.enumerated()), id: \.offset) { c, cell in
                tableCell(cell, alignments[c], header: false)
              }
            }
          }
        }
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
      }
      .scrollIndicators(.visible)
    case .rule:
      Divider()
    case .details(let summary, let open, let blocks):
      DetailsView(summary: summary, blocks: blocks, expanded: open)
    case .footnotes(let notes):
      VStack(alignment: .leading, spacing: 4) {
        Divider()
        ForEach(notes, id: \.number) { note in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(note.number).").monospacedDigit()
            MarkdownBlocksView(blocks: note.blocks)
          }
        }
      }
      .font(.callout)
      .foregroundStyle(.secondary)
    }
  }

  private static let headingFonts: [Font] = [
    .title2.bold(), .title3.bold(), .headline, .subheadline.bold(), .subheadline.bold(), .subheadline,
  ]

  @ViewBuilder
  private static func marker(_ text: String?, checked: Bool?) -> some View {
    HStack(spacing: 4) {
      if let text { Text(text).foregroundStyle(.secondary).monospacedDigit() }
      if let checked {
        Image(systemName: checked ? "checkmark.square" : "square")
          .foregroundStyle(.secondary)
          .accessibilityLabel(checked ? "Done" : "Not done")
      }
    }
  }

  private static func tableCell(_ text: MarkdownText, _ align: MarkdownBlock.Alignment, header: Bool) -> some View {
    CappedWidthLayout(limit: 320) {
      Text(text.attributed).bold(header)
        .multilineTextAlignment(align.text)
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: align.horizontal, vertical: .top))
    }
  }
}

/// A `<details>` element: its summary, and its blocks under a disclosure.
private struct DetailsView: View {
  let summary: MarkdownText
  let blocks: [MarkdownBlock]
  @State var expanded: Bool

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      MarkdownBlocksView(blocks: blocks).padding(.top, 4).frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      Text(summary.attributed)
    }
  }
}

/// An image from a web or file URL, at its own size up to a limit. An image
/// shows its alt text until the user clicks it, so text that a model wrote can't
/// make the app request a URL or touch a path, such as one under `/net` or a
/// protected folder. Any other source, and an image that fails to load, shows
/// its alt text.
private struct MarkdownImageView: View {
  let image: MarkdownBlock.Image
  @State private var loaded: NSImage?
  @State private var asked = false

  /// A lazy row drops its state when it scrolls away, so loaded images stay here.
  private static let cache = NSCache<NSURL, NSImage>()

  private var url: URL? {
    URL(string: image.source).flatMap { ["http", "https", "file"].contains($0.scheme?.lowercased()) ? $0 : nil }
  }

  var body: some View {
    if let loaded {
      Image(nsImage: loaded)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(maxWidth: min(loaded.size.width, 640), maxHeight: min(loaded.size.height, 480), alignment: .leading)
        .accessibilityLabel(image.alt)
        .onTapGesture {
          if let link = image.link.flatMap(URL.init(string:)) ?? url { NSWorkspace.shared.open(link) }
        }
    } else {
      let label = Label(image.alt.isEmpty ? image.source : image.alt, systemImage: "photo")
      Group {
        if let url, !MarkdownImageLoader.loadsUnasked(url), !asked {
          Button {
            asked = true
          } label: {
            label
          }
          .buttonStyle(.link)
          .help("Load the image from \(url.host ?? image.source)")
        } else {
          label.foregroundStyle(.secondary)
        }
      }
      .task(id: "\(image.source)/\(asked)") {
        guard let url else { return }
        if let cached = Self.cache.object(forKey: url as NSURL) {
          loaded = cached
        } else if asked || MarkdownImageLoader.loadsUnasked(url), let image = await MarkdownImageLoader.load(url) {
          Self.cache.setObject(image, forKey: url as NSURL)
          loaded = image
        }
      }
    }
  }
}

/// Reads an image from a URL, up to `limit` bytes. A larger image, and a local
/// path that is not a regular file, such as `/dev/zero` or a FIFO, load nothing.
enum MarkdownImageLoader {
  static let limit = 20 << 20

  /// No image loads without a click. The answer comes from nothing but the URL,
  /// because a path under `/net` or a protected folder acts on the first
  /// filesystem call, a symlink resolution or a stat.
  static func loadsUnasked(_ url: URL) -> Bool { false }

  static func load(_ url: URL, limit: Int = limit) async -> NSImage? {
    guard let data = url.isFileURL ? read(url, limit: limit) : await fetch(url, limit: limit) else { return nil }
    return NSImage(data: data)
  }

  private static func read(_ url: URL, limit: Int) -> Data? {
    let file = url.resolvingSymlinksInPath()
    guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      values.isRegularFile == true, let size = values.fileSize, size <= limit,
      let handle = try? FileHandle(forReadingFrom: file)
    else { return nil }
    defer { try? handle.close() }
    // The file can grow after the check. The read stops past the limit as well.
    guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
    return data
  }

  private static func fetch(_ url: URL, limit: Int) async -> Data? {
    guard let (bytes, response) = try? await URLSession.shared.bytes(from: url),
      response.expectedContentLength <= limit
    else { return nil }
    var data = Data()
    do {
      for try await byte in bytes {
        data.append(byte)
        if data.count > limit { return nil }
      }
    } catch {
      return nil
    }
    return data
  }
}

extension MarkdownText {
  /// The text with its styles as presentation intents, and its links. `Text`
  /// draws presentation intents in the font around it.
  fileprivate var attributed: AttributedString {
    var result = AttributedString()
    for run in runs {
      var part = AttributedString(run.text.isEmpty ? run.image ?? "" : run.text)
      var intent: InlinePresentationIntent = []
      if run.style.contains(.emphasis) { intent.insert(.emphasized) }
      if run.style.contains(.strong) { intent.insert(.stronglyEmphasized) }
      if run.style.contains(.code) { intent.insert(.code) }
      if run.style.contains(.strikethrough) { intent.insert(.strikethrough) }
      if !intent.isEmpty { part.inlinePresentationIntent = intent }
      if run.style.contains(.footnote) {
        part.baselineOffset = 6
        part.font = .caption2
      }
      if let link = (run.link ?? run.image).flatMap(URL.init(string:)) { part.link = link }
      result += part
    }
    return result
  }
}

/// Sizes its one child to the child's natural width, or to `limit` when the
/// child is wider, and measures the height at that width. A horizontal
/// ScrollView proposes no width, so a plain `frame(maxWidth:)` would measure a
/// wrapped cell's height as one line.
private struct CappedWidthLayout: Layout {
  let limit: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let child = subviews.first else { return .zero }
    let natural = child.sizeThatFits(.unspecified).width
    return child.sizeThatFits(ProposedViewSize(width: min(natural, limit), height: nil))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
  }
}

extension MarkdownBlock.Alignment {
  fileprivate var horizontal: HorizontalAlignment {
    switch self {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }

  fileprivate var text: TextAlignment {
    switch self {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }
}
