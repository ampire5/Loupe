import AppKit
import LoupeCore

// `Loupe --print-input-conf`: the input.conf template (every built-in binding, commented) on stdout, before any window;
// the installer makes the user's ~/.config/loupe/input.conf from it.
if CommandLine.arguments.dropFirst().contains("--print-input-conf") {
    print(InputConfTemplate.text, terminator: InputConfTemplate.text.hasSuffix("\n") ? "" : "\n")
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
