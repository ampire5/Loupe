import AppKit
import ImageIO
import UniformTypeIdentifiers
import LoupeCore
import LoupeRender
import Testing
@testable import Loupe

@Suite(.serialized) @MainActor struct SmartFramingNavigationTests {
    @Test func panOnlyNavigationRemembersTheImmediatelyPreviousCentre() async throws {
        try await checkNavigation(restored: false, startInAuto: false)
        try await checkNavigation(restored: true, startInAuto: false)
        try await checkNavigation(restored: false, startInAuto: true)
    }

    private func checkNavigation(restored: Bool, startInAuto: Bool) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try (0..<3).map { i -> URL in
            let folder = restored ? root.appendingPathComponent("folder-\(i)") : root
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("photo-\(i).png").standardizedFileURL
            let context = try #require(CGContext(data: nil, width: 1000, height: 1000, bitsPerComponent: 8, bytesPerRow: 4000,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(gray: 0.5, alpha: 1); context.fill(.init(x: 0, y: 0, width: 1000, height: 1000))
            let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, try #require(context.makeImage()), nil)
            #expect(CGImageDestinationFinalize(dest))
            return url
        }
        let reader = FileReader(threads: 1)
        let cache = ImageCache(loader: MetalPyramidLoader(), reader: reader, pool: DecodePool(), limits: CacheLimits(config: Config()))
        let thumbnails = ThumbnailStore(directory: nil, reader: reader, thumbSize: 320, limitBytes: 0)
        let session = ViewerSession(cache: cache, thumbnails: thumbnails, positions: FolderPositions(database: nil))
        defer { session.close() }
        var rules = ZoomRules(config: Config())
        rules.chain = [.object]; rules.keep = true; rules.pan = .keep; rules.subjectSize = 0.7
        rules.defaultMode = .actual(0.7); rules.composition.margin = 0; rules.composition.maxZoom = 4
        session.zoomRules = { _ in rules }
        session.subjectBoxes = { url in
            let i = files.firstIndex(of: url) ?? 0
            return .init(faces: [], people: [], objects: [.init(x: 0.4 + Double(i) * 0.001, y: 0.4, width: 0.2, height: 0.2)], saliency: [])
        }
        session.transform = .init(imageSize: .init(width: 1000, height: 1000), viewSize: .init(width: 400, height: 200), mode: .actual(0.7))
        session.screenSize = .init(width: 400, height: 200)
        session.smartZoom.select(startInAuto ? .frame : .pan)
        session.setActivity(active: true, visible: true, lastActive: 1)
        session.openPhotos(files, current: files[0])
        #expect(await wait { session.entry?.url == files[0] && session.entry?.info != nil })
        session.transform.center = .init(x: 0.52, y: 0.5)
        for i in 1...2 {
            if i == 2 && startInAuto { session.smartZoom.select(.pan) }
            if restored { session.open(files[i], view: SavedView(session.transform)) }
            else { #expect(session.go(by: 1)) }
            #expect(await wait { session.entry?.url == files[i] && session.entry?.info != nil })
            let expected = i == 1 ? 0.52 : 0.53
            #expect(abs(session.transform.clamped.center.x - expected) < 1e-8,
                    "restored=\(restored), auto→pan=\(startInAuto), photo=\(i)")
            session.transform.center = .init(x: 0.53, y: 0.5)
        }
        #expect(session.browse.sizes.isEmpty)
    }
    private func wait(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
