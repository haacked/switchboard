import AppKit
import Foundation
import SwiftUI
import SwitchboardCore

/// Hooks for scripted checks of the GUI. SB_SELECT selects a session when the
/// app starts, SB_INBOX focuses a session's item in the Inbox, SB_ISSUES starts on the Issues view, SB_ISSUES=backlog-hidden also turns on Hide Backlog, SB_SETTINGS=<general|issues|advanced> opens the Settings window at that tab once sbd lists the sessions, SB_LOOPS starts on the Loops view, SB_BOARD_CLICK starts on the Board and opens that session's card after 2 seconds, SB_BOARD_SELECT=<id,id> starts on the Board and selects those cards once sbd lists the sessions, SB_JUMP then runs Next Needing You (⌘J) after 3, SB_SHEET=import opens the import sheet, SB_SHEET=new opens the New Session sheet, SB_SHEET_GROUP=<name or id> opens it instead with that group chosen once sessions are listed, SB_REPO_PICKER=open then opens its repository picker once the repositories are read, SB_SHEET=search opens the search panel once sessions are listed, SB_SHEET=loop opens New Loop… once sessions are listed, SB_SEARCH=<query> types that query into the panel, SB_DETAILS opens each card's Details, SB_HOVER=<id> starts on the Board and opens that session's hover card a second after its card appears, because the card otherwise opens only on a real hover, SB_HOVER_REF=<owner/name#N> opens the reference card on the first text that names that reference a second after the text appears, and SB_HOVER_REF=<session id> opens the session card on the first text that names that session by its id or links to its id link, SB_ACCOUNTS=open opens the account menu once the accounts and their usage are read, SB_ACCOUNTS_CHOOSE=<name> then chooses that account a second later, SB_ACCOUNTS_MOVE=1 instead presses the menu's Move button, SB_ACCOUNTS_CONFIRM=new-only or move then answers the switch's dialog 2 seconds after that, SB_ACCOUNT_MOVE=<session id>:<account name> asks to move that session to that account once both are listed, which shows the move's confirmation when it asks one, SB_ORG_FILTER=<org,org> starts the app with that org filter, where `(local)` names the sessions with no GitHub remote, SB_ORGS=open opens the org filter's menu once sbd lists the sessions, SB_HISTORY=<place,place> goes to each place in turn once sbd lists the sessions, where a place is a session id, `inbox`, `board`, `issues`, or `loops`, SB_HISTORY_BACK=<n> then goes back n times, SB_HISTORY_MENU=open then opens Recent Places, and SB_QUIT_FILE=<path> quits the app (⌘Q) once that file exists. SB_SNAPSHOT names a
/// PNG file that the app draws its windows into after SB_SNAPSHOT_DELAY
/// seconds (default 3): the main window with its toolbar, and any sheet or
/// popover in front of it. The app draws the windows itself, so this needs no
/// screen recording permission. The drawing leaves out the windows'
/// translucent backgrounds, so each window gets a plain background color
/// first. SB_SNAPSHOT_APPEARANCE=dark draws the dark appearance, and the default is
/// light. SB_SNAPSHOT_SIZE=<width>x<height> sets the window's content size in
/// points 1 s before the drawing, so a narrow layout can be drawn, and puts
/// the window's frame back after it. SB_SNAPSHOT_EXIT ends the app once it has drawn, with status 1 when it
/// wrote no PNG. SwiftTerm draws text in layers that the
/// drawing misses, so `sb screen` checks terminals.
/// SB_GROUP_FILTER=<id,id> starts the app with that group filter, where `(ungrouped)` names the sessions in no
/// group. Like SB_ORG_FILTER, it never saves the filter. SB_ORGS=open opens the menu that holds both filters.
@MainActor
enum Snapshot {
  static let opensDetails = ProcessInfo.processInfo.environment["SB_DETAILS"] != nil
  static let orgFilter = OrgFilter(list: ProcessInfo.processInfo.environment["SB_ORG_FILTER"] ?? "")
  static let groupFilter = GroupFilter(list: ProcessInfo.processInfo.environment["SB_GROUP_FILTER"] ?? "")
  static let opensRepoPicker = ProcessInfo.processInfo.environment["SB_REPO_PICKER"] == "open"
  static let hoverSession = ProcessInfo.processInfo.environment["SB_HOVER"]
  static let hoverReference = ProcessInfo.processInfo.environment["SB_HOVER_REF"].flatMap { value in
    if let ref = GitHubRef(parsing: value) { return Referent.github(ref).key }
    return SessionID.isValid(value) ? Referent.session(.id(value)).key : nil
  }
  static let searchQuery = ProcessInfo.processInfo.environment["SB_SEARCH"]

