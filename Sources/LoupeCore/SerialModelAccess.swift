import Foundation

/// A bounded model cache shared by detector preflight and per-window inference.
/// The queue owns loading, all model use, and eviction. Neither a cached model nor a Vision request escapes:
/// operations return Sendable values only. Core ML requires a model to be used on one thread/queue at a time.
/// Replace this synchronous queue bridge with actor isolation if the detector entry points become async.
final class SerialModelAccess<Model>: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Loupe model access", qos: .utility)
    private let load: @Sendable (String) -> Model?
    private var loaded: [(path: String, model: Model?)] = []

    init(load: @escaping @Sendable (String) -> Model?) { self.load = load }

    func withModel<Result: Sendable>(_ path: String, operation: (Model) -> Result) -> Result? {
        queue.sync {
            let model: Model?
            if let index = loaded.firstIndex(where: { $0.path == path }) {
                let item = loaded.remove(at: index)
                loaded.append(item)
                model = item.model
            } else {
                model = load(path)
                loaded.append((path, model))
                if loaded.count > 2 { loaded.removeFirst(loaded.count - 2) }
            }
            guard let model else { return nil }
            return operation(model)
        }
    }
}
