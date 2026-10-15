// Explicit command-line helper for manual/system integration testing.
// Not called by installation: choosing a keyboard remains a user action.
import AppKit
import Carbon

_ = NSApplication.shared
guard (2...3).contains(CommandLine.arguments.count) else { exit(2) }
let id = CommandLine.arguments[1]
if CommandLine.arguments.count == 3 {
    let url = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    guard TISRegisterInputSource(url as CFURL) == noErr else { exit(1) }
}
let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
guard let result = TISCreateInputSourceList(filter, true),
      let source = (result.takeRetainedValue() as! [TISInputSource]).first else {
    fputs("Input source is not available: \(id)\n", stderr)
    exit(1)
}
let status = TISSelectInputSource(source)
guard status == noErr else { fputs("Selection failed: \(status)\n", stderr); exit(1) }
print("Selected \(id)")
