import Foundation

/// The marks of a folder's photo cards (photo-cards spec 2026-10-26, §3): which photos are not viewed yet (the dot)
/// and which are a page of a two-page pair (the ⧉ chip). Pure and O(n) in the folder's photos; nothing is read from
/// files.
public enum PhotoMarks {
    /// Not viewed yet: the photos after the folder's remembered photo (`remembered`, a file name) in `order` (the
    /// browser's, which the viewer follows), and those modified after the visit. With no remembered photo, or one gone
    /// and no visit, all of them. `partner`, the other page of the remembered one's pair, was on screen with it.
    public static func unseen(order: [URL], remembered: String?, visit: FolderVisit?,
                              modified: (URL) -> Date?, partner: URL? = nil) -> Set<URL> {
        let at = remembered.flatMap { name in order.firstIndex { $0.lastPathComponent == name } }
        if at == nil, visit == nil || remembered == nil { return Set(order) }
        var result: Set<URL> = []
        if let at { result.formUnion(order[(at + 1)...]) }
        if let partner { result.remove(partner) }
        if let visited = visit?.visited {
            for url in order { if let date = modified(url), date > visited { result.insert(url) } }
        }
        return result
    }

    /// Pages in a pair while the folder's two pages are on (`rules.on`): both pages of each pair of the `SpreadPlan`
    /// over `order`. `aspects` (width / height, parallel to `order`, shorter or [] for unknown: portrait) matter only
    /// with `landscapeAlone`.
    public static func paired(order: [URL], rules: SpreadRules, aspects: [Double?]) -> Set<URL> {
        Set(pairs(order: order, rules: rules, aspects: aspects).keys)
    }

    /// `paired`'s pages, each to the other page of its pair.
    public static func pairs(order: [URL], rules: SpreadRules, aspects: [Double?]) -> [URL: URL] {
        guard rules.on, !order.isEmpty else { return [:] }
        let plan = SpreadPlan(sizes: SpreadSizes.sizes(files: order, aspects: aspects, headers: [:]),
                              options: rules.options)
        var result: [URL: URL] = [:]
        var pair = plan.first
        while let current = pair {
            if let second = current.second {
                result[order[current.first]] = order[second]
                result[order[second]] = order[current.first]
            }
            pair = plan.next(after: current)
        }
        return result
    }
}
