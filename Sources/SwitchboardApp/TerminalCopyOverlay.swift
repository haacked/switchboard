import AppKit
import SwiftTerm
import SwitchboardCore
import os

/// Reads the blocks of the session's recent assistant messages off the main thread, and calls back on it.
typealias BlockSourcesLoader = (@escaping @MainActor @Sendable (BlockSources) -> Void) -> Void

/// Shows a copy button at the top right of the block quote or code block under the pointer in a Claude terminal.
/// It owns the padded view's tracking area, so the terminal's own mouse events do not reach it.
@MainActor
final class TerminalCopyOverlay: NSResponder {
  static let refreshDelay: Duration = .milliseconds(100)
  static let fetchInterval: Duration = .seconds(2)

  private unowned let host: PaddedTerminalView
  private let loadBlockSources: BlockSourcesLoader
  let button = NSButton()
  /// Tests set a pasteboard of their own, so they leave the user's clipboard alone.
  var pasteboard = NSPasteboard.general
  private var trackingArea: NSTrackingArea?
  private var monitor: Any?
  /// Set on SwiftTerm's parse thread when output arrives, and cleared by `refresh`. Only the output that sets it
  /// wakes the main actor, so a burst of output costs one refresh.
  private let outputPending = OSAllocatedUnfairLock(initialState: false)

  /// The pointer's location in the terminal's coordinates, or nil when the pointer is outside the pane.
  private var pointer: NSPoint?
  private var dragging = false
  private var refreshPending = false
  private var rows: [String] = []
  private var sources = BlockSources(messages: [])
  private var blocks: [TerminalBlock] = []
  private var shown: TerminalBlock?
  private var fetching = false
  private var fetchRequested = false
  private var pendingFetch: Task<Void, Never>?
  private var lastFetch: ContinuousClock.Instant?
  private var copiedUntil: ContinuousClock.Instant?

  init(host: PaddedTerminalView, loadBlockSources: @escaping BlockSourcesLoader) {
    self.host = host
    self.loadBlockSources = loadBlockSources
    super.init()
    button.bezelStyle = .inline
    button.controlSize = .small
    button.imagePosition = .imageLeading
    button.target = self
    button.action = #selector(copyBlock)
    button.isHidden = true
    button.toolTip = "Copy the block's Markdown"
    showCopyLabel()
    host.addSubview(button)
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    host.addTrackingArea(area)
    trackingArea = area
    // A drag in the pane selects text, in tmux or in SwiftTerm, and the button would cover the selection.
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
      self?.mouse(event)
      return event
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    host.terminal.setProcessOutputHandler(nil)
    pendingFetch?.cancel()
    if let trackingArea { host.removeTrackingArea(trackingArea) }
    trackingArea = nil
    button.removeFromSuperview()
  }

  override func mouseEntered(with event: NSEvent) {
    pointer = location(of: event)
    // The terminal redraws as output arrives. The handler runs on SwiftTerm's parse thread, only while the
    // pointer is in the pane.
    host.terminal.setProcessOutputHandler { [weak self, outputPending] in
      let first = outputPending.withLock { pending in
        defer { pending = true }
        return !pending
      }
      if first { Task { @MainActor in self?.scheduleRefresh() } }
    }
    fetchIfStale()
    refresh()
  }

  override func mouseMoved(with event: NSEvent) {
    pointer = location(of: event)
    place()
  }

  override func mouseExited(with event: NSEvent) {
    pointer = nil
    host.terminal.setProcessOutputHandler(nil)
    hide()
  }

  private func mouse(_ event: NSEvent) {
    guard event.window === host.window else { return }
    if event.type == .leftMouseDragged, pointer != nil {
      dragging = true
      hide()
    } else if event.type == .leftMouseUp, dragging {
      dragging = false
      scheduleRefresh()
    }
  }

  private func location(of event: NSEvent) -> NSPoint {
    host.terminal.convert(event.locationInWindow, from: nil)
  }

