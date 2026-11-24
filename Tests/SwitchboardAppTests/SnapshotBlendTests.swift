import AppKit
import Foundation
import QuartzCore
import Testing

@testable import SwitchboardApp

/// A layer-backed view in a borderless window that is never shown, so `Snapshot.cache` draws it at the screen's
/// scale.
@MainActor
private struct Canvas {
  final class FlippedView: NSView {
    override var isFlipped: Bool { true }
  }

  static let size = NSSize(width: 120, height: 60)

  let window: NSWindow
  let view: NSView
  let appearance: NSAppearance

  init(dark: Bool, flipped: Bool = false) {
    _ = NSApplication.shared
    let frame = NSRect(origin: .zero, size: Self.size)
    view = flipped ? FlippedView(frame: frame) : NSView(frame: frame)
    view.wantsLayer = true
    appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    view.appearance = appearance
    window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    view.layoutSubtreeIfNeeded()
  }

  var root: CALayer { view.layer! }

  /// The window must outlive the drawing.
  func cache() throws -> NSBitmapImageRep {
    try withExtendedLifetime(window) { try #require(Snapshot.cache(view)) }
  }

  /// The pixel at `x` points from the left and `y` points from the top of the bitmap.
  func pixel(_ rep: NSBitmapImageRep, x: CGFloat, fromTop y: CGFloat) throws -> NSColor {
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    return try #require(rep.colorAt(x: Int(x * scale), y: Int(y * scale)))
  }

  /// The window background color in this canvas's appearance, as red, green, and blue in `rep`'s color space.
  func background(in rep: NSBitmapImageRep) throws -> [CGFloat] {
    var color: NSColor?
    appearance.performAsCurrentDrawingAppearance {
      color = NSColor.windowBackgroundColor.usingColorSpace(rep.colorSpace)
    }
    return try rgb(try #require(color))
  }

  /// A gray of white level `white` as red, green, and blue in `rep`'s color space.
  static func gray(_ white: CGFloat, in rep: NSBitmapImageRep) throws -> [CGFloat] {
    try rgb(try #require(NSColor(srgbRed: white, green: white, blue: white, alpha: 1).usingColorSpace(rep.colorSpace)))
  }
}

private func rgb(_ color: NSColor) throws -> [CGFloat] {
  try #require(color.numberOfComponents >= 3)
  return [color.redComponent, color.greenComponent, color.blueComponent]
}

/// Whether `color`'s red, green, and blue are `expected`, to within 0.03.
private func matches(_ color: NSColor, _ expected: [CGFloat]) -> Bool {
  guard let actual = try? rgb(color) else { return false }
  return zip(actual, expected).allSatisfy { abs($0 - $1) < 0.03 }
}

/// An opaque layer filled with a gray of white level `white`.
private func solid(_ frame: CGRect, white: CGFloat) -> CALayer {
  let layer = CALayer()
  layer.frame = frame
  layer.backgroundColor = CGColor(srgbRed: white, green: white, blue: white, alpha: 1)
  return layer
}

private func plus(_ filter: String, _ frame: CGRect, white: CGFloat) -> CALayer {
  let layer = solid(frame, white: white)
  layer.compositingFilter = filter
  return layer
}

/// What the window server shows for a `filter` layer of `gray` over `background`, channel by channel.
private func blended(_ filter: String, _ gray: [CGFloat], over background: [CGFloat]) -> [CGFloat] {
  zip(background, gray).map { b, g in filter == "plusL" ? min(1, b + g) : max(0, b + g - 1) }
}

struct BlendCase: Sendable, CustomTestStringConvertible {
  let dark: Bool
  let filter: String
  let white: CGFloat

  var testDescription: String { "\(filter) of \(white) in \(dark ? "dark" : "light")" }
}

@MainActor
@Suite struct SnapshotBlendTests {
  /// Every case gives a result that differs from both the background and the gray drawn as a plain layer. The last two
  /// clamp.
  nonisolated static let cases: [BlendCase] = [
    BlendCase(dark: true, filter: "plusL", white: 0.3),
    BlendCase(dark: false, filter: "plusL", white: 0.05),
    BlendCase(dark: false, filter: "plusD", white: 0.5),
    BlendCase(dark: true, filter: "plusD", white: 0.9),
    BlendCase(dark: false, filter: "plusL", white: 0.5),
    BlendCase(dark: true, filter: "plusD", white: 0.2),
  ]

  /// A strip that spans the view's middle third vertically, so it is in the same place whichever way the view flips.
  static let strip = CGRect(x: 40, y: 15, width: 40, height: 30)

  @Test(arguments: [false, true]) func anEmptyViewShowsTheWindowBackground(dark: Bool) throws {
    let canvas = Canvas(dark: dark)

    let rep = try canvas.cache()

    #expect(matches(try canvas.pixel(rep, x: 60, fromTop: 30), try canvas.background(in: rep)))
  }

  @Test func theBackgroundLeavesOutTheRoundedCorners() throws {
    let canvas = Canvas(dark: true)

    let rep = try canvas.cache()

    #expect(try canvas.pixel(rep, x: 0, fromTop: 0).alphaComponent < 0.03)
  }

  @Test(arguments: [false, true]) func aPlainLayerKeepsItsColor(dark: Bool) throws {
    let canvas = Canvas(dark: dark)
    canvas.root.addSublayer(solid(Self.strip, white: 0.5))

    let rep = try canvas.cache()

    #expect(matches(try canvas.pixel(rep, x: 60, fromTop: 30), try Canvas.gray(0.5, in: rep)))
  }

  @Test(arguments: cases) func aPlusLayerBlendsWithTheWindowBackground(_ blend: BlendCase) throws {
    let canvas = Canvas(dark: blend.dark)
    canvas.root.addSublayer(plus(blend.filter, Self.strip, white: blend.white))

    let rep = try canvas.cache()

    let expected = blended(blend.filter, try Canvas.gray(blend.white, in: rep), over: try canvas.background(in: rep))
    #expect(matches(try canvas.pixel(rep, x: 60, fromTop: 30), expected))
  }

  @Test(arguments: ["plusL", "plusD"]) func pixelsAwayFromAPlusLayerShowTheBackground(_ filter: String) throws {
    let canvas = Canvas(dark: filter == "plusL")
    canvas.root.addSublayer(plus(filter, Self.strip, white: 0.5))

    let rep = try canvas.cache()

    #expect(matches(try canvas.pixel(rep, x: 20, fromTop: 30), try canvas.background(in: rep)))
  }

  /// Draws `layer` as a plain layer and returns the one of `rows` where the pixel at x 60 is `white`, then the other.
  private func rows(
    _ rows: (CGFloat, CGFloat), showing white: CGFloat, in layer: CALayer, flipped: Bool
  ) throws -> (shows: CGFloat, other: CGFloat) {
    let control = Canvas(dark: true, flipped: flipped)
    control.root.addSublayer(layer)
    let rep = try control.cache()
    let gray = try Canvas.gray(white, in: rep)
    let firstShows = matches(try control.pixel(rep, x: 60, fromTop: rows.0), gray)
    try #require(firstShows != matches(try control.pixel(rep, x: 60, fromTop: rows.1), gray))
    return firstShows ? rows : (rows.1, rows.0)
  }

  /// The layer sits in one half of the view. A plain copy of it shows which half `cacheDisplay` puts it in, and the
  /// blended layer must land in the same half.
  @Test(arguments: [false, true]) func aPlusLayerDrawsWhereAPlainLayerDraws(flipped: Bool) throws {
    let frame = CGRect(x: 40, y: 12, width: 40, height: 12)
    let (inside, outside) = try rows((18, 42), showing: 0.3, in: solid(frame, white: 0.3), flipped: flipped)
    let canvas = Canvas(dark: true, flipped: flipped)
    canvas.root.addSublayer(plus("plusL", frame, white: 0.3))

    let rep = try canvas.cache()

    let background = try canvas.background(in: rep)
    let gray = try Canvas.gray(0.3, in: rep)
    #expect(matches(try canvas.pixel(rep, x: 60, fromTop: inside), blended("plusL", gray, over: background)))
    #expect(matches(try canvas.pixel(rep, x: 60, fromTop: outside), background))
  }

  /// A 0.1 gray layer whose first 18 points hold a 0.4 gray sublayer. A plain copy shows which row `cacheDisplay`
  /// puts the sublayer in, and the blended layer must draw it in the same row, not upside down.
  @Test(arguments: [false, true]) func aPlusLayerKeepsItsContentRightSideUp(flipped: Bool) throws {
    func tree(_ make: (CGRect, CGFloat) -> CALayer) -> CALayer {
      let layer = make(CGRect(x: 40, y: 12, width: 40, height: 36), 0.1)
      layer.addSublayer(solid(CGRect(x: 0, y: 0, width: 40, height: 18), white: 0.4))
      return layer
    }
    let (sublayerRow, layerRow) = try rows((21, 39), showing: 0.4, in: tree { solid($0, white: $1) }, flipped: flipped)
    let canvas = Canvas(dark: true, flipped: flipped)
    let blend = tree { plus("plusL", $0, white: $1) }
    canvas.root.addSublayer(blend)
    if flipped { try #require(blend.contentsAreFlipped()) }

    let rep = try canvas.cache()

    let background = try canvas.background(in: rep)
    let light = try Canvas.gray(0.4, in: rep)
    #expect(matches(try canvas.pixel(rep, x: 60, fromTop: sublayerRow), blended("plusL", light, over: background)))
    let dark = try Canvas.gray(0.1, in: rep)
    #expect(matches(try canvas.pixel(rep, x: 60, fromTop: layerRow), blended("plusL", dark, over: background)))
  }

  @Test func aPlusLayerInAnOffsetAncestorDrawsAtItsPositionInTheView() throws {
    let canvas = Canvas(dark: true)
    let container = CALayer()
    container.frame = CGRect(x: 50, y: 0, width: 70, height: 60)
    container.addSublayer(plus("plusL", CGRect(x: 10, y: 15, width: 20, height: 30), white: 0.3))
    canvas.root.addSublayer(container)

    let rep = try canvas.cache()

    let background = try canvas.background(in: rep)
    let expected = blended("plusL", try Canvas.gray(0.3, in: rep), over: background)
    #expect(matches(try canvas.pixel(rep, x: 70, fromTop: 30), expected))
    #expect(matches(try canvas.pixel(rep, x: 20, fromTop: 30), background))
  }

  enum Invisible: String, CaseIterable, Sendable {
    case transparent, hidden
  }

  @Test(arguments: Invisible.allCases) func aPlusLayerUnderAnInvisibleAncestorDrawsNothing(_ way: Invisible) throws {
    let canvas = Canvas(dark: true)
    let ancestor = CALayer()
    ancestor.frame = canvas.view.bounds
    switch way {
    case .transparent: ancestor.opacity = 0
    case .hidden: ancestor.isHidden = true
    }
    let middle = CALayer()
    middle.frame = ancestor.bounds
    middle.addSublayer(plus("plusL", Self.strip, white: 0.5))
    ancestor.addSublayer(middle)
    canvas.root.addSublayer(ancestor)

    let rep = try canvas.cache()

    #expect(matches(try canvas.pixel(rep, x: 60, fromTop: 30), try canvas.background(in: rep)))
  }

  /// An ancestor at half opacity adds half of the layer's color.
  @Test func aPlusLayerUnderAHalfTransparentAncestorAddsHalfItsColor() throws {
    let canvas = Canvas(dark: true)
    let ancestor = CALayer()
    ancestor.frame = canvas.view.bounds
    ancestor.opacity = 0.5
    ancestor.addSublayer(plus("plusL", Self.strip, white: 0.4))
    canvas.root.addSublayer(ancestor)

    let rep = try canvas.cache()

    let half = try Canvas.gray(0.4, in: rep).map { $0 / 2 }
    #expect(
      matches(try canvas.pixel(rep, x: 60, fromTop: 30), blended("plusL", half, over: try canvas.background(in: rep))))
  }

  /// A scroll view 40 points wide shows the left part of a document whose plus layer spans its width.
  fileprivate func scrolledCanvas() -> Canvas {
    let canvas = Canvas(dark: true)
    let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 40, height: 60))
    scroll.drawsBackground = false
    let document = NSView(frame: CGRect(x: 0, y: 0, width: 120, height: 60))
    document.wantsLayer = true
    document.layer?.addSublayer(plus("plusL", CGRect(x: 0, y: 15, width: 120, height: 30), white: 0.3))
    scroll.documentView = document
    canvas.view.addSubview(scroll)
    // AppKit puts the document's layer under the clip view's layer when the window displays, as the app's window has.
    canvas.window.displayIfNeeded()
    return canvas
  }

  @Test func aPlusLayerInAScrollViewBlendsWhereTheScrollViewShowsIt() throws {
    let canvas = scrolledCanvas()

    let rep = try canvas.cache()

    let expected = blended("plusL", try Canvas.gray(0.3, in: rep), over: try canvas.background(in: rep))
    #expect(matches(try canvas.pixel(rep, x: 20, fromTop: 30), expected))
  }

  /// Content outside a scroll view's safe area scrolls under an inset bar, so the drawing leaves it out.
  @Test func aPlusLayerOutsideAScrollViewsSafeAreaDrawsNothing() throws {
    let canvas = Canvas(dark: true)
    let scroll = NSScrollView(frame: canvas.view.bounds)
    scroll.drawsBackground = false
    scroll.automaticallyAdjustsContentInsets = false
    scroll.additionalSafeAreaInsets = NSEdgeInsets(top: 0, left: 40, bottom: 0, right: 0)
    let document = NSView(frame: canvas.view.bounds)
    document.wantsLayer = true
    document.layer?.addSublayer(plus("plusL", CGRect(x: 10, y: 20, width: 20, height: 20), white: 0.3))
    scroll.documentView = document
    canvas.view.addSubview(scroll)
    canvas.window.displayIfNeeded()

    let rep = try canvas.cache()

    #expect(matches(try canvas.pixel(rep, x: 20, fromTop: 30), try canvas.background(in: rep)))
  }

  @Test func aPlusLayerInAScrollViewDrawsNothingPastTheScrollView() throws {
    let canvas = scrolledCanvas()

    let rep = try canvas.cache()

    #expect(matches(try canvas.pixel(rep, x: 80, fromTop: 30), try canvas.background(in: rep)))
  }

  /// Each way an ancestor changes a layer that rendering it alone and clipping it to rects can't reproduce.
  enum AncestorChange: String, CaseIterable, Sendable {
    case mask, roundedClip, scale, sublayerTransform, filter
  }

  /// `cacheDisplay` draws a plus layer whose ancestor it can't reproduce as a plain layer.
  @Test(arguments: AncestorChange.allCases) func aPlusLayerUnderAnAncestorItCantReproduceDrawsPlain(
    _ change: AncestorChange
  ) throws {
    let canvas = Canvas(dark: true)
    let ancestor = CALayer()
    ancestor.frame = canvas.view.bounds
    switch change {
    case .mask: ancestor.mask = solid(ancestor.bounds, white: 1)
    case .roundedClip:
      ancestor.masksToBounds = true
      ancestor.cornerRadius = 4
    case .scale: ancestor.transform = CATransform3DMakeScale(1, 1.01, 1)
    case .sublayerTransform: ancestor.sublayerTransform = CATransform3DMakeScale(1, 1.01, 1)
    case .filter: ancestor.filters = [SnapshotVibrancy.filter("colorMatrix", SnapshotVibrancy.identity)]
    }
    ancestor.addSublayer(plus("plusL", Self.strip, white: 0.3))
    canvas.root.addSublayer(ancestor)

    let rep = try canvas.cache()

    #expect(matches(try canvas.pixel(rep, x: 60, fromTop: 30), try Canvas.gray(0.3, in: rep)))
  }

  /// A mask that leaves the plus layer out keeps it out of the drawing.
  @Test func aPlusLayerThatAnAncestorsMaskLeavesOutDrawsNothing() throws {
    let canvas = Canvas(dark: true)
    let ancestor = CALayer()
    ancestor.frame = canvas.view.bounds
    ancestor.mask = solid(CGRect(x: 0, y: 0, width: 20, height: 60), white: 1)
    ancestor.addSublayer(plus("plusL", Self.strip, white: 0.3))
    canvas.root.addSublayer(ancestor)

    let rep = try canvas.cache()

    #expect(matches(try canvas.pixel(rep, x: 60, fromTop: 30), try canvas.background(in: rep)))
  }

  @Test func anOpaqueLayerDrawnAfterAPlusLayerCoversIt() throws {
    let canvas = Canvas(dark: true)
    canvas.root.addSublayer(plus("plusL", Self.strip, white: 0.3))
    canvas.root.addSublayer(solid(Self.strip, white: 0))

    let rep = try canvas.cache()

    #expect(matches(try canvas.pixel(rep, x: 60, fromTop: 30), [0, 0, 0]))
  }

  @Test func aCoveringLayerUnderAnAncestorsLaterSiblingCoversAPlusLayer() throws {
    let canvas = Canvas(dark: true)
    let group = CALayer()
    group.frame = canvas.view.bounds
    group.addSublayer(plus("plusL", Self.strip, white: 0.3))
    let later = CALayer()
    later.frame = canvas.view.bounds
    later.addSublayer(solid(Self.strip, white: 0))
    canvas.root.addSublayer(group)
    canvas.root.addSublayer(later)

    let rep = try canvas.cache()

    #expect(matches(try canvas.pixel(rep, x: 60, fromTop: 30), [0, 0, 0]))
  }

  /// A later layer that draws elsewhere leaves the plus layer blending.
  @Test func aLaterLayerElsewhereLeavesAPlusLayerBlending() throws {
    let canvas = Canvas(dark: true)
    canvas.root.addSublayer(plus("plusL", Self.strip, white: 0.3))
    canvas.root.addSublayer(solid(CGRect(x: 0, y: 0, width: 20, height: 20), white: 0))

    let rep = try canvas.cache()

    let expected = blended("plusL", try Canvas.gray(0.3, in: rep), over: try canvas.background(in: rep))
    #expect(matches(try canvas.pixel(rep, x: 60, fromTop: 30), expected))
  }

  /// Core Animation draws siblings in order of `zPosition`, so array order no longer says what draws last.
  @Test func aPlusLayerAmongSiblingsWithMixedZPositionsDrawsPlain() throws {
    let canvas = Canvas(dark: true)
    let blend = plus("plusL", Self.strip, white: 0.3)
    let raised = solid(CGRect(x: 0, y: 0, width: 20, height: 20), white: 0)
    raised.zPosition = 1
    canvas.root.addSublayer(raised)
    canvas.root.addSublayer(blend)

    let rep = try canvas.cache()

    #expect(matches(try canvas.pixel(rep, x: 60, fromTop: 30), try Canvas.gray(0.3, in: rep)))
  }

  /// The plus layer spans x 20…100 inside an ancestor that spans x 40…80 and masks to its bounds.
  private func clippedCanvas() -> Canvas {
    let canvas = Canvas(dark: true)
    let clip = CALayer()
    clip.frame = CGRect(x: 40, y: 0, width: 40, height: 60)
    clip.masksToBounds = true
    clip.addSublayer(plus("plusL", CGRect(x: -20, y: 15, width: 80, height: 30), white: 0.3))
    canvas.root.addSublayer(clip)
    return canvas
  }

  @Test func aPlusLayerOutsideAnAncestorThatMasksToBoundsDrawsNothing() throws {
    let canvas = clippedCanvas()

    let rep = try canvas.cache()

    #expect(matches(try canvas.pixel(rep, x: 30, fromTop: 30), try canvas.background(in: rep)))
  }

  @Test func aPlusLayerInsideAnAncestorThatMasksToBoundsBlends() throws {
    let canvas = clippedCanvas()

    let rep = try canvas.cache()

    let expected = blended("plusL", try Canvas.gray(0.3, in: rep), over: try canvas.background(in: rep))
    #expect(matches(try canvas.pixel(rep, x: 60, fromTop: 30), expected))
  }
}

/// A segmented control's selected segment: an opaque white pill, the selected label on it, and a group that holds
/// the unselected labels' gray and a `destOut` layer that knocks the group out over the pill. The window shows the
/// pill and the black label.
@MainActor
private struct Segment {
  let canvas: Canvas
  let group: CALayer
  let knockout: CALayer