  static func start(_ model: BoardModel) {
    let env = ProcessInfo.processInfo.environment
    // A launch hook chooses the first place, so it records no history of its own.
    model.navigate(.replace) {
      if let id = env["SB_SELECT"] { model.selection = id }
      if let id = env["SB_INBOX"] { model.inboxFocus = id }
      if env["SB_BOARD_CLICK"] != nil || env["SB_BOARD_SELECT"] != nil || hoverSession != nil { model.show(.board) }
      if env["SB_ISSUES"] != nil { model.show(.issues) }
      if env["SB_LOOPS"] != nil { model.show(.loops) }
    }
    if let tab = env["SB_SETTINGS"].flatMap(SettingsTab.init(rawValue:)) {
      whenListed(model) { model.openSettings(tab) }
    }
    if env["SB_ISSUES"] == "backlog-hidden" { model.hidesBacklog = true }
    if let id = env["SB_BOARD_CLICK"] {
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.openFromBoard(id) }
      if env["SB_JUMP"] != nil {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { model.selectNextNeedingYou() }
      }
    }
    if let ids = env["SB_BOARD_SELECT"] {
      whenListed(model) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          model.selectBoardRect(Set(ids.split(separator: ",").map(String.init)))
        }
      }
    }
    if env["SB_SHEET"] == "import" { model.showingImport = true }
    if env["SB_SHEET"] == "new" {
      if let name = env["SB_SHEET_GROUP"] {
        whenListed(model) { model.openNewSession(group: model.groups.first { $0.name == name || $0.id == name }?.id) }
      } else {
        model.openNewSession()
      }
    }
    if env["SB_SHEET"] == "search" { openSearch(model) }
    if env["SB_SHEET"] == "loop" { whenListed(model) { model.loopEditor = .new } }
    if env["SB_ACCOUNTS"] == "open" {
      openAccounts(
        model, choose: env["SB_ACCOUNTS_CHOOSE"], move: env["SB_ACCOUNTS_MOVE"] != nil,
        confirm: env["SB_ACCOUNTS_CONFIRM"])
    }
    if env["SB_ORGS"] == "open" {
      whenListed(model) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.showingFilter = true } }
    }
    if let places = env["SB_HISTORY"] {
      visit(
        places.split(separator: ",").map(String.init), model, back: Int(env["SB_HISTORY_BACK"] ?? "") ?? 0,
        openList: env["SB_HISTORY_MENU"] == "open")
    }
    if let spec = env["SB_ACCOUNT_MOVE"], let colon = spec.lastIndex(of: ":") {
      requestAccountMove(model, id: String(spec[..<colon]), account: String(spec[spec.index(after: colon)...]))
    }
    if let path = env["SB_QUIT_FILE"] {
      Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
        if FileManager.default.fileExists(atPath: path) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
      }
    }
    TerminalSelfTest.start(model)
    DraftSelfTest.start(model)
    ShellSelfTest.start(model)
    DropSelfTest.start(model)
    KeySelfTest.start(model)
    SlashSelfTest.start(model)
    WakeSelfTest.start(model)
    guard let path = env["SB_SNAPSHOT"] else { return }
    NSApp.appearance = NSAppearance(named: env["SB_SNAPSHOT_APPEARANCE"] == "dark" ? .darkAqua : .aqua)
    let delay = Double(env["SB_SNAPSHOT_DELAY"] ?? "3") ?? 3
    let size = env["SB_SNAPSHOT_SIZE"].flatMap(contentSize)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      let window = size == nil ? nil : NSApp.switchboardWindow
      let frame = window?.frame
      if let size, let window {
        window.setContentSize(size)
        window.contentView?.layoutSubtreeIfNeeded()
      }
      // The split views fit their panes to the new size only on a later turn of the run loop.
      DispatchQueue.main.asyncAfter(deadline: .now() + (size == nil ? 0 : 1)) {
        let written = write(to: path)
        // AppKit saves the main window's frame on every change. Restoring it keeps the next launch at the user's last size.
        if let window, let frame { window.setFrame(frame, display: false) }
        // An open sheet keeps NSApp.terminate from quitting, so the hook ends the process itself.
        if env["SB_SNAPSHOT_EXIT"] != nil { exit(written ? 0 : 1) }
      }
    }
  }

  /// Runs `then` once sbd has listed the sessions.
  private static func whenListed(_ model: BoardModel, then: @escaping () -> Void) {
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
      MainActor.assumeIsolated {
        guard !model.allSessions.isEmpty else { return }
        timer.invalidate()
        then()
      }
    }
  }

  /// Goes to each place in turn as the user would, once sbd lists the sessions, so each one records a history
  /// entry. A place is a session id, `inbox`, `board`, `issues`, or `loops`. Then it goes back `back` times and opens Recent Places.
  private static func visit(_ places: [String], _ model: BoardModel, back: Int, openList: Bool) {
    var steps: [@MainActor @Sendable () -> Void] = places.map { place in
      switch place {
      case "inbox": { model.show(.inbox) }
      case "board": { model.show(.board) }
      case "issues": { model.show(.issues) }
      case "loops": { model.show(.loops) }
      default: { model.selection = place }
      }
    }
    let goBack: @MainActor @Sendable () -> Void = { model.goBack() }
    steps += Array(repeating: goBack, count: back)
    if openList { steps.append { model.showingRecentPlaces = true } }
    whenListed(model) {
      for (i, step) in steps.enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(i + 1), execute: step)
      }
    }
  }

  /// The panel ranks the sessions it sees when it opens, so the hook waits for the first list.
  private static func openSearch(_ model: BoardModel) {
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
      MainActor.assumeIsolated {
        guard !model.sessions.isEmpty else { return }
        timer.invalidate()
        model.showingSearch = true
      }
    }
  }

  /// The account menu exists only once the accounts are read, so the hook
  /// waits for them before it opens the menu.
  private static func openAccounts(_ model: BoardModel, choose name: String?, move: Bool, confirm answer: String?) {
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
      MainActor.assumeIsolated {
        guard !model.accounts.isEmpty, !model.usage.isEmpty else { return }
        timer.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.showingAccounts = true }
        let account = model.accounts.first { $0.name == name }
        guard account != nil || move else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
          if let account { model.useAccount(account.folder) } else if let plan = model.movable { model.offerMove(plan) }
        }
        guard let answer else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
          if let change = model.switchingAccount { model.confirmAccountSwitch(change, move: answer == "move") }
        }
      }
    }
  }

  /// The move needs the session and the accounts, so the hook waits for both.
  private static func requestAccountMove(_ model: BoardModel, id: String, account name: String) {
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
      MainActor.assumeIsolated {
        guard model.summary(id) != nil, let account = model.accounts.first(where: { $0.name == name }) else { return }
        timer.invalidate()
        model.requestAccountMove(id, to: account.folder)
      }
    }
  }

  /// The size that `<width>x<height>` names, or nil when the text is not one.
  nonisolated static func contentSize(_ text: String) -> NSSize? {
    let parts = text.split(separator: "x", omittingEmptySubsequences: false).map { Double($0) ?? 0 }
    guard parts.count == 2, parts.allSatisfy({ $0 > 0 }) else { return nil }
    return NSSize(width: parts[0], height: parts[1])
  }

  /// What `view` draws, on the window background color. `cacheDisplay` gets six things wrong that the window shows
  /// correctly. It leaves out the contents of some scroll views, such as a `List`'s rows. It leaves out the colors that
  /// a vibrancy filter gives sidebar text and symbols. It draws plus-lighter and plus-darker layers, such as dark
  /// sidebar text, as plain layers. It erases too much under a knockout layer, such as the selected segment of a
  /// segmented control. It draws a selected row's highlight black. It draws a translucent overlay, such as the dimming
  /// behind a sheet, opaque. This draws all six as the window shows them.
  static func cache(_ view: NSView) -> NSBitmapImageRep? {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    // The layer changes below last only for the drawing. Disabled actions keep them from animating in the window.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let restore = view.layer.map(applyVibrancy) ?? {}
    defer { restore() }
    let restoreKnockouts = view.layer.map(applyKnockouts) ?? {}
    defer { restoreKnockouts() }
    let clips = clipViews(in: view)
    // An overlay above the content, such as the dimming behind a sheet, covers the scroll views' contents too.
    let overlays =
      view.subviews.lastIndex { subview in clips.contains { $0.isDescendant(of: subview) } }
      .map { content in view.subviews[(content + 1)...].filter { $0.frame == view.bounds }.compactMap(\.layer) } ?? []
    // `applyKnockouts` has already set its masks. A blend under one of them counts as masked.
    let blends = blendedLayers(in: view, overlays: overlays)
    let showBlends = hide(blends)
    view.cacheDisplay(in: view.bounds, to: rep)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    for clip in clips { drawContents(of: clip, in: view) }
    showBlends()
    // A blend adds to what is under it, so the background goes in first.
    fillBackground(view)
    for blend in blends { draw(blend, in: view) }
    for overlay in overlays { fillSolids(overlay, in: view) }
    return rep
  }

  /// Fills the window background color under what the current context already holds, in a rounded rect of `view`'s
  /// bounds. `cacheDisplay` leaves the window's translucent material out.
  private static func fillBackground(_ view: NSView) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current?.compositingOperation = .destinationOver
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
      NSColor.windowBackgroundColor.setFill()
      NSBezierPath(roundedRect: view.bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }
  }

  /// The corner radius of a window and of a popover.
  private static let cornerRadius: CGFloat = 10

  /// A layer that the window server blends with what is under it, the opacity that its ancestors give it, and the
  /// part of the view where it shows, in the root layer's coordinates.
  private struct BlendedLayer {
    let layer: CALayer
    let mode: CGBlendMode
    let opacity: Float
    let visible: CGRect
  }

  /// The blend mode of each `compositingFilter` that AppKit puts on sidebar text and symbols: plus-lighter in the dark
  /// appearance and plus-darker in the light one.
  private static let blendModes: [String: CGBlendMode] = ["plusL": .plusLighter, "plusD": .plusDarker]

  /// Each layer under `view`'s layer that has a blending `compositingFilter`, that shows, and that `draw(_:in:)` can
  /// draw as the window does. A layer under a hidden or fully transparent ancestor does not show, such as an overlay
  /// scroller that has faded out. `draw(_:in:)` renders the layer alone, clips it to rects, and draws it after
  /// everything else. So it leaves out a layer that an ancestor changes some other way, such as with a mask, rounded
  /// clipping, or a transform, and a layer that something drawn after it covers. The `overlays` that `fillSolids`
  /// draws last do not count. `cacheDisplay` draws the layers it leaves out as plain layers.
  private static func blendedLayers(in view: NSView, overlays: [CALayer]) -> [BlendedLayer] {
    guard let root = view.layer else { return [] }
    func visit(_ layer: CALayer, opacity: Float) -> [BlendedLayer] {
      guard !layer.isHidden, layer.opacity > 0 else { return [] }
      if let mode = (layer.compositingFilter as? String).flatMap({ blendModes[$0] }) {
        guard isTranslation(layer.transform) else { return [] }
        let visible = visibleRect(of: layer, in: view)
        // A layer that shows nowhere stays in the list, so it stays out of `cacheDisplay` too.
        guard visible.isEmpty || !isCovered(layer, within: visible, root: root, overlays: overlays) else { return [] }
        return [BlendedLayer(layer: layer, mode: mode, opacity: opacity, visible: visible)]
      }
      let plain =
        layer.mask == nil && !(layer.masksToBounds && layer.cornerRadius > 0) && isTranslation(layer.transform)
        && CATransform3DIsIdentity(layer.sublayerTransform) && (layer.filters ?? []).isEmpty
        && layer.compositingFilter == nil
      guard plain else { return [] }
      return (layer.sublayers ?? []).flatMap { visit($0, opacity: opacity * layer.opacity) }
    }
    return visit(root, opacity: 1)
  }

  private static func isTranslation(_ transform: CATransform3D) -> Bool {
    CATransform3DIsIdentity(CATransform3DTranslate(transform, -transform.m41, -transform.m42, -transform.m43))
  }

  /// The part of `layer` that shows inside each ancestor that masks to its bounds and inside the visible part of the
  /// scroll view that holds it, as `drawContents` draws, in the root layer's coordinates.
  private static func visibleRect(of layer: CALayer, in view: NSView) -> CGRect {
    guard let root = view.layer else { return .null }
    var visible = layer.convert(layer.bounds, to: root)
    var ancestor = layer.superlayer
    while let outer = ancestor, outer !== root {
      if let clip = outer.delegate as? NSClipView { return visible.intersection(visibleRect(of: clip, in: view)) }
      if outer.masksToBounds { visible = visible.intersection(outer.convert(outer.bounds, to: root)) }
      ancestor = outer.superlayer
    }
    return visible
  }

  /// Whether a layer that Core Animation draws after `layer` draws something inside `rect`, or whether the draw order
  /// is unclear because siblings on the way to `root` differ in `zPosition`.
  private static func isCovered(_ layer: CALayer, within rect: CGRect, root: CALayer, overlays: [CALayer]) -> Bool {
    var child = layer
    while child !== root, let parent = child.superlayer {
      let siblings = (parent.sublayers ?? []).filter { !$0.isHidden }
      guard siblings.allSatisfy({ $0.zPosition == child.zPosition }),
        let index = siblings.firstIndex(where: { $0 === child })
      else { return true }
      let later = siblings[(index + 1)...].filter { sibling in !overlays.contains { $0 === sibling } }
      if later.contains(where: { draws($0, within: rect, root: root) }) { return true }
      child = parent
    }
    return false
  }

  /// Whether `layer` or a layer under it draws anything inside `rect`, a rect in `root`'s coordinates.
  private static func draws(_ layer: CALayer, within rect: CGRect, root: CALayer) -> Bool {
    guard !layer.isHidden, layer.opacity > 0 else { return false }
    let shadow =
      layer.shadowOpacity > 0
      ? layer.shadowRadius + max(abs(layer.shadowOffset.width), abs(layer.shadowOffset.height)) : 0
    let paints =
      (layer.backgroundColor.map { $0.alpha > 0 } ?? false) || layer.contents != nil || layer.borderWidth > 0
      || shadow > 0 || layer.compositingFilter != nil
    if paints && layer.convert(layer.bounds.insetBy(dx: -shadow, dy: -shadow), to: root).intersects(rect) {
      return true
    }
    return (layer.sublayers ?? []).contains { draws($0, within: rect, root: root) }
  }

  /// Sets each blended layer's opacity to 0, which leaves it out of `cacheDisplay`, and returns a function that puts
  /// the opacities back.
  private static func hide(_ blends: [BlendedLayer]) -> () -> Void {
    let opacities = blends.map(\.layer.opacity)
    for blend in blends { blend.layer.opacity = 0 }
    return { for (blend, opacity) in zip(blends, opacities) { blend.layer.opacity = opacity } }
  }

  /// Draws `blend` into the current context with its blend mode, inside the part of the view where it shows.
  private static func draw(_ blend: BlendedLayer, in view: NSView) {
    guard let root = view.layer, let context = NSGraphicsContext.current?.cgContext else { return }
    let layer = blend.layer
    let frame = layer.convert(layer.bounds, to: root)
    let scale = context.convertToDeviceSpace(CGSize(width: 1, height: 1)).width
    guard !blend.visible.isEmpty,
      let image = bitmapContext(
        width: Int((layer.bounds.width * scale).rounded(.up)), height: Int((layer.bounds.height * scale).rounded(.up)))
    else { return }
    image.scaleBy(x: scale, y: scale)
    if layer.contentsAreFlipped() {
      image.translateBy(x: 0, y: layer.bounds.height)
      image.scaleBy(x: 1, y: -1)
    }
    layer.render(in: image)
    guard let rendered = image.makeImage() else { return }
    context.saveGState()
    defer { context.restoreGState() }
    context.clip(to: unflipped(blend.visible, in: view))
    context.setBlendMode(blend.mode)
    context.setAlpha(CGFloat(blend.opacity))
    context.draw(rendered, in: unflipped(frame, in: view))
  }

  /// A `destOut` compositing filter erases its superlayer's other sublayers where its shapes are opaque, such as the
  /// labels under the selected segment of a segmented control, which draws its own label on top. `cacheDisplay`
  /// erases everything under the shapes instead, including the selected segment. This hides each such layer and masks
  /// its superlayer to leave out the shapes. It returns a function that puts both back. It leaves a layer alone
  /// unless the mask can stand for it: every visible sibling draws before the layer, the superlayer has no mask, and
  /// the layer and its sublayers draw only opaque solid rounded rects.
  static func applyKnockouts(_ layer: CALayer) -> () -> Void {
    var restores: [() -> Void] = []
    func visit(_ layer: CALayer) {
      guard !layer.isHidden else { return }
      if (layer.compositingFilter as? String) == "destOut" {
        guard let parent = layer.superlayer, drawsLast(layer, in: parent), parent.mask == nil,
          let shapes = knockoutShapes(layer, in: parent)
        else {
          FileHandle.standardError.write(
            Data(
              "snapshot: a knockout layer is not drawn as the window shows it, so the drawing erases too much under it\n"
                .utf8))
          return
        }
        let mask = CAShapeLayer()
        mask.frame = parent.bounds
        mask.path = shapes.reduce(CGPath(rect: parent.bounds, transform: nil)) { $0.subtracting($1) }
        parent.mask = mask
        layer.isHidden = true
        restores.append {
          parent.mask = nil
          layer.isHidden = false
        }
        return
      }
      layer.sublayers?.forEach(visit)
    }
    visit(layer)
    return { restores.reversed().forEach { $0() } }
  }

  /// Whether Core Animation draws every visible sibling of `layer` before it. The mask erases from every sublayer of
  /// `parent`, and the window erases only from the sublayers drawn before the knockout. Core Animation draws siblings
  /// in order of `zPosition`, then in array order.
  private static func drawsLast(_ layer: CALayer, in parent: CALayer) -> Bool {
    let siblings = (parent.sublayers ?? []).filter { !$0.isHidden }
    return siblings.last === layer && siblings.allSatisfy { $0.zPosition == layer.zPosition }
  }

  /// The outlines of what the knockout `layer` erases, in `parent`'s coordinates, or nil when something it draws is
  /// not an opaque solid rounded rect.
  private static func knockoutShapes(_ layer: CALayer, in parent: CALayer) -> [CGPath]? {
    // A plain CALayer draws its background, border, shadow, contents, and sublayers, and its filters, mask, opacity,
    // and transforms change them. A subclass such as CAShapeLayer or CATextLayer draws more.
    func isSolid(_ shape: CALayer) -> Bool {
      type(of: shape) == CALayer.self && (shape.filters ?? []).isEmpty && (shape.backgroundFilters ?? []).isEmpty
        && CATransform3DIsIdentity(shape.sublayerTransform) && shape.contents == nil && shape.mask == nil
        && shape.borderWidth == 0 && shape.shadowOpacity == 0
        && shape.opacity == 1 && CATransform3DIsIdentity(shape.transform)
        && (shape.cornerRadius == 0 || shape.maskedCorners == Self.allCorners)
        && (shape.backgroundColor.map { $0.alpha == 1 } ?? true)
    }
    let sublayers = (layer.sublayers ?? []).filter { !$0.isHidden }
    guard isSolid(layer),
      sublayers.allSatisfy({ isSolid($0) && $0.compositingFilter == nil && ($0.sublayers ?? []).isEmpty }),
      !layer.masksToBounds || sublayers.allSatisfy({ layer.bounds.contains($0.frame) })
    else { return nil }
    return ([layer] + sublayers).filter { $0.backgroundColor != nil }.map { shape in
      let rect = shape.convert(shape.bounds, to: parent)
      let radius = min(shape.cornerRadius, rect.width / 2, rect.height / 2)
      return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
  }

  private static let allCorners: CACornerMask = [
    .layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner,
  ]

  /// Fills each layer under `layer` that has a background color, such as the dimming behind a sheet, at its
  /// opacity. `cacheDisplay` draws those layers opaque.
  private static func fillSolids(_ layer: CALayer, in view: NSView) {
    guard let root = view.layer, let context = NSGraphicsContext.current?.cgContext else { return }
    func visit(_ layer: CALayer, opacity: Float) {
      guard !layer.isHidden else { return }
      let alpha = opacity * layer.opacity
      if let color = layer.backgroundColor {
        context.setFillColor(color.copy(alpha: color.alpha * CGFloat(alpha)) ?? color)
        context.fill(unflipped(layer.convert(layer.bounds, to: root), in: view))
      }
      layer.sublayers?.forEach { visit($0, opacity: alpha) }
    }
    visit(layer, opacity: 1)
  }

  /// Every clip view under `view`, each one before the clip views inside it.
  private static func clipViews(in view: NSView) -> [NSClipView] {
    ((view as? NSClipView).map { [$0] } ?? []) + view.subviews.flatMap(clipViews)
  }

  /// Draws what `clip` shows into the current context, which holds `view`'s image. A table draws row by row, because
  /// `cacheDisplay` of the table leaves its rows out. The drawing stays inside the scroll view's safe area, because
  /// content scrolls under the floating sidebar, the toolbar, and inset bars such as the sidebar's search field.
  private static func drawContents(of clip: NSClipView, in view: NSView) {
    guard let document = clip.documentView, !clip.isHiddenOrHasHiddenAncestor else { return }
    let visible = visibleRect(of: clip, in: view)
    guard !visible.isEmpty else { return }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSBezierPath(rect: unflipped(visible, in: view)).addClip()
    guard document is NSTableView else { return draw(document, within: visible, in: view) }
    for row in document.subviews.compactMap({ $0 as? NSTableRowView }) {
      if row.isSelected { drawSelected(row, within: visible, in: view) } else { draw(row, within: visible, in: view) }
    }
  }

  /// The part of `view` that `clip` shows, in `view`'s coordinates.
  private static func visibleRect(of clip: NSClipView, in view: NSView) -> NSRect {
    let scroll = clip.enclosingScrollView ?? clip
    var visible = scroll.convert(scroll.safeAreaRect, to: view).intersection(clip.convert(clip.bounds, to: view))
    // A scroll view inside another one, such as a code block in a transcript, shows only what the outer one shows.
    var ancestor = clip.superview
    while let outer = ancestor, outer !== view {
      if let outerClip = outer as? NSClipView {
        visible = visible.intersection(outerClip.convert(outerClip.bounds, to: view))
      }
      ancestor = outer.superview
    }
    return visible
  }

  /// Draws the part of `part` inside `visible`, a rect in `view`'s coordinates. A long document caches only what
  /// shows.
  private static func draw(_ part: NSView, within visible: NSRect, in view: NSView) {
    let rect = part.convert(visible, from: view).intersection(part.bounds)
    guard !rect.isEmpty, let image = part.bitmapImageRepForCachingDisplay(in: rect) else { return }
    part.cacheDisplay(in: rect, to: image)
    image.draw(in: unflipped(part.convert(rect, to: view), in: view))
  }

  /// A selected row draws its highlight with a visual effect view, which `cacheDisplay` draws black. This draws the
  /// row's cells and then blends the selection color over them: multiplied in light mode, and at half opacity in dark
  /// mode, so the text stays readable on the highlight. The cells draw an opaque background, which would cover a fill
  /// drawn first.
  private static func drawSelected(_ row: NSTableRowView, within visible: NSRect, in view: NSView) {
    // The separator view fills the row and draws over everything under it.
    for subview in row.subviews where !(subview is NSVisualEffectView) && subview.frame != row.bounds {
      draw(subview, within: visible, in: view)
    }
    let color: NSColor =
      row.isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
    let dark = row.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let (operation, fill): (NSCompositingOperation, NSColor) =
      dark ? (.sourceOver, color.withAlphaComponent(0.5)) : (.multiply, color)
    let rect = unflipped(row.convert(row.bounds.insetBy(dx: 10, dy: 0), to: view), in: view)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current?.compositingOperation = operation
    row.effectiveAppearance.performAsCurrentDrawingAppearance {
      fill.setFill()
      NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
    }
  }

  /// `rect` in `view`'s coordinates, moved to a context whose origin is at the bottom left.
  private static func unflipped(_ rect: NSRect, in view: NSView) -> NSRect {
    guard view.isFlipped else { return rect }
    return NSRect(x: rect.minX, y: view.bounds.height - rect.maxY, width: rect.width, height: rect.height)
  }

  /// A `vibrantColorMatrix` filter recolors a layer as the window server composites it, so `cacheDisplay` draws the
  /// layer in the filter's input colors, such as a white status dot. This gives each such layer under `layer` the
  /// colors that its filter makes, and returns a function that puts the original colors back.
  static func applyVibrancy(_ layer: CALayer) -> () -> Void {
    var restores: [() -> Void] = []
    func visit(_ layer: CALayer) {
      if let matrix = vibrantMatrix(of: layer) {
        if let color = layer.backgroundColor {
          layer.backgroundColor = apply(matrix, to: color)
          restores.append { layer.backgroundColor = color }
        }
        // SwiftUI draws a rounded rectangle's stroke, such as a highlight ring, as the layer's border.
        if layer.borderWidth > 0, let color = layer.borderColor {
          layer.borderColor = apply(matrix, to: color)
          restores.append { layer.borderColor = color }
        }
        if let contents = layer.contents as? NSObject, let image = tinted(contents, through: matrix) {
          layer.contents = image
          restores.append { layer.contents = contents }
        }
      }
      layer.sublayers?.forEach(visit)
    }
    visit(layer)
    return { restores.reversed().forEach { $0() } }
  }

  /// The 4×5 color matrix of the layer's `vibrantColorMatrix` filter, row by row, or nil when it has none.
  private static func vibrantMatrix(of layer: CALayer) -> [Float]? {
    guard
      let filter = layer.filters?.compactMap({ $0 as? NSObject }).first(where: {
        String(describing: $0) == "vibrantColorMatrix"
      }),
      let value = filter.value(forKey: "inputColorMatrix") as? NSValue
    else { return nil }
    var matrix = [Float](repeating: 0, count: 20)
    value.getValue(&matrix, size: MemoryLayout<Float>.size * matrix.count)
    return matrix
  }

  /// The color that the 4×5 color `matrix` makes of `color`: each output component is its row's dot product with
  /// the input's red, green, blue, and alpha, plus the row's last value, clamped to 0…1.
  nonisolated static func apply(_ matrix: [Float], to color: CGColor) -> CGColor {
    guard matrix.count == 20, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
      let input = color.converted(to: srgb, intent: .defaultIntent, options: nil)?.components, input.count == 4
    else { return color }
    let output = (0..<4).map { row in
      let m = matrix[(row * 5)..<(row * 5 + 5)].map { CGFloat($0) }
      return min(max(zip(m, input + [1]).reduce(0) { $0 + $1.0 * $1.1 }, 0), 1)
    }
    return CGColor(srgbRed: output[0], green: output[1], blue: output[2], alpha: output[3])
  }

  /// A `CATintedImage`'s template image filled with its tint after `matrix` recolors it, or nil for other contents.
  /// CATintedImage is private. Its `image` and `tint` methods return a CGImage and a CGColor, and it has no KVC keys.
  private static func tinted(_ contents: NSObject, through matrix: [Float]) -> CGImage? {
    guard String(describing: type(of: contents)) == "CATintedImage",
      let image = contents.perform(NSSelectorFromString("image"))?.takeUnretainedValue(),
      CFGetTypeID(image) == CGImage.typeID,
      let tint = contents.perform(NSSelectorFromString("tint"))?.takeUnretainedValue(),
      CFGetTypeID(tint) == CGColor.typeID
    else { return nil }
    let template = image as! CGImage
    let rect = CGRect(x: 0, y: 0, width: template.width, height: template.height)
    guard let context = bitmapContext(width: template.width, height: template.height) else { return nil }
    context.draw(template, in: rect)
    context.setBlendMode(.sourceIn)
    context.setFillColor(apply(matrix, to: tint as! CGColor))
    context.fill(rect)
    return context.makeImage()
  }

  /// An empty RGBA bitmap context of `width` by `height` pixels.
  private static func bitmapContext(width: Int, height: Int) -> CGContext? {
    CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  }

  /// Returns false when it wrote no PNG. It writes to a temporary file first, so the PNG never exists half written.
  @discardableResult
  static func write(to path: String) -> Bool {
    guard let main = NSApp.switchboardWindow else {
      FileHandle.standardError.write(Data("snapshot: no window to draw\n".utf8))
      return false
    }
    // A popover's window is a child window of the window that presents it, which is the main window or its sheet.
    let sheet = main.attachedSheet
    let popovers = ((main.childWindows ?? []) + (sheet?.childWindows ?? [])).filter { $0.isVisible && $0 != sheet }
    let windows = [main] + [sheet].compactMap { $0 } + popovers
    let bounds = windows.reduce(main.frame) { $0.union($1.frame) }
    let scale = main.backingScaleFactor
    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else { return false }
    rep.size = bounds.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    for window in windows {
      // The theme frame holds the toolbar as well as the content. A popover's
      // frame draws its shadow as colored noise, so only its content draws.
      let popover = popovers.contains(window)
      guard let content = window.contentView else { continue }
      let view = popover ? content : content.superview ?? content
      guard let image = cache(view) else { continue }
      let rect = window.convertToScreen(view.convert(view.bounds, to: nil)).offsetBy(dx: -bounds.minX, dy: -bounds.minY)
      image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      if popover {
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
          NSColor.separatorColor.setStroke()
          NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
            .stroke()
        }
      }
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    do {
      try png.write(to: URL(fileURLWithPath: path), options: .atomic)
      return true
    } catch {
      FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
      return false
    }
  }
}