  /// Runs `refresh` once after a short delay, however many redraws arrive before then. SwiftTerm can report
  /// a redraw while it holds the terminal lock, which `visibleRowsText` takes, so the read never runs inline.
  func scheduleRefresh() {
    guard pointer != nil, !refreshPending else { return }
    refreshPending = true
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.refreshDelay)
      self?.refreshPending = false
      self?.refresh()
    }
  }

  private func refresh() {
    outputPending.withLock { $0 = false }
    guard pointer != nil else { return hide() }
    let terminal = host.terminal
    let screen = terminal.visibleRowsText(0..<terminal.terminalDimensions.rows)
    if screen != rows {
      rows = screen
      rematch()
      fetchIfStale()
    }
    place()
  }

  private func rematch() { blocks = TerminalBlocks.find(rows: rows, sources: sources) }

  /// Reads the transcript at most once per `fetchInterval`. A request inside the interval runs when the interval
  /// ends, and a request during a read runs one interval after that read. The transcript gets a reply's last
  /// lines as the screen settles. No later screen change would ask for them.
  private func fetchIfStale() {
    if fetching {
      fetchRequested = true
      return
    }
    guard pendingFetch == nil else { return }
    let wait = lastFetch.map { Self.fetchInterval - (ContinuousClock.now - $0) } ?? .zero
    if wait > .zero {
      pendingFetch = Task { @MainActor [weak self] in
        try? await Task.sleep(for: wait)
        guard let self, !Task.isCancelled else { return }
        pendingFetch = nil
        if pointer != nil { fetchIfStale() }
      }
      return
    }
    fetching = true
    loadBlockSources { [weak self] sources in
      guard let self else { return }
      fetching = false
      lastFetch = ContinuousClock.now
      if sources != self.sources {
        self.sources = sources
        rematch()
        place()
      }
      if fetchRequested {
        fetchRequested = false
        fetchIfStale()
      }
    }
  }

  /// Shows the button on the block under the pointer, or hides it.
  private func place() {
    let terminal = host.terminal
    let rowCount = terminal.terminalDimensions.rows
    guard let pointer, !dragging, rowCount > 0, !terminal.selectionActive else { return hide() }
    let cellHeight = terminal.getOptimalFrameSize().height / CGFloat(rowCount)
    guard cellHeight > 0 else { return hide() }
    let size = terminal.bounds.size
    let row = Self.row(at: pointer.y, cellHeight: cellHeight, height: size.height)
    guard let block = blocks.first(where: { $0.rows.contains(row) }) else { return hide() }
    let changed = block != shown
    shown = block
    if changed, copiedUntil == nil { showCopyLabel() }
    let topRight = host.convert(
      Self.topRight(row: block.rows.lowerBound, cellHeight: cellHeight, size: size), from: terminal)
    button.setFrameOrigin(NSPoint(x: topRight.x - button.frame.width, y: topRight.y - button.frame.height))
    button.isHidden = false
  }

  /// The screen row at `y` in the terminal's coordinates. The terminal is not flipped. SwiftTerm draws row 0 at
  /// the top of its bounds, so rows count down from `height`.
  static func row(at y: CGFloat, cellHeight: CGFloat, height: CGFloat) -> Int {
    Int((height - y) / cellHeight)
  }

  /// The button's top right corner in the terminal's coordinates, inset from the pane's right edge.
  static func topRight(row: Int, cellHeight: CGFloat, size: NSSize) -> NSPoint {
    NSPoint(x: size.width - 4, y: size.height - CGFloat(row) * cellHeight)
  }

  private func hide() {
    button.isHidden = true
    shown = nil
  }

  @objc private func copyBlock() {
    guard let shown else { return }
    DraftCopy.copy(shown.copyText, to: pasteboard)
    button.title = "Copied"
    button.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
    button.setAccessibilityLabel("Copied")
    button.sizeToFit()
    let until = ContinuousClock.now + .seconds(DraftCopyButton.copiedSeconds)
    copiedUntil = until
    Task { @MainActor [weak self] in
      try? await Task.sleep(until: until, clock: .continuous)
      guard let self, copiedUntil == until else { return }
      copiedUntil = nil
      showCopyLabel()
      place()
    }
  }

  private func showCopyLabel() {
    button.title = ""
    button.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
    button.setAccessibilityLabel(shown?.kind == .code ? "Copy code" : "Copy quote")
    button.sizeToFit()
  }
}
