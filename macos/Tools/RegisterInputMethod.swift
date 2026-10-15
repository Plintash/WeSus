import Foundation
import Carbon
import AppKit
import CoreServices

_ = NSApplication.shared

guard CommandLine.arguments.count == 2 else { exit(2) }
let url = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
// Replacing a bundle can leave Launch Services holding its former metadata.
// Update this app explicitly before rebuilding the text-input source cache.
let applicationRegistration = LSRegisterURL(url as CFURL, true)
guard applicationRegistration == noErr else {
    fputs("Application registration returned \(applicationRegistration).\n", stderr)
    exit(1)
}
let result = TISRegisterInputSource(url as CFURL)
guard result == noErr else {
    fputs("Input source registration returned \(result). Log out and back in if necessary.\n", stderr)
    exit(1)
}
let filter = [kTISPropertyBundleID as String: "io.github.plintash.inputmethod.wetype"] as CFDictionary
if let list = TISCreateInputSourceList(filter, true) {
    let sources = list.takeRetainedValue() as! [TISInputSource]
    print("Registered input sources: \(sources.count)")
    // Carbon requires the parent input method to be enabled before a mode.
    // Enabling only the mode succeeds, but selecting it then returns paramErr.
    for wanted in ["io.github.plintash.inputmethod.wetype", "io.github.plintash.inputmethod.wetype.flypy"] {
        for source in sources {
            guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
            guard id == wanted else { continue }
            let enabled = TISEnableInputSource(source)
            if enabled != noErr { fputs("Input source enable returned \(enabled).\n", stderr) }
        }
    }
    print("Enabled 巨疑输入法; current keyboard selection is unchanged.")
} else {
    print("Registration accepted; input-source discovery may require a new login session.")
}
// Adding this input source is part of installation. Never select it globally.
