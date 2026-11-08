import Foundation
import LoupeCore
import Metal

/// Render-thread-only, two-entry cache of the visible source window. The original
/// pyramid remains immutable. Only the active level is filtered; a fitting
/// image may occupy the complete visible window, but no pyramid is duplicated.
final class DebandCache {
    struct Parameters {
        var levelSize: SIMD2<UInt32>
        var sourceColumns: UInt32
        var sourceSliceOffset: UInt32
        var outputTileOrigin: SIMD2<UInt32>
        var outputColumns: UInt32
        var firstSlice: UInt32 = 0
        var strength: Float
        var threshold: Float
        var radius: Float
        var protection: Float
        var mode: UInt32
        var iterations: UInt32
        var pad0: UInt32 = 0
        var encodedInput: UInt32 = 0
    }
    private final class Entry {
        weak var source: AnyObject?
        let texture: MTLTexture
        let settings: DebandSettings
        let window: Window
        var use: UInt64
        init(source: MTLTexture, texture: MTLTexture, settings: DebandSettings, window: Window, use: UInt64) {
            self.source=source; self.texture=texture; self.settings=settings; self.window=window; self.use=use
        }
    }
    private final class Failed {
        weak var source: AnyObject?
        let settings:DebandSettings
        let window:Window
        let message:String
        init(_ source:MTLTexture,_ settings:DebandSettings,_ window:Window,_ message:String) {
            self.source=source;self.settings=settings;self.window=window;self.message=message
        }
    }
    private var failed:[Failed]=[]
    private func reject(_ source:MTLTexture,_ settings:DebandSettings,_ window:Window,_ message:String) -> LevelFrame? {
        if failed.count==2 { failed.removeFirst() }
        failed.append(Failed(source,settings,window,message))
        failure=message
        return nil
    }
    struct Window: Equatable {
        var x: Int, y: Int, columns: Int, rows: Int
        var count: Int { columns*rows }
        var offset: UInt32 { UInt32(y*columns+x) }
        func contains(_ other: Self) -> Bool {
            x<=other.x && y<=other.y && x+columns>=other.x+other.columns && y+rows>=other.y+other.rows
        }
    }
    // This bounds retained filtered windows, independently of image size. A 6K
    // view near the pyramid's lowest sampling ratio needs <1 GiB of FP16 tiles;
    // lower-memory machines get 1/32 of physical RAM. Actual fixture bytes and
    // processing times are recorded in the debanding bench, not an FPS guarantee.
    let byteLimit: Int
    private var entries: [Entry] = []
    private var use: UInt64 = 0
    private(set) var failure: String?
    private(set) var dispatches = 0
    var allocatedBytes: Int { entries.reduce(0) { $0+$1.texture.allocatedSize } }
    init(byteLimit: Int = min(1<<30, Int(ProcessInfo.processInfo.physicalMemory/32))) { self.byteLimit=byteLimit }
    func clear() { entries.removeAll(); failed.removeAll(); failure=nil }

    static func window(_ frame: LevelFrame) -> Window? {
        let visible=frame.orientation.storedRect(frame.transform.visibleRect,
            storedSize:CGSize(width:frame.grid.imageSize.width,height:frame.grid.imageSize.height))
        let f=frame.factor
        // Includes partial compute groups, the reconstruction kernels and
        // MetalFX input padding. Deband itself reads the immutable full source.
        let rect=CGRect(x:visible.minX/f,y:visible.minY/f,width:visible.width/f,height:visible.height/f)
            .insetBy(dx:-128,dy:-128)
        let tiles=frame.grid.tiles(level:frame.level,intersecting:rect)
        guard let first=tiles.first, let last=tiles.last else { return nil }
        return Window(x:first.column,y:first.row,columns:last.column-first.column+1,rows:last.row-first.row+1)
    }

