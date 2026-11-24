import AppKit
import SwiftUI
import SwitchboardCore

extension View {
  /// Shows the session's hover card while the pointer rests on this view. The
  /// card's text is also the view's VoiceOver hint, which no hover card gives.
  func hoverCard(_ session: SessionSummary, activeAccount: String, card: HoverCard<String>?, pinned: Bool = false)
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
  let card: HoverCard<String>?
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
  weak var card: HoverCard<String>?
  /// SB_HOVER names this tile, so its card opens without a pointer.
  var pinned = false

  /// The tile's button gets every click.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  private var anchor: HoverAnchor { HoverAnchor(view: self) }

  override func mouseEntered(with event: NSEvent) { card?.entered(id, anchor: anchor) }
  override func mouseExited(with event: NSEvent) { card?.exited(id, anchor: anchor) }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else {
      card?.disappeared(anchor: anchor)
      return
    }
    // The view has no frame until SwiftUI lays it out.
    DispatchQueue.main.async { [weak self] in
      guard let self, let window = self.window, let card = self.card else { return }
      let pointer = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
      card.appeared(
        self.id, anchor: self.anchor, pointerInside: !BackgroundLaunch.isRunning && self.visibleRect.contains(pointer))
      if self.pinned {
        // A card in a lazy stack can appear before it has its final frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
          guard let self, self.window != nil else { return }
          self.card?.pin(self.id, below: self.anchor)
        }
      }
    }
  }
}

/// Draws the hover card in a borderless panel below its anchor. The panel is a
/// child window of the anchor's window and never takes key focus. `content`
/// draws the card for an id, and a card that reads the model follows each
/// update. The panel places itself again whenever the card changes size.
@MainActor
final class HoverCardPanel<ID: Hashable & Sendable>: HoverCardPresenter {
  /// The card that hears the pointer enter and leave the panel.
  weak var card: HoverCard<ID>?
  /// The panel once it exists. Tests read its frame.
  private(set) var panel: NSPanel?
  private let clickable: Bool
  private let content: (ID) -> AnyView
  /// A link in a card takes the click that reaches its panel, which is never key.
  private var hosting: FirstClickHostingView<AnyView>?
  private var anchor: HoverAnchor?

  /// A clickable panel is its card's `clickableWindow`, so a click on a link in it does not close the card.
  init(clickable: Bool, content: @escaping (ID) -> AnyView) {
    self.clickable = clickable
    self.content = content
  }

  func show(_ id: ID, below anchor: HoverAnchor) {
    guard let window = anchor.view.window else { return }
    let panel = self.panel ?? makePanel()
    hosting?.rootView = AnyView(
      content(id)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) {
          $0.size
        } action: { [weak self] _ in
          self?.placeLater()
        })
    self.anchor = anchor
    ChildPanel.attach(panel, to: window)
    place()
    panel.orderFront(nil)
  }

  func hide() {
    guard let panel else { return }
    ChildPanel.detach(panel)
    anchor = nil
    // A hidden card stops observing the model.
    hosting?.rootView = AnyView(EmptyView())
  }

  func refresh(below anchor: HoverAnchor) {
    self.anchor = anchor
    placeLater()
  }

  /// Places the panel after SwiftUI's current update, which may still change the card.
  private func placeLater() {
    DispatchQueue.main.async { [weak self] in self?.place() }
  }

  /// Below the anchor, or above it when the screen has no room below.
  private func place() {
    guard let anchor, let window = anchor.view.window, let panel, let hosting else { return }
    let size = hosting.fittingSize
    let (tile, screen) = ChildPanel.frames(of: anchor, in: window)
    let x = max(screen.minX, min(tile.minX, screen.maxX - size.width))
    let frame = NSRect(
      origin: NSPoint(x: x, y: ChildPanel.y(height: size.height, anchor: tile, screen: screen)), size: size)
    if frame != panel.frame { panel.setFrame(frame, display: true) }
  }

  private func makePanel() -> NSPanel {
    let container = HoverCardTrackingView { [weak self] inside in
      if inside { self?.card?.enteredCard() } else { self?.card?.exitedCard() }
    }
    let hosting = FirstClickHostingView(rootView: AnyView(EmptyView()))
    hosting.autoresizingMask = [.width, .height]
    container.addSubview(hosting)
    let panel = ChildPanel.make(contentView: container)
    self.panel = panel
    self.hosting = hosting
    if clickable { card?.clickableWindow = panel }
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
  /// A card drawn in a `HoverCardPanel`.
  static func panel(clickable: Bool, content: @escaping (ID) -> AnyView) -> HoverCard {
    let panel = HoverCardPanel<ID>(clickable: clickable, content: content)
    let card = HoverCard(presenter: panel)
    panel.card = card
    return card
  }

  /// Closes the card on a click outside `clickableWindow`, on any scroll or key, and when the app goes to the
  /// background. The monitor passes each event on unchanged. The click therefore still reaches the tile.
  func closeOnEvents() {
    _ = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
    ) { [weak self] event in
      MainActor.assumeIsolated {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: self?.mouseDown(in: event.window)
        default: self?.interrupt()
        }
      }
      return event
    }
    _ = NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.interrupt() } }
  }
}