  init(dark: Bool) {
    canvas = Canvas(dark: dark)
    let superlayer = CALayer()
    superlayer.frame = canvas.view.bounds
    superlayer.addSublayer(solid(CGRect(x: 10, y: 15, width: 100, height: 30), white: 1))
    let label = solid(CGRect(x: 55, y: 25, width: 10, height: 10), white: 0)
    superlayer.addSublayer(label)
    group = CALayer()
    group.frame = superlayer.bounds
    group.addSublayer(solid(label.frame, white: 0.5))
    knockout = CALayer()
    knockout.frame = group.bounds
    knockout.compositingFilter = "destOut"
    knockout.addSublayer(solid(CGRect(x: 10, y: 15, width: 100, height: 30), white: 0))
    group.addSublayer(knockout)
    superlayer.addSublayer(group)
    canvas.root.addSublayer(superlayer)
  }
}

@MainActor
@Suite struct SnapshotBlendKnockoutCacheTests {
  @Test(arguments: [false, true]) func theSelectedLabelShowsThroughTheKnockout(dark: Bool) throws {
    let segment = Segment(dark: dark)

    let rep = try segment.canvas.cache()

    #expect(matches(try segment.canvas.pixel(rep, x: 60, fromTop: 30), [0, 0, 0]))
  }

