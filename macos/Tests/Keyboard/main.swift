import AppKit

let model = Composition(engine: StubEngine())
final class StubEngine: EngineConnection {
    var onFailure: (() -> Void)?
    func send(_ command: String, reply: @escaping (String) -> Void) {}
    func stop() {}
}
func key(_ code: UInt16, _ text: String = "") -> InputKey? {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                timestamp: 0, windowNumber: 0, context: nil,
                                characters: text, charactersIgnoringModifiers: text,
                                isARepeat: false, keyCode: code)!
    return inputKey(for: event, composition: model)
}
for (code, expected) in [(UInt16(123), InputKey.arrow(-1, 0)), (124, .arrow(1, 0)),
                         (125, .arrow(0, 1)), (126, .arrow(0, -1)),
                         (116, .page(-1)), (121, .page(1))] {
    guard key(code) == expected else { fatalError("Key \(code) was routed incorrectly") }
}
model.handle(.text("ni"))
guard key(33, "[") == .page(-1), key(30, "]") == .page(1) else { fatalError("Bracket paging was not routed") }
print("PASS physical arrow keys navigate candidates; Page Up/Down and brackets page")
