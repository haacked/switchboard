import AppKit
import SwiftUI
import SwitchboardCore

/// Shows a message field's slash commands in a panel under the field. Put it in the field's background, so that its
/// frame is the field's frame.
struct SlashCompletionAnchor: NSViewRepresentable {
  let rows: [SlashCommand]
  let highlighted: String?
  let open: Bool
  let accept: (String) -> Void

  func makeNSView(context: Context) -> SlashCompletionAnchorView { SlashCompletionAnchorView() }

  func updateNSView(_ view: SlashCompletionAnchorView, context: Context) {
    view.list = open ? SlashCompletionList(rows: rows, highlighted: highlighted, accept: accept) : nil
  }

  static func dismantleNSView(_ view: SlashCompletionAnchorView, coordinator: ()) { view.list = nil }
}

/// Opens and places the panel. The panel closes when the window resigns key and opens again when the window becomes
/// key. It also closes when the field leaves the window.
final class SlashCompletionAnchorView: NSView {
  let panel = SlashCompletionPanel()
  var list: SlashCompletionList? { didSet { refresh() } }
  private var windowResignedKey = false
  private var observers: [NSObjectProtocol] = []

  /// The field gets every click.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    refresh()
  }

  override func setFrameOrigin(_ newOrigin: NSPoint) {
    super.setFrameOrigin(newOrigin)
    refresh()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    windowResignedKey = false
    if let window {
      observers = [
        (NSWindow.didResignKeyNotification, true), (NSWindow.didBecomeKeyNotification, false),
      ].map { name, resigned in
        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.windowResignedKey = resigned
            self?.refresh()
          }
        }
      }
    }
    refresh()
  }

  private func refresh() {
    if let list, let window, !windowResignedKey {
      panel.show(list, below: self, in: window)
    } else {
      panel.hide()
    }
  }
}

/// A borderless child panel of the field's window. It never becomes key, so typing stays in the field.
@MainActor
final class SlashCompletionPanel {
  static let rowHeight: CGFloat = 24
  static let maxRows = 8
  static let padding: CGFloat = 4
  static let gap: CGFloat = 4
  private var panel: NSPanel?
  private var hosting: FirstClickHostingView<SlashCompletionList>?

  var isVisible: Bool { panel?.isVisible == true }
  /// The rows that the panel shows, in order. A closed panel shows none.
  var rows: [SlashCommand] { isVisible ? hosting?.rootView.rows ?? [] : [] }

  func show(_ list: SlashCompletionList, below anchor: NSView, in window: NSWindow) {
    let panel = self.panel ?? makePanel(list)
    hosting?.rootView = list
    if panel.parent !== window {
      panel.parent?.removeChildWindow(panel)
      window.addChildWindow(panel, ordered: .above)
    }
    let field = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    let screen = window.screen?.visibleFrame ?? field.insetBy(dx: -10_000, dy: -10_000)
    let frame = Self.frame(field: field, rows: list.rows.count, screen: screen)
    if frame != panel.frame { panel.setFrame(frame, display: true) }
    if !panel.isVisible { panel.orderFront(nil) }
  }

  func hide() {
    guard let panel, panel.isVisible else { return }
    panel.parent?.removeChildWindow(panel)
    panel.orderOut(nil)
  }

  /// The panel's frame in screen coordinates: as wide as the field, up to `maxRows` rows tall, and under the field,
  /// or above it when the screen has no room below.
  static func frame(field: NSRect, rows: Int, screen: NSRect) -> NSRect {
    let height = CGFloat(min(rows, maxRows)) * rowHeight + 2 * padding
    var y = field.minY - gap - height
    if y < screen.minY { y = field.maxY + gap }
    return NSRect(x: field.minX, y: y, width: field.width, height: height)
  }

  private func makePanel(_ list: SlashCompletionList) -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.transient, .ignoresCycle]
    let hosting = FirstClickHostingView(rootView: list)
    hosting.autoresizingMask = [.width, .height]
    panel.contentView = hosting
    self.panel = panel
    self.hosting = hosting
    return panel
  }
}

/// The panel never becomes key, so every click on it is a first click into a window that is not key.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct SlashCompletionList: View {
  let rows: [SlashCommand]
  let highlighted: String?
  let accept: (String) -> Void

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(rows, id: \.name) { row in
            Button {
              accept(row.name)
            } label: {
              self.row(row)
            }
            .buttonStyle(.plain)
            .id(row.name)
          }
        }
        .padding(SlashCompletionPanel.padding)
      }
      .onChange(of: highlighted) {
        if let highlighted { proxy.scrollTo(highlighted) }
      }
    }
    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
  }

  private func row(_ row: SlashCommand) -> some View {
    HStack(spacing: 8) {
      Text(verbatim: "/\(row.name)").layoutPriority(1)
      if let description = row.description {
        Text(verbatim: description).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .lineLimit(1)
    .truncationMode(.tail)
    .padding(.horizontal, 8)
    .frame(height: SlashCompletionPanel.rowHeight)
    .background(
      RoundedRectangle(cornerRadius: 6).fill(row.name == highlighted ? Color.accentColor.opacity(0.2) : Color.clear)
    )
    .contentShape(Rectangle())
    .accessibilityAddTraits(row.name == highlighted ? .isSelected : [])
  }
}
