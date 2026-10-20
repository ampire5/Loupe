import Foundation
import Testing
@testable import LoupeCore

@Suite struct InfoPanelContentTests {
    private func info(orientation: ImageOrientation = .up, progressive: Bool = false) -> ImageInfo {
        ImageInfo(pixelSize: PixelSize(width: 4000, height: 3000), typeIdentifier: "public.jpeg", isProgressive: progressive,
                  fileSize: 12_345_678, colorSpaceName: "Display P3", orientation: orientation)
    }

    private func file(name: String = "a.jpg", folder: String = "/Photos/Trip", fileSize: Int? = 12_345_678, info: ImageInfo? = nil,
                      applying: Bool = true, error: String? = nil) -> InfoFileFacts {
        InfoFileFacts(name: name, folder: folder, fileSize: fileSize, info: info, applyingOrientation: applying, error: error)
    }

    private func sections(file: InfoFileFacts? = nil, metadata: PhotoMetadata? = nil, pending: Bool = false,
                          display: InfoDisplayFacts? = nil, diagnostics: [InfoRow] = []) -> [InfoSection] {
        InfoPanelContent.sections(file: file, metadata: metadata, metadataPending: pending, display: display,
                                  diagnostics: diagnostics)
    }

    private func rows(_ sections: [InfoSection], _ title: String) -> [InfoRow]? { sections.first { $0.title == title }?.rows }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func metadata(_ edit: (inout PhotoMetadata) -> Void = { _ in }) -> PhotoMetadata {
        var m = PhotoMetadata(properties: [:], pngText: [:], created: nil, modified: nil)
        edit(&m)
        return m
    }

    @Test func nothingKnownGivesNoSections() {
        #expect(sections().isEmpty)
    }

    @Test func emptySectionsAndRowsAreLeftOut() {
        let s = sections(file: file(name: "", folder: "", fileSize: nil), metadata: metadata(),
                         display: InfoDisplayFacts(mode: "", filter: nil, colour: nil), diagnostics: [])
        #expect(s.isEmpty)
    }

