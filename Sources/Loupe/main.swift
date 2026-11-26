import AppKit
import LoupeCore

if let path = Bundle.main.object(forInfoDictionaryKey: "LoupeLearningBenchDirectory") as? String {
    MainActor.assumeIsolated {
        Task { @MainActor in await FramingLearningBench.run(directory: URL(fileURLWithPath: path)) }
        NSApplication.shared.run()
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--framing-learning-bench"), CommandLine.arguments.count > i + 1 {
    let directory = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    MainActor.assumeIsolated {
        Task { @MainActor in await FramingLearningBench.run(directory: directory) }
        NSApplication.shared.run()
    }
}

#if DEBUG
if let index = CommandLine.arguments.firstIndex(of: "--photo-comparison-bench"),
   CommandLine.arguments.count > index + 2 {
    let first = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    let second = URL(fileURLWithPath: CommandLine.arguments[index + 2])
    MainActor.assumeIsolated {
        Task { @MainActor in await PhotoComparisonBench.run(first: first, second: second) }
        NSApplication.shared.run()
    }
}
if CommandLine.arguments.contains("--file-view-history-bench") {
    MainActor.assumeIsolated {
        Task { @MainActor in await FileViewHistoryBench.run() }
        NSApplication.shared.run()
    }
}
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

if CommandLine.arguments.contains("--photos-read-bench") {
    MainActor.assumeIsolated {
        Task { @MainActor in await PhotosReadBench.run() }
        NSApplication.shared.run()
    }
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

if let i = CommandLine.arguments.firstIndex(of: "--local-media-bench"), CommandLine.arguments.count > i + 2 {
    let root = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    let scenario = CommandLine.arguments[i + 2]
    MainActor.assumeIsolated {
        Task { @MainActor in await LocalMediaBench.run(root: root, scenario: scenario) }
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
