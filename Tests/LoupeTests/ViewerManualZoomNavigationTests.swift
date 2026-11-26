import AppKit
import ImageIO
import LoupeCore
import LoupeRender
import Testing
import UniformTypeIdentifiers
@testable import Loupe

@Suite(.serialized) @MainActor struct ViewerManualZoomNavigationTests {
    @Test(arguments: [ZoomCarry.scale, .share, .screen])
    func automaticZoomOnSmallPhotoDoesNotReplaceReference(carry: ZoomCarry) async throws {
        try await withViewer(carry: carry) { session, files in
            session.noteManualZoom()
            session.transform = session.transform.withMode(.free(2))
            try await step(session, by: 1, to: files[1])
            let expected: Double = switch carry { case .scale: 0.4; case .share: 1; case .screen: 2 }
            #expect(abs(session.transform.scale - expected) < 1e-9)
            try await step(session, by: 1, to: files[2])
            #expect(abs(session.transform.scale - 0.4) < 1e-9)
        }
    }

    @Test func revisitRestoresItsOwnFramingInTheNewWindow() async throws {
        try await withViewer(carry: .scale) { session, files in
            session.noteManualZoom()
            session.transform = session.transform.withMode(.free(3))
            session.transform.center = CGPoint(x: 0.3, y: 0.65)
            try await step(session, by: 1, to: files[1])
            session.noteManualZoom()
            session.transform = session.transform.withMode(.actual(1.2))
            session.transform = session.transform.withViewSize(CGSize(width: 80, height: 120), carry: .scale)
            try await step(session, by: -1, to: files[0])
            #expect(session.transform.mode == .free(3))
            #expect(abs(session.transform.scale - 0.4) < 1e-9)
            #expect(session.transform.clamped.center == CGPoint(x: 0.3, y: 0.625))
        }
    }

    @Test func explicitlyZoomingTheSmallPhotoChangesTheReference() async throws {
        try await withViewer(carry: .share) { session, files in
            session.noteManualZoom()
            session.transform = session.transform.withMode(.free(2))
            try await step(session, by: 1, to: files[1])
            session.noteManualZoom()
            session.transform = session.transform.withMode(.free(1.5))
            try await step(session, by: 1, to: files[2])
            #expect(abs(session.transform.scale - 0.3) < 1e-9)
        }
    }

    @Test func keepZoomCanSuspendAndResumePhotoMemory() async throws {
        try await withViewer(carry: .scale) { session, files in
            session.noteManualZoom()
            session.transform = session.transform.withMode(.actual(1.2))
            try await step(session, by: 1, to: files[1])
            var config = Config()
            config.keepZoomAs = .scale
            config.keepZoomPosition = false
            session.zoomRules = { _ in ZoomRules(config: config) }
            session.rebaseManualZoom(keeping: false)
            try await step(session, by: -1, to: files[0])
            #expect(session.transform.mode == .fit)
            try await step(session, by: 1, to: files[1])
            session.noteManualZoom()
            session.transform = session.transform.withMode(.actual(0.8))
            config.keepZoomPosition = true
            session.rebaseManualZoom(keeping: true)
            try await step(session, by: 1, to: files[2])
            #expect(session.transform.mode == .actual(0.8))
            try await step(session, by: -2, to: files[0])
            #expect(session.transform.mode == .actual(1.2))
        }
    }

    @Test func folderChangeStartsANewReferenceAndKeepsTheOldPhotoFraming() async throws {
        try await withViewer(carry: .scale, anotherFolder: true) { session, files in
            session.noteManualZoom()
            session.transform = session.transform.withMode(.actual(1.2))
            try await step(session, by: 1, to: files[1])
            #expect(session.transform.mode == .fit)
            try await step(session, by: 1, to: files[2])
            #expect(session.transform.mode == .fit)
            try await step(session, by: -2, to: files[0])
            #expect(session.transform.mode == .actual(1.2))
        }
    }

