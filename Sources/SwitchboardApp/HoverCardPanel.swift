import AppKit
import SwiftUI
import SwitchboardCore

extension View {
  /// Shows the session's hover card while the pointer rests on this view. The
  /// card's text is also the view's VoiceOver hint, which no hover card gives.
  func hoverCard(_ session: SessionSummary, activeAccount: String, card: HoverCard?, pinned: Bool = false)
    -> some View
  {
    background(HoverCardAnchor(id: session.id, card: card, pinned: pinned))
      .modifier(HoverCardHint(session: session, activeAccount: activeAccount))
  }
}

private struct HoverCardHint: ViewModifier {
  @Environment(\.sessionNames) private var names
  let session: SessionSummary
  let activeAccount: String

  func body(content: Content) -> some View {
    content.accessibilityHint(HoverCardContent(session, activeAccount: activeAccount, names: names).accessibilityText)
  }
}

/// Watches the pointer over a tile with its own tracking area. A model update
/// redraws the tile but keeps this view and its tracking area. An open card
/// therefore stays open.
private struct HoverCardAnchor: NSViewRepresentable {
  let id: String
  let card: HoverCard?
  let pinned: Bool

  func makeNSView(context: Context) -> HoverCardAnchorView {
    let view = HoverCardAnchorView()
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ view: HoverCardAnchorView, context: Context) {
    view.id = id
    view.card = card
    view.pinned = pinned
  }
}

/// Reports the pointer entering and leaving the view. The tracking area follows the view's visible rect.
class PointerTrackingView: NSView {
  init() {
    super.init(frame: .zero)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
  }

  required init?(coder: NSCoder) { nil }
}

final class HoverCardAnchorView: PointerTrackingView {
  var id = ""
  weak var card: HoverCard?
  /// SB_HOVER names this tile, so its card opens without a pointer.
  var pinned = false

  /// The tile's button gets every click.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func mouseEntered(with event: NSEvent) { card?.entered(id, anchor: self) }
  override func mouseExited(with event: NSEvent) { card?.exited(id, anchor: self) }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else {
      card?.disappeared(anchor: self)
      return
    }
    // The view has no frame until SwiftUI lays it out.
    DispatchQueue.main.async { [weak self] in
      guard let self, let window = self.window, let card = self.card else { return }
      let pointer = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
      card.appeared(self.id, anchor: self, pointerInside: self.visibleRect.contains(pointer))
      if self.pinned {
        // A card in a lazy stack can appear before it has its final frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
          guard let self, self.window != nil else { return }
          self.card?.pin(self.id, below: self)
        }
      }
    }
  }
}

/// Draws the hover card in a borderless panel below the tile. The panel is a
/// child window of the tile's window and never takes key focus. It reads the
/// session from the model, so the card's text follows each update.
@MainActor
final class HoverCardPanel: HoverCardPresenter {
  weak var model: BoardModel?
  /// Reports when the pointer enters or leaves the card.
  var onPointer: (Bool) -> Void = { _ in }
  private var panel: NSPanel?
  private var hosting: NSHostingView<AnyView>?
  private weak var anchor: NSView?

  func show(_ id: String, below anchor: NSView) {
    guard let model, let window = anchor.window else { return }
    let panel = self.panel ?? makePanel()
    hosting?.rootView = AnyView(HoverCardView(model: model, id: id))
    self.anchor = anchor
    ChildPanel.attach(panel, to: window)
    place()
    panel.orderFront(nil)
  }

  func hide() {
    guard let panel else { return }
    ChildPanel.detach(panel)
    // A hidden card stops observing the model.
    hosting?.rootView = AnyView(EmptyView())
  }

  func refresh(below anchor: NSView) {
    self.anchor = anchor
    // SwiftUI draws the new text on its next update.
    DispatchQueue.main.async { [weak self] in self?.place() }
  }

  /// Below the tile, or above it when the screen has no room below.
  private func place() {
    guard let anchor, let window = anchor.window, let panel, let hosting else { return }
    let size = hosting.fittingSize
    let (tile, screen) = ChildPanel.frames(of: anchor, in: window)
    let x = max(screen.minX, min(tile.minX, screen.maxX - size.width))
    let frame = NSRect(
      origin: NSPoint(x: x, y: ChildPanel.y(height: size.height, anchor: tile, screen: screen)), size: size)
    if frame != panel.frame { panel.setFrame(frame, display: true) }
  }

  private func makePanel() -> NSPanel {
    let container = HoverCardTrackingView { [weak self] inside in self?.onPointer(inside) }
    let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    hosting.autoresizingMask = [.width, .height]
    container.addSubview(hosting)
    let panel = ChildPanel.make(contentView: container)
    self.panel = panel
    self.hosting = hosting
    return panel
  }
}

/// Reports the pointer entering and leaving the card's panel.
private final class HoverCardTrackingView: PointerTrackingView {
  private let report: (Bool) -> Void

  init(report: @escaping (Bool) -> Void) {
    self.report = report
    super.init()
  }

  required init?(coder: NSCoder) { nil }

  override func mouseEntered(with event: NSEvent) { report(true) }
  override func mouseExited(with event: NSEvent) { report(false) }
}

extension HoverCard {
  /// The card for the app: a panel that reads `model`.
  static func panel(for model: BoardModel) -> HoverCard {
    let panel = HoverCardPanel()
    panel.model = model
    let card = HoverCard(presenter: panel)
    panel.onPointer = { [weak card] inside in if inside { card?.enteredCard() } else { card?.exitedCard() } }
    return card
  }

  /// Closes the card on any click, scroll, or key, and when the app goes to the background.
  /// The monitor passes each event on unchanged. The click therefore still reaches the tile.
  func closeOnEvents() {
    _ = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
    ) { [weak self] event in
      MainActor.assumeIsolated { self?.interrupt() }
      return event
    }
    _ = NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.interrupt() } }
  }
}

/// The session's card, or nothing once the model no longer lists it.
private struct HoverCardView: View {
  @ObservedObject var model: BoardModel
  let id: String

  var body: some View {
    if let s = model.board.first(where: { $0.id == id }) {
      HoverCardBody(content: HoverCardContent(s, activeAccount: model.activeAccountFolder, names: model.sessionNames))
        .environment(\.sessionNames, model.sessionNames)
    }
  }
}

struct HoverCardBody: View {
  static let width: CGFloat = 320
  let content: HoverCardContent

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: content.title).font(.headline).lineLimit(2)
        ForEach(Array(content.details.enumerated()), id: \.offset) { _, line in
          Text(verbatim: line).lineLimit(1).truncationMode(.middle)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      if let pr = content.pr {
        HStack(spacing: 5) {
          Circle().fill(pr.status.color).frame(width: 6, height: 6)
          Text(verbatim: pr.text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(pr.status.color.opacity(0.14)))
      }
      if let summary = content.summary {
        // `HoverCardContent` already put the names in. A name is never scanned again.
        Text(verbatim: summary).font(.callout).lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(12)
    .frame(width: Self.width, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
  }
}