  @Test(arguments: [false, true]) func thePillShowsThroughTheKnockout(dark: Bool) throws {
    let segment = Segment(dark: dark)

    let rep = try segment.canvas.cache()

    #expect(matches(try segment.canvas.pixel(rep, x: 25, fromTop: 30), try Canvas.gray(1, in: rep)))
  }

  /// The group's copy of the label blends in the window, and the knockout erases it under the pill.
  @Test(arguments: [false, true]) func aPlusLabelUnderTheKnockoutAddsNothingToTheSelectedLabel(dark: Bool) throws {
    let segment = Segment(dark: dark)
    segment.group.sublayers?.first?.compositingFilter = dark ? "plusL" : "plusD"

    let rep = try segment.canvas.cache()

    #expect(matches(try segment.canvas.pixel(rep, x: 60, fromTop: 30), [0, 0, 0]))
  }

  @Test func cacheLeavesTheLayersAsItFoundThem() throws {
    let segment = Segment(dark: true)
    let blend = plus("plusL", CGRect(x: 10, y: 50, width: 20, height: 5), white: 0.3)
    blend.opacity = 0.6
    segment.canvas.root.addSublayer(blend)

    _ = try segment.canvas.cache()

    #expect(!segment.knockout.isHidden)
    #expect(segment.group.mask == nil)
    #expect(blend.opacity == 0.6)
    #expect(blend.compositingFilter as? String == "plusL")
  }
}

@MainActor
@Suite struct SnapshotBlendKnockoutTests {
  /// A 100×40 superlayer whose `destOut` sublayer, at `offset`, holds `shapes`.
  struct Tree {
    let root = CALayer()
    let parent = CALayer()
    let knockout = CALayer()

