/// Bidirectional selection of a bounded list, without queued intermediate work.
public enum ChoiceCycle {
    public static func index(current: Int?, count: Int, direction: Int) -> Int? {
        guard count > 0, direction != 0 else { return nil }
        guard let current, (0..<count).contains(current) else { return direction > 0 ? 0 : count - 1 }
        return (current + (direction > 0 ? 1 : count - 1)) % count
    }
}