    @Test func fileRowsInOrder() {
        let m = metadata { $0.created = date(2024, 5, 1, 9, 7); $0.modified = date(2025, 1, 31, 23, 59)
                           $0.bitDepth = 16; $0.hasAlpha = true }
        let s = sections(file: file(info: info(progressive: true)), metadata: m)
        #expect(rows(s, "File") == [
            InfoRow(label: "Name", value: "a.jpg"),
            InfoRow(label: "Folder", value: "/Photos/Trip"),
            InfoRow(label: "Size", value: "12.3 MB"),
            InfoRow(label: "Modified", value: "2025-01-31 23:59"),
            InfoRow(label: "Created", value: "2024-05-01 09:07"),
            InfoRow(label: "Format", value: "JPEG progressive"),
            InfoRow(label: "Dimensions", value: "4000 × 3000"),
            InfoRow(label: "Bit depth", value: "16-bit"),
            InfoRow(label: "Profile", value: "Display P3"),
            InfoRow(label: "Alpha", value: "yes"),
        ])
    }

    @Test func bitDepthAndAlphaOnlyWhenTheMetadataKnowsThem() {
        func labels(_ m: PhotoMetadata?, pending: Bool = false) -> [String] {
            rows(sections(file: file(info: info()), metadata: m, pending: pending), "File")?.map(\.label) ?? []
        }
        #expect(!labels(nil).contains("Bit depth") && !labels(nil).contains("Alpha"))
        #expect(!labels(metadata()).contains("Bit depth") && !labels(metadata()).contains("Alpha"))
        // Pending: whatever an earlier read left is not shown.
        #expect(!labels(metadata { $0.bitDepth = 8; $0.hasAlpha = true }, pending: true).contains("Bit depth"))
        let eight = rows(sections(file: file(info: info()), metadata: metadata { $0.bitDepth = 8; $0.hasAlpha = false }), "File")!
        #expect(eight.first { $0.label == "Bit depth" }?.value == "8-bit")
        #expect(eight.first { $0.label == "Alpha" }?.value == "no")
    }

    @Test func fileFromWhatIsKnownWhileLoading() {
        let s = sections(file: file(), metadata: nil, pending: true)
        #expect(rows(s, "File")?.map(\.label) == ["Name", "Folder", "Size"])
    }

    @Test func alphaAndOrientationOnlyWhenTheyApply() {
        let plain = rows(sections(file: file(info: info())), "File")!
        #expect(!plain.contains { $0.label == "Alpha" || $0.label == "Orientation" })
        let turned = rows(sections(file: file(info: info(orientation: .right))), "File")!
        #expect(turned.first { $0.label == "Orientation" }?.value == "6 (rotated 90° CW)")
        #expect(turned.first { $0.label == "Dimensions" }?.value == "3000 × 4000")
        // exif-orientation=no: stored dimensions, the file's orientation is still a fact.
        let stored = rows(sections(file: file(info: info(orientation: .right), applying: false)), "File")!
        #expect(stored.first { $0.label == "Dimensions" }?.value == "4000 × 3000")
        #expect(stored.contains { $0.label == "Orientation" })
    }

    @Test func orientationWords() {
        let words = ImageOrientation.allCases.dropFirst().map { InfoPanelContent.orientationText($0) }
        #expect(words == ["2 (mirrored)", "3 (rotated 180°)", "4 (flipped vertically)", "5 (transposed)",
                          "6 (rotated 90° CW)", "7 (anti-transposed)", "8 (rotated 90° CCW)"])
    }

    @Test func errorRowComesFromTheFileOrTheMetadata() {
        #expect(rows(sections(file: file(error: "Could not decode")), "File")?.last == InfoRow(label: "Error", value: "Could not decode"))
        let m = metadata { $0.error = "File not found" }
        #expect(rows(sections(file: file(), metadata: m), "File")?.last == InfoRow(label: "Error", value: "File not found"))
        #expect(rows(sections(file: file(error: "Own"), metadata: m), "File")?.last?.value == "Own")
    }

    @Test func captureRows() {
        let m = metadata {
            $0.camera = "Nikon Z 6"; $0.lens = "24-70mm"; $0.focalLength = "50 mm"; $0.aperture = "f/2.8"; $0.exposure = "1/250 s"
            $0.iso = "ISO 100"; $0.captured = "2024-05-01 12:34:56"; $0.gps = "50.1° N, 8.6° E"; $0.software = "Lightroom"
            $0.description = "Harbour"; $0.generation = "a cat\nSteps: 20"
        }
        let capture = rows(sections(metadata: m), "Capture")!
        #expect(capture.map(\.label) == ["Camera", "Lens", "Focal length", "Aperture", "Exposure", "ISO", "Captured", "GPS",
                                         "Software", "Description", "Generation"])
        #expect(capture.last?.value == "a cat\nSteps: 20")
    }

    @Test func comfyRow() {
        func comfy(_ bytes: Int) -> String? {
            rows(sections(metadata: metadata { $0.comfyWorkflowBytes = bytes }), "Capture")?.first { $0.label == "ComfyUI" }?.value
        }
        #expect(comfy(12 * 1024) == "workflow, 12 KB")
        #expect(comfy(12_800) == "workflow, 13 KB")   // 12.5 KB rounds up
        #expect(comfy(1023) == "workflow, <1 KB")
        #expect(comfy(0) == "workflow, <1 KB")
        #expect(comfy(2_000_000) == "workflow, 1953 KB")   // the true size, past the 64 KB the text is cut at
    }

    @Test func captureReadingWhilePending() {
        let s = sections(file: file(), metadata: nil, pending: true)
        #expect(rows(s, "Capture") == [InfoRow(label: "Capture", value: "Reading…")])
        // Pending wins over what an earlier read left.
        let stale = sections(metadata: metadata { $0.camera = "X" }, pending: true)
        #expect(rows(stale, "Capture") == [InfoRow(label: "Capture", value: "Reading…")])
    }

    @Test func noCaptureSectionWithoutCaptureData() {
        #expect(rows(sections(file: file(), metadata: metadata()), "Capture") == nil)
    }

    @Test func displayRows() {
        let facts = InfoDisplayFacts(mode: "Fit 23 %", filter: "downscale lanczos3 ×0.87 L1", colour: "Colour: off")
        #expect(rows(sections(display: facts), "Display") == [
            InfoRow(label: "Zoom", value: "Fit 23 %"),
            InfoRow(label: "Filter", value: "downscale lanczos3 ×0.87 L1"),
            InfoRow(label: "Colour", value: "off"),   // not "Colour: Colour: off"
        ])
        let auto = InfoDisplayFacts(mode: "Fit 23 %", filter: nil,
                                    colour: StatsLine.colour(.applied(method: .apple, share: 0.42, delta: 8.5), vibrance: 0.5,
                                                             fromFolder: true))
        #expect(rows(sections(display: auto), "Display")?.last == InfoRow(label: "Colour",
                                                                          value: "auto apple 0.42 · Δ 8.5 · vibrance 0.5 · folder"))
        let bare = InfoDisplayFacts(mode: "100 %", filter: nil, colour: nil)
        #expect(rows(sections(display: bare), "Display") == [InfoRow(label: "Zoom", value: "100 %")])
    }

    @Test func sectionOrderAndDiagnostics() {
        let diag = [InfoRow(label: "Decoder", value: "ImageIO")]
        let s = sections(file: file(), metadata: metadata { $0.camera = "X" },
                         display: InfoDisplayFacts(mode: "Fit 10 %", filter: nil, colour: nil), diagnostics: diag)
        #expect(s.map(\.title) == ["File", "Capture", "Display", "Diagnostics"])
        #expect(rows(s, "Diagnostics") == diag)
    }

    @Test func sizeIsDecimalMegabytes() {
        #expect(rows(sections(file: file(fileSize: 52_340_000)), "File")?.first { $0.label == "Size" }?.value == "52.3 MB")
        #expect(rows(sections(file: file(fileSize: 0)), "File")?.first { $0.label == "Size" }?.value == "0.0 MB")
    }
}