    init(offset: CGPoint = .zero, _ shapes: [CALayer]) {
      parent.frame = CGRect(x: 0, y: 0, width: 100, height: 40)
      knockout.frame = CGRect(origin: offset, size: CGSize(width: 100, height: 40))
      knockout.compositingFilter = "destOut"
      for shape in shapes { knockout.addSublayer(shape) }
      parent.addSublayer(solid(parent.bounds, white: 0.5))
      parent.addSublayer(knockout)
      root.addSublayer(parent)
    }

    /// Whether the mask lets `point`, in the superlayer's coordinates, show. No mask lets everything show.
    func shows(_ point: CGPoint) throws -> Bool {
      guard parent.mask != nil else { return true }
      let mask = try #require(parent.mask as? CAShapeLayer)
      let rule: CGPathFillRule = mask.fillRule == .evenOdd ? .evenOdd : .winding
      return try #require(mask.path).contains(point, using: rule)
    }
  }

  static let rect = CGRect(x: 20, y: 10, width: 40, height: 20)

  static func image() throws -> CGImage {
    let context = try #require(
      CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return try #require(context.makeImage())
  }

  @Test func hidesTheKnockoutLayer() {
    let tree = Tree([solid(Self.rect, white: 0)])

    _ = Snapshot.applyKnockouts(tree.root)

    #expect(tree.knockout.isHidden)
  }

