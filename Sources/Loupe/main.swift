import AppKit
import LoupeCore

#if DEBUG
if CommandLine.arguments.contains("--native-toolbar-bench")
    || Bundle.main.object(forInfoDictionaryKey: "LoupeNativeToolbarBench") as? Bool == true {
    MainActor.assumeIsolated {
        Task { @MainActor in await NativeToolbarBench.run() }
        NSApplication.shared.run()
    }
}
#endif

// `Loupe --print-input-conf`: the input.conf template (every built-in binding, commented) on stdout, before any window;
// the installer makes the user's ~/.config/loupe/input.conf from it.
if CommandLine.arguments.dropFirst().contains("--print-input-conf") {
    print(InputConfTemplate.text, terminator: InputConfTemplate.text.hasSuffix("\n") ? "" : "\n")
    exit(0)
}

if CommandLine.arguments.contains("--smartzoom-bench") {
    MainActor.assumeIsolated { SmartZoomBench.run() }
}

if CommandLine.arguments.contains("--folder-slots-bench") {
    MainActor.assumeIsolated { FolderSlotsBench.run() }
}

if let i = CommandLine.arguments.firstIndex(of: "--zoom-carry-bench"), CommandLine.arguments.count > i + 1 {
    let folder = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    MainActor.assumeIsolated {
        Task { @MainActor in await ZoomCarryBench.run(folder: folder) }
        NSApplication.shared.run()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
