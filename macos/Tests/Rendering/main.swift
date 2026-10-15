import AppKit

_ = NSApplication.shared
for (word, ordinal, width, height) in [("原厂", "1", 70.0, 24.0), ("撒点发送", "1", 110.0, 24.0),
                                      ("爱", "", 60.0, 28.0), ("sa", "3", 50.0, 24.0)] {
    let cell = CandidateCell(frame: NSRect(x: 0, y: 0, width: width, height: height))
    cell.word = word
    cell.ordinal = ordinal
    cell.isCurrentCandidate = true
    cell.isBordered = false
    let bitmap = cell.bitmapImageRepForCachingDisplay(in: cell.bounds)!
    cell.cacheDisplay(in: cell.bounds, to: bitmap)
    var white: [NSPoint] = [], blue: [NSPoint] = []
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.9 else { continue }
            if color.redComponent > 0.9 && color.greenComponent > 0.9 && color.blueComponent > 0.9 {
                white.append(NSPoint(x: x, y: y))
            } else if color.blueComponent > 0.8 && color.redComponent < 0.2 {
                blue.append(NSPoint(x: x, y: y))
            }
        }
    }
    guard !white.isEmpty, !blue.isEmpty else { fatalError("Candidate did not render: \(word)") }
    func center(_ points: [NSPoint], _ path: KeyPath<NSPoint, CGFloat>) -> CGFloat {
        (points.map { $0[keyPath: path] }.min()! + points.map { $0[keyPath: path] }.max()!) / 2
    }
    let scale = CGFloat(bitmap.pixelsWide) / width
    let dy = abs(center(white, \.y) - center(blue, \.y)) / scale
    let dx = abs(center(white, \.x) - center(blue, \.x)) / scale
    guard dy <= 1, dx <= 1.5 else { fatalError("Candidate ink not centred: \(word), dx=\(dx), dy=\(dy)") }
    print("PASS centred candidate \(ordinal) \(word): dx=\(dx), dy=\(dy)")
}

final class RenderEngine: EngineConnection {
    var onFailure: (() -> Void)?
    var latest: ((String) -> Void)?
    func send(_ command: String, reply: @escaping (String) -> Void) {
        if command.hasPrefix("B ") { latest = reply }
    }
    func stop() {}
    func answer() { latest?("CAND\t" + (0..<52).map { "2:候选\($0)" }.joined(separator: "\t")) }
}
let engine = RenderEngine()
let model = Composition(engine: engine)
let panel = CandidatePanel()
// Exercise real NSPanel visibility and geometry without putting a test popup on
// the user's screen or taking keyboard focus away from their current app.
panel.alphaValue = 0
let bounds = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
let caret = NSRect(x: bounds.midX, y: bounds.maxY - 100, width: 1, height: 20)
model.onUpdate = { panel.show(composition: model, caret: caret) }
model.handle(.text("ni")); engine.answer()
guard panel.isVisible else { fatalError("Candidate window was not shown") }
let windowNumber = panel.windowNumber
let compactTop = panel.frame.maxY
let compactHeight = panel.frame.height
for key in "hcvsgo" {
    model.handle(.text(String(key)))
    guard panel.isVisible, panel.windowNumber == windowNumber else { fatalError("Candidate window flickered while waiting for the engine") }
    engine.answer()
    guard panel.isVisible, panel.windowNumber == windowNumber else { fatalError("Candidate window was replaced after an engine response") }
}
model.handle(.arrow(0, 1))
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
let cells = panel.candidateContentView.subviews.compactMap { $0 as? CandidateCell }.filter { !$0.isHidden }
guard panel.isVisible, panel.windowNumber == windowNumber, panel.frame.height > compactHeight,
      abs(panel.frame.maxY - compactTop) <= 0.5, cells.count == 29 else {
    fatalError("Expanding must reuse the window, anchor its top and reveal 29 candidates")
}
for row in 0..<4 {
    let rowCells = Array(cells[(5 + row * 6)..<(11 + row * 6)])
    guard rowCells.allSatisfy({ abs($0.frame.midY - rowCells[0].frame.midY) < 0.1 }) else {
        fatalError("Expanded candidate row is misaligned")
    }
}
guard cells.prefix(5).map(\.ordinal) == ["1", "2", "3", "4", "5"],
      cells.dropFirst(5).allSatisfy({ $0.ordinal.isEmpty }) else {
    fatalError("Initial numbering must appear only on the highlighted top row")
}
model.handle(.arrow(0, 1))
guard cells.prefix(5).allSatisfy({ $0.ordinal.isEmpty }),
      cells[5..<11].map(\.ordinal) == ["1", "2", "3", "4", "5", "6"],
      cells.dropFirst(11).allSatisfy({ $0.ordinal.isEmpty }) else {
    fatalError("Rendered labels must follow the highlighted second row")
}
model.handle(.arrow(0, -1))
guard cells.prefix(5).map(\.ordinal) == ["1", "2", "3", "4", "5"],
      cells.dropFirst(5).allSatisfy({ $0.ordinal.isEmpty }), panel.windowNumber == windowNumber else {
    fatalError("Returning to the first row must move the labels back without replacing the window")
}
if #available(macOS 26.0, *) {
    guard let glass = panel.contentView as? NSGlassEffectView,
          glass.contentView === panel.candidateContentView, glass.tintColor == nil,
          panel.candidateContentView.frame.size == glass.bounds.size else {
        fatalError("Native glass must contain the candidate controls without a fixed colour tint")
    }
}
model.handle(.escape)
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
guard panel.frame.height == compactHeight, panel.isVisible else { fatalError("Collapse must return to the compact window") }
model.handle(.escape)
guard !panel.isVisible else { fatalError("Cancel must dismiss the candidate window") }
print("PASS persistent window, anchored expansion, aligned rows, moving number labels, native glass, collapse and dismissal")