  @Test func leavesOutEveryOpaqueRect() throws {
    let tree = Tree([
      solid(CGRect(x: 5, y: 5, width: 20, height: 20), white: 0),
      solid(CGRect(x: 60, y: 5, width: 20, height: 20), white: 0),
    ])

    _ = Snapshot.applyKnockouts(tree.root)

    #expect(tree.parent.mask != nil)
    #expect(try !tree.shows(CGPoint(x: 15, y: 15)))
    #expect(try !tree.shows(CGPoint(x: 70, y: 15)))
    #expect(try tree.shows(CGPoint(x: 42, y: 15)))
  }

  @Test func aRoundedCornerOutsideTheRadiusStaysInTheMask() throws {
    let shape = solid(Self.rect, white: 0)
    shape.cornerRadius = 10
    let tree = Tree([shape])

    _ = Snapshot.applyKnockouts(tree.root)

    #expect(tree.parent.mask != nil)
    #expect(try tree.shows(CGPoint(x: 20.5, y: 10.5)))
    #expect(try !tree.shows(CGPoint(x: 40, y: 20)))
  }

  /// A corner that `maskedCorners` leaves out stays square in the window, so the knockout covers it.
  @Test func aSquareCornerOfAPartlyRoundedShapeIsNotLeftInTheMask() throws {
    let shape = solid(Self.rect, white: 0)
    shape.cornerRadius = 10
    shape.maskedCorners = [.layerMaxXMaxYCorner]
    let tree = Tree([shape])

    _ = Snapshot.applyKnockouts(tree.root)

    let refused = tree.parent.mask == nil
    #expect(try refused || !tree.shows(CGPoint(x: 20.5, y: 10.5)))
  }