    @Test func leavingForASmartZoomFolderStillRemembersTheManualFraming() async throws {
        try await withViewer(carry: .scale, anotherFolder: true) { session, files in
            session.noteManualZoom()
            session.transform = session.transform.withMode(.actual(1.2))
            try #require(session.go(by: 1))
            session.smartZoom.select(.frame)
            try await waitForPhoto(files[1], in: session)
            try #require(session.go(by: -1))
            session.smartZoom.select(.off)
            try await waitForPhoto(files[0], in: session)
            #expect(session.transform.mode == .actual(1.2))
        }
    }

    @Test func skippingAnUnshownPhotoDoesNotRememberItsFraming() async throws {
        try await withViewer(carry: .scale) { session, files in
            session.noteManualZoom()
            session.transform = session.transform.withMode(.actual(1.2))
            try #require(session.go(by: 1))
            try #require(session.go(by: 1))
            try await waitForPhoto(files[2], in: session)
            session.noteManualZoom()
            session.transform = session.transform.withMode(.actual(0.8))
            try await step(session, by: -1, to: files[1])
            #expect(session.transform.mode == .actual(0.8))
        }
    }

    @Test func reEnablingKeepZoomDuringLoadingUsesTheStillDisplayedPhoto() async throws {
        try await withViewer(carry: .share) { session, files in
            session.noteManualZoom()
            session.transform = session.transform.withMode(.free(2))
            try #require(session.go(by: 1))
            session.rebaseManualZoom(keeping: false)
            session.rebaseManualZoom(keeping: true)
            try await waitForPhoto(files[1], in: session)
            #expect(abs(session.transform.scale - 1) < 1e-9)
            try await step(session, by: 1, to: files[2])
            #expect(abs(session.transform.scale - 0.4) < 1e-9)
        }
    }

    private func withViewer(carry: ZoomCarry, anotherFolder: Bool = false,
                            run: (ViewerSession, [URL]) async throws -> Void) async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sizes = [PixelSize(width: 600, height: 400), PixelSize(width: 120, height: 80), PixelSize(width: 600, height: 400)]
        let files = try sizes.enumerated().map { index, size in
            let directory = anotherFolder && index > 0 ? folder.appendingPathComponent("second", isDirectory: true) : folder
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(index).png")
            let context = try #require(CGContext(data: nil, width: size.width, height: size.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(writer, try #require(context.makeImage()), nil)
            try #require(CGImageDestinationFinalize(writer))
            return url.standardizedFileURL
        }
        let reader = FileReader(threads: 1)
        let cache = ImageCache(loader: MetalPyramidLoader(), reader: reader, pool: DecodePool(), limits: CacheLimits(config: Config()))
        let thumbnails = ThumbnailStore(directory: nil, reader: reader, thumbSize: 120, limitBytes: 0)
        let session = ViewerSession(cache: cache, thumbnails: thumbnails, positions: FolderPositions(database: nil))
        defer { session.close() }
        var config = Config()
        config.keepZoomPosition = true
        config.keepZoomAs = carry
        config.stepPan = .keep
        session.zoomRules = { _ in ZoomRules(config: config) }
        session.spreadRules = { _ in SpreadRules(config: config) }
        session.transform = .init(imageSize: .zero, viewSize: CGSize(width: 120, height: 80))
        session.screenSize = .init(width: 120, height: 80)
        session.setActivity(active: true, visible: true, lastActive: 1)
        session.openPhotos(files, current: files[0])
        try await waitForPhoto(files[0], in: session)
        try await run(session, files)
    }

    private func step(_ session: ViewerSession, by delta: Int, to file: URL) async throws {
        try #require(session.go(by: delta))
        try await waitForPhoto(file, in: session)
    }

    private func waitForPhoto(_ file: URL, in session: ViewerSession) async throws {
        let timeout = ContinuousClock.now + .seconds(4)
        while session.entry?.url != file || session.entry?.info == nil {
            try #require(ContinuousClock.now < timeout, "Photo did not appear: \(file.lastPathComponent)")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