    func prepare(_ frame: LevelFrame, settings: DebandSettings, context: MetalContext,
                 commandBuffer: MTLCommandBuffer) -> LevelFrame? {
        failure=nil
        guard settings.active, let required=Self.window(frame) else { return nil }
        failed.removeAll { $0.source == nil }
        use &+= 1
        entries.removeAll { $0.source == nil }
        if let hit=entries.first(where: { $0.source === (frame.view as AnyObject) && $0.settings==settings && $0.window.contains(required) }) {
            hit.use=use
            return applying(hit,to:frame)
        }
        if let previous=failed.first(where: { $0.source === (frame.view as AnyObject) && $0.settings==settings && $0.window==required }) {
            failure=previous.message;return nil
        }
        let bytes=required.count*TileGrid.slotSize*TileGrid.slotSize*8
        guard required.count<=TileGrid.maxTilesPerLevel, bytes<=byteLimit else {
            return reject(frame.view,settings,required,"Debanding unavailable: visible source exceeds the filtered-texture memory budget")
        }
        while !entries.isEmpty && (entries.count>=2 || allocatedBytes+bytes>byteLimit) {
            entries.remove(at:entries.indices.min(by:{entries[$0].use<entries[$1].use})!)
        }
        let d=MTLTextureDescriptor()
        d.textureType = .type2DArray; d.pixelFormat = .rgba16Float
        d.width=TileGrid.slotSize; d.height=TileGrid.slotSize; d.arrayLength=required.count
        d.storageMode = .private; d.usage = [.shaderRead,.shaderWrite]
        guard let texture=context.device.makeTexture(descriptor:d) else {
            return reject(frame.view,settings,required,"Debanding unavailable: filtered-texture allocation failed")
        }
        // Metal's physical allocation can be larger than the descriptor estimate.
        guard texture.allocatedSize<=byteLimit else {
            return reject(frame.view,settings,required,"Debanding unavailable: filtered texture exceeds the memory budget")
        }
        while !entries.isEmpty && allocatedBytes+texture.allocatedSize>byteLimit { entries.removeFirst() }
        texture.label="deband visible source"
        let size=frame.grid.levelSize(frame.level)
        var p=Parameters(levelSize:SIMD2(UInt32(size.width),UInt32(size.height)),
            sourceColumns:UInt32(frame.columns),sourceSliceOffset:frame.sliceOffset,
            outputTileOrigin:SIMD2(UInt32(required.x),UInt32(required.y)),outputColumns:UInt32(required.columns),
            strength:Float(min(1,max(0,settings.strength))),threshold:Float(min(32,max(0.1,settings.threshold))/255),
            radius:Float(min(64,max(1,settings.radius))),protection:Float(min(1,max(0,settings.textureProtection))),
            mode:Self.mode(settings.mode),iterations:UInt32(min(4,max(1,settings.iterations))))
        guard let encoder=commandBuffer.makeComputeCommandEncoder() else {
            return reject(frame.view,settings,required,"Debanding unavailable: compute encoder failed")
        }
        // Reading opaque encoded bytes avoids an exact decode/encode round trip
        // at every neighborhood sample. Alpha still unpremultiplies in linear light.
        let rawFormat: MTLPixelFormat? = switch frame.view.pixelFormat {
        case .bgra8Unorm_srgb: .bgra8Unorm
        case .rgba8Unorm_srgb: .rgba8Unorm
        default: nil
        }
        let rawView=rawFormat.flatMap { frame.view.makeTextureView(pixelFormat:$0) }
        p.encodedInput=rawView == nil ? 0:1
        encoder.label="deband visible source"
        encoder.setComputePipelineState(context.deband)
        encoder.setTexture(rawView ?? frame.view,index:0); encoder.setTexture(texture,index:1)
        encoder.setBytes(&p,length:MemoryLayout<Parameters>.stride,index:0)
        encoder.dispatchThreads(MTLSize(width:TileGrid.slotSize,height:TileGrid.slotSize,depth:required.count),
            threadsPerThreadgroup:MTLSize(width:16,height:8,depth:1))
        encoder.endEncoding()
        dispatches += 1
        let entry=Entry(source:frame.view,texture:texture,settings:settings,window:required,use:use)
        entries.append(entry)
        failed.removeAll { $0.source === (frame.view as AnyObject) }
        return applying(entry,to:frame)
    }
    private func applying(_ entry: Entry, to original: LevelFrame) -> LevelFrame {
        var frame=original
        frame.view=entry.texture; frame.columns=entry.window.columns
        frame.sliceOffset=entry.window.offset; frame.debanded=true
        return frame
    }
    private static func mode(_ mode: DebandMode) -> UInt32 {
        switch mode {
        case .off: 0
        case .single: 1
        case .double: 2
        case .adaptive: 3
        case .reference: 4
        case .window: 5
        }
    }
}