  @Test func convertsTheRectsOfAnOffsetKnockoutLayerToTheSuperlayer() throws {
    let tree = Tree(offset: CGPoint(x: 30, y: 5), [solid(CGRect(x: 10, y: 5, width: 20, height: 20), white: 0)])

    _ = Snapshot.applyKnockouts(tree.root)

    #expect(tree.parent.mask != nil)
    #expect(try !tree.shows(CGPoint(x: 50, y: 20)))
    #expect(try tree.shows(CGPoint(x: 15, y: 10)))
  }

  @Test func findsAKnockoutLayerDeepInTheTree() throws {
    let tree = Tree([solid(Self.rect, white: 0)])
    let top = CALayer()
    let middle = CALayer()
    top.addSublayer(middle)
    middle.addSublayer(tree.root)

    _ = Snapshot.applyKnockouts(top)

    #expect(try !tree.shows(CGPoint(x: 40, y: 20)))
  }

  @Test(arguments: [nil, "plusL", "plusD", "destIn"])
  func leavesLayersWithoutTheDestOutFilterAlone(_ filter: String?) {
    let tree = Tree([solid(Self.rect, white: 0)])
    tree.knockout.compositingFilter = filter

    _ = Snapshot.applyKnockouts(tree.root)

    #expect(tree.parent.mask == nil)
    #expect(!tree.knockout.isHidden)
  }

