import Foundation
import HomeScreenModel
import Testing
@testable import LoupeCore

@Test func videoCardUsesTheStreamDimensionsAndFormat() async throws {
    let clip = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/blue-720p.mp4")
    let fileSize = try #require(clip.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let (jpeg, info) = try await PlaybackMedia.videoThumbnail(clip, maximumSide: 160, fileSize: fileSize)
    let poster = try #require(ThumbnailMaker.decodeImage(jpeg))
    #expect(poster.width == 160)
    #expect(poster.height == 90)
    #expect(info.pixelSize == PixelSize(width: 1280, height: 720))
    let facts = try #require(info.browserFacts)
    #expect(facts.duration == 0.08)
    #expect(FileFactsText.stream(facts) == "HD · 25p · H.264")
    #expect(FileFactsText.badges(facts, format: "MP4").map(\.text) == ["HD", "25p"])
}

@Test func localPlaybackMediaStaysInTheFolderPlaylist() {
    let folder = URL(fileURLWithPath: "/tmp/media", isDirectory: true)
    let photo = folder.appendingPathComponent("item1.jpg")
    let video = folder.appendingPathComponent("item2.MOV")
    let animation = folder.appendingPathComponent("item3.gif")
    let nonMedia = folder.appendingPathComponent("item4.txt")
    let playlist = Playlist(files: [nonMedia, animation, video, photo], current: photo)
    #expect(playlist.files == [photo, video, animation])
    #expect(PlaybackMedia.candidate(video) == .video)
    #expect(PlaybackMedia.candidate(animation) == .animation)
    #expect(PlaybackMedia.candidate(photo) == nil)
    #expect(PlaybackMedia.candidate(URL(string: "https://example.invalid/item.mov")!) == nil)
}

@Test func frameScrubHandoffUsesPresentedTimeAndPausedLanding() throws {
    let file = URL(fileURLWithPath: "/tmp/movie #1 & clips.mov")
    let url = try #require(PlaybackMedia.frameScrubLink(for: file, presentedTime: 12.375))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = try #require(components.queryItems)
    #expect(components.scheme == "framescrub")
    #expect(components.host == "open")
    #expect(items == [.init(name: "path", value: file.path),
                      .init(name: "t", value: "12.375"), .init(name: "paused", value: "1")])
    let fallback = try #require(PlaybackMedia.frameScrubLink(for: file, presentedTime: -.infinity))
    #expect(URLComponents(url: fallback, resolvingAgainstBaseURL: false)?.queryItems?
        .first(where: { $0.name == "t" })?.value == "0.0")
}

@Test func staticWebPStaysAPhotoWhileGIFAndWebPAnimationsHavePosters() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }

    // Tiny generated fixtures with two or three frames, and a still WebP with the same first picture.
    let still = "UklGRiIAAABXRUJQVlA4TBUAAAAvA0AAEA8Q8x/zHwyFAAKgoInofzwA"
    let gif = "R0lGODlhBAACAPAAAAAAAP8AACH/C05FVFNDQVBFMi4wAwEAAAAh+QQFBwAAACwAAAAABAACAAACBEwAhgUAIfkECQ0AAAAsAgAAAAIAAgCAAAAAAAD/AgIMXAAh+QQFFAAAACwAAAAAAgACAIAAAAAA/wACAgxcADs="
    let webp = "UklGRroAAABXRUJQVlA4WAoAAAASAAAAAwAAAQAAQU5JTQYAAAAAAAAAAwBBTk1GLgAAAAAAAAAAAAMAAAEAAEYAAABWUDhMFQAAAC8DQAAQDxDzH/MfDIUAAqCgieh/PABBTk1GKAAAAAEAAAAAAAEAAAEAAIIAAAFWUDhMEAAAAC8BQAAQDxAx//MfjIzofwBBTk1GKAAAAAAAAAAAAAEAAAEAAMgAAABWUDhMEAAAAC8BQAAQDzD/EfMfjIzofwA="
    for (name, bytes, animated) in [("still.webp", still, false), ("animated.gif", gif, true),
                                     ("animated.webp", webp, true)] {
        let url = folder.appendingPathComponent(name)
        let data = try #require(Data(base64Encoded: bytes))
        try data.write(to: url)
        let (isAnimated, poster) = PlaybackMedia.animationPoster(url, maximumSide: 16)
        #expect(isAnimated == animated, "Frame count for \(name)")
        #expect((poster != nil) == animated, "Poster for \(name)")
    }
}

@Test func videoKeepsItsOwnSpreadAndDoesNotEnterThePhotoCachePlan() {
    let folder = URL(fileURLWithPath: "/tmp/spread")
    let files = ["one.jpg", "two.mov", "three.jpg", "four.jpg"].map { folder.appendingPathComponent($0) }
    var spread = SpreadState()
    _ = spread.setViewSize(CGSize(width: 1280, height: 720))
    spread.update(files: files, index: 1, rules: { _ in
        SpreadRules(on: true, options: SpreadOptions(shift: false, rightToLeft: false, landscapeAlone: false))
    }, aspects: { _ in [] })
    #expect(spread.navigation.pair(at: 1) == SpreadPair(first: 1, second: nil))
    #expect(spread.navigation.target(from: 0, by: 1, count: files.count) == 1)
    #expect(spread.navigation.target(from: 1, by: 1, count: files.count) == 2)

    let focus = CacheFocus(count: files.count, current: 1, direction: 1, dwelling: true, needsFull: false,
                           screen: PixelSize(width: 1200, height: 800))
    let plan = CachePlan.make(focus: focus, limits: CacheLimits(config: Config()),
                              isExcluded: { PlaybackMedia.candidate(files[$0]) == .video }) { _ in EntryFacts() }
    #expect(!plan.isEmpty)
    #expect(plan.allSatisfy { $0.index != 1 })
}

@Test func largeGIFUsesOnlyTheFirstFrameForThePhotoCache() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("animation.gif")
    let gif = try #require(Data(base64Encoded: "R0lGODlhBAACAPAAAAAAAP8AACH/C05FVFNDQVBFMi4wAwEAAAAh+QQFBwAAACwAAAAABAACAAACBEwAhgUAIfkECQ0AAAAsAgAAAAIAAgCAAAAAAAD/AgIMXAAh+QQFFAAAACwAAAAAAgACAIAAAAAA/wACAgxcADs="))
    try gif.write(to: file)
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 1 << 30)
    try handle.close()

    let bytes = try await PlaybackMedia.readPosterBytes(file, reader: FileReader(isLocal: { _ in false }),
                                                       priority: ReadPriority(0))
    #expect(bytes.stamp.size == 1 << 30)
    #expect(bytes.data.count < gif.count)
    #expect(try ImageIODecoder.probe(bytes.data).pixelSize == PixelSize(width: 4, height: 2))
    let (animated, poster) = PlaybackMedia.animationPoster(file, maximumSide: 16)
    #expect(animated && poster?.width == 4)
}