extension BoardModel {
  /// The session card, and the reference card, whose links take clicks. Each reads the model.
  func makeHoverCards() {
    hoverCard = HoverCard<String>.panel(clickable: false) { [weak self] id in
      self.map { AnyView(HoverCardView(model: $0, id: id)) } ?? AnyView(EmptyView())
    }
    referenceCard = HoverCard<ReferenceCardID>.panel(clickable: true) { [weak self] id in
      guard let self else { return AnyView(EmptyView()) }
      switch id.referent {
      case .github(let ref): return AnyView(ReferenceCardView(model: self, ref: ref).inlineLinks(self))
      case .session(let target): return AnyView(SessionLinkCardView(model: self, target: target))
      }
    }
  }
}

/// The card of a session link in text. It reads every listed session and
/// follow-up, whatever the org filter shows. For a link that names no listed
/// session, it shows the name or id that the link holds and the error banner
/// that a click on the link would set.
private struct SessionLinkCardView: View {
  @ObservedObject var model: BoardModel
  let target: SessionLink.Target

  var body: some View {
    let outcome = model.linkOutcome(target)
    if case .reveal(let s) = outcome {
      HoverCardBody(content: .link(s, activeAccount: model.activeAccountFolder, names: model.sessionNames))
    } else if let message = outcome.error(for: target) {
      unresolved(message)
    }
  }

  private func unresolved(_ message: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      // `shown` leaves an id as it is, because an id holds no format character.
      Text(verbatim: BoardModel.shown(target.text)).font(.headline).lineLimit(2)
      Text(verbatim: message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .hoverCardFrame()
  }
}

/// The session's card, or nothing once the model no longer lists it.
private struct HoverCardView: View {
  @ObservedObject var model: BoardModel
  let id: String

  var body: some View {
    if let s = model.board.first(where: { $0.id == id }) {
      HoverCardBody(content: HoverCardContent(s, activeAccount: model.activeAccountFolder, names: model.sessionNames))
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
        if content.state != nil || content.id != nil {
          HStack(spacing: 6) {
            if let state = content.state { StateBadge(state: state) }
            if let id = content.id { Text(verbatim: id).font(.caption.monospaced()).foregroundStyle(.secondary) }
          }
        }
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
        .pill(pr.status.color, size: .regular, plainText: true)
      }
      if let summary = content.summary {
        // `HoverCardContent` already put the names in. A name is never scanned again.
        Text(verbatim: summary).font(.callout).lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .hoverCardFrame()
  }
}

extension View {
  /// The padding, width, background, and border of a hover card.
  func hoverCardFrame() -> some View {
    padding(12)
      .frame(width: HoverCardBody.width, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
  }
}