  @Test func restoringPutsBackEveryKnockout() {
    let first = Tree([solid(Self.rect, white: 0)])
    let second = Tree([solid(Self.rect, white: 0)])
    let root = CALayer()
    root.addSublayer(first.root)
    root.addSublayer(second.root)
    let restore = Snapshot.applyKnockouts(root)

    restore()

    #expect([first, second].allSatisfy { $0.parent.mask == nil && !$0.knockout.isHidden })
  }

  @Test func restoringKeepsAKnockoutLayerThatWasHiddenHidden() {
    let tree = Tree([solid(Self.rect, white: 0)])
    tree.knockout.isHidden = true
    let restore = Snapshot.applyKnockouts(tree.root)

    restore()

    #expect(tree.knockout.isHidden)
  }

  /// A hidden knockout layer erases nothing in the window.
  @Test func aHiddenKnockoutLayerLeavesNothingOutOfTheMask() throws {
    let tree = Tree([solid(Self.rect, white: 0)])
    tree.knockout.isHidden = true

    _ = Snapshot.applyKnockouts(tree.root)

    #expect(try tree.shows(CGPoint(x: 40, y: 20)))
  }

  /// A hidden shape erases nothing in the window.
  @Test func aHiddenShapeIsNotLeftOutOfTheMask() throws {
    let hidden = solid(Self.rect, white: 0)
    hidden.isHidden = true
    let tree = Tree([hidden])

    _ = Snapshot.applyKnockouts(tree.root)

    #expect(try tree.shows(CGPoint(x: 40, y: 20)))
  }

  /// A square turned 45° about (50, 20) covers less than its bounding box, x 21.7…78.3. The point (25, 2) is inside
  /// the box but outside the turned square, so it still shows.
  @Test func aTransformedShapeLeavesOutNoMoreThanItCovers() throws {
    let shape = solid(CGRect(x: 30, y: 0, width: 40, height: 40), white: 0)
    shape.transform = CATransform3DMakeRotation(.pi / 4, 0, 0, 1)
    let tree = Tree([shape])

    _ = Snapshot.applyKnockouts(tree.root)

    #expect(try tree.shows(CGPoint(x: 25, y: 2)))
  }

  /// Each way the mask can't stand for the knockout. The superlayer keeps the mask it had, if any.
  enum Refusal: String, CaseIterable, Sendable {
    case superlayerHasAMask
    case knockoutHasContents
    case shapeHasContents
    case nestedShapeHasContents
    case shapeIsTranslucent
    case shapeIsPartlyTransparent
    case knockoutIsPartlyTransparent
    case shapeHasAMask
    case shapeHasABorder
    case shapeHasAShadow
    case knockoutIsTransformed
    case shapeIsAShapeLayer
    case shapeHasAFilter
    case aSiblingDrawsAfterTheKnockout
    case anEarlierSiblingHasAHigherZPosition
    case shapeHasACompositingFilter
    case shapeHasABackgroundFilter
    case knockoutHasASublayerTransform
    case shapeSpillsOutOfAMaskingKnockout
  }

  static func refusedTree(_ refusal: Refusal) throws -> Tree {
    let shape = solid(Self.rect, white: 0)
    let tree = Tree([shape])
    switch refusal {
    case .superlayerHasAMask: tree.parent.mask = solid(tree.parent.bounds, white: 1)
    case .knockoutHasContents: tree.knockout.contents = try image()
    case .shapeHasContents: shape.contents = try image()
    case .nestedShapeHasContents:
      let nested = solid(CGRect(x: 0, y: 0, width: 10, height: 10), white: 0)
      nested.contents = try image()
      shape.addSublayer(nested)
    case .shapeIsTranslucent: shape.backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5)
    case .shapeIsPartlyTransparent: shape.opacity = 0.5
    case .knockoutIsPartlyTransparent: tree.knockout.opacity = 0.5
    case .shapeHasAMask: shape.mask = solid(shape.bounds, white: 1)
    case .shapeHasABorder: shape.borderWidth = 1
    case .shapeHasAShadow: shape.shadowOpacity = 0.5
    case .knockoutIsTransformed: tree.knockout.transform = CATransform3DMakeScale(0.5, 0.5, 1)
    case .shapeIsAShapeLayer:
      let drawn = CAShapeLayer()
      drawn.frame = Self.rect
      drawn.path = CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil)
      tree.knockout.addSublayer(drawn)
    case .shapeHasAFilter: shape.filters = [SnapshotVibrancy.filter("colorMatrix", SnapshotVibrancy.identity)]
    case .aSiblingDrawsAfterTheKnockout: tree.parent.addSublayer(solid(tree.parent.bounds, white: 0.2))
    case .anEarlierSiblingHasAHigherZPosition: tree.parent.sublayers?.first?.zPosition = 1
    case .shapeHasACompositingFilter: shape.compositingFilter = "plusL"
    case .shapeHasABackgroundFilter:
      shape.backgroundFilters = [SnapshotVibrancy.filter("colorMatrix", SnapshotVibrancy.identity)]
    case .knockoutHasASublayerTransform: tree.knockout.sublayerTransform = CATransform3DMakeScale(0.5, 0.5, 1)
    case .shapeSpillsOutOfAMaskingKnockout:
      tree.knockout.masksToBounds = true
      shape.frame = CGRect(x: 80, y: 10, width: 40, height: 20)
    }
    return tree
  }

  /// Two shapes that overlap erase their overlap too.
  @Test func overlappingShapesBothEraseTheirOverlap() throws {
    let tree = Tree([solid(Self.rect, white: 0), solid(Self.rect, white: 0)])

    _ = Snapshot.applyKnockouts(tree.root)

    #expect(tree.parent.mask != nil)
    #expect(try !tree.shows(CGPoint(x: 40, y: 20)))
  }

  @Test func aKnockoutWhoseBackgroundOverlapsItsShapeErasesBoth() throws {
    let tree = Tree([solid(Self.rect, white: 0)])
    tree.knockout.backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    _ = Snapshot.applyKnockouts(tree.root)

    #expect(tree.parent.mask != nil)
    #expect(try !tree.shows(CGPoint(x: 40, y: 20)))
    #expect(try !tree.shows(CGPoint(x: 80, y: 20)))
  }

  /// A hidden sibling draws nothing, so it does not matter where it sits.
  @Test func aHiddenSiblingAfterTheKnockoutStillLetsTheMaskStandForIt() throws {
    let tree = Tree([solid(Self.rect, white: 0)])
    let sibling = solid(tree.parent.bounds, white: 0.2)
    sibling.isHidden = true
    tree.parent.addSublayer(sibling)

    _ = Snapshot.applyKnockouts(tree.root)

    #expect(try !tree.shows(CGPoint(x: 40, y: 20)))
  }

  @Test(arguments: Refusal.allCases) func refusingChangesNothing(_ refusal: Refusal) throws {
    let tree = try Self.refusedTree(refusal)
    let mask = tree.parent.mask

    _ = Snapshot.applyKnockouts(tree.root)

    #expect(tree.parent.mask === mask)
    #expect(!tree.knockout.isHidden)
  }
}
