import Foundation

/// The work ahead's subfolders (thumbs-ahead spec, stage 4) of a folder's cards: each card's entries are made once,
/// when its subfolders' names come (`entries`, off the main thread), and kept until the folder changes; an ask joins
/// the ids of the cards in view, in their order, up to `limit`. The queue's ids carry their card, so a task finds its
/// subfolder (`card`) in the kept entries without a table of every subfolder made for each ask.
public struct AheadSubfolders: Sendable {
    /// A subfolder of a card in view, as the work ahead makes it.
    public struct Card: Sendable, Equatable {
        /// The cover queue's id: its card and its name (`AheadSubfolders.id`).
        public var id: String
        /// The card's id (the folder card it is a subfolder of).
        public var parent: String
        public var url: URL
        /// Where the catalog keeps it, and its card's folder; nil when the folder on screen has no place there.
        public var location: ThumbnailLocation?
        public var parentLocation: ThumbnailLocation?
    }

    /// One card's subfolders, in Finder order: their ids for an ask, and each by id.
    public struct Entries: Sendable {
        var ids: [String]
        var cards: [String: Card]
    }

    /// Subfolders an ask sends to the cover queue at most, all cards in view together. Basis: the work ahead makes
    /// 11-13 subfolders a second on a local SSD (`CoverQueue.listingLimit`'s bench: 72 subfolders in 5.4-6.5 s on an
    /// Intel iMac, i7-10700K), so 1 000 is over a minute of work, more than one screen is looked at before the next
    /// ask (a scroll) sends the list again; and every ask then costs the main thread a bounded join and the queue a
    /// bounded `want`, whatever the cards hold (a card may have up to `coverSubfoldersPerFolder`, 1 000, itself).
    /// Measured (`aheadAskBench`, debug test build, the same iMac; a synthetic local tree of 30 folders of 1 000 empty
    /// subfolders each, names only, on SSD; 20 asks): main-thread time per ask, median / max of two runs, 187-190 /
    /// 207-251 ms before (every subfolder's entry and a dictionary of all 30 000 made on each ask), 0.020 / 0.073 ms
    /// after with the limit (0.93-0.99 / 2.0-2.1 ms uncapped); the entries made once for all 30 cards: 136 ms in all
    /// (4.5 ms a card), off the main thread.
    public static let limit = 1_000

    private var byCard: [String: Entries] = [:]

    public init() {}

    /// Whether `card`'s subfolders are known (perhaps none).
    public func has(_ card: String) -> Bool { byCard[card] != nil }

    /// `card`'s subfolders, kept for the asks to come.
    public mutating func set(_ entries: Entries, for card: String) {
        byCard[card] = entries
    }

    /// The ids of `cards`' subfolders, card by card in the order given, those whose names are known, at most `limit`.
    public func ids(for cards: [String], limit: Int = Self.limit) -> [String] {
        var ids: [String] = []
        for card in cards {
            guard ids.count < limit else { break }
            guard let entries = byCard[card] else { continue }
            ids.append(contentsOf: entries.ids.prefix(limit - ids.count))
        }
        return ids
    }

    /// The subfolder of a queue id (`ids`); nil for one not among the kept entries (the folder changed since).
    public func card(_ id: String) -> Card? {
        guard let parent = Self.parent(of: id) else { return nil }
        return byCard[parent]?.cards[id]
    }

    /// The entries of `card`'s subfolders `names` (in Finder order) in its `folder` (the catalog's `location` for it):
    /// made once per card, off the main thread.
    public static func entries(_ names: [String], card: String, folder: URL,
                               location: ThumbnailLocation?) -> Entries {
        var ids: [String] = []
        var cards: [String: Card] = [:]
        ids.reserveCapacity(names.count)
        cards.reserveCapacity(names.count)
        for name in names {
            let id = Self.id(parent: card, name: name)
            guard cards[id] == nil else { continue }
            ids.append(id)
            cards[id] = Card(id: id, parent: card, url: folder.appendingPathComponent(name, isDirectory: true),
                             location: location?.subfolder(name), parentLocation: location)
        }
        return Entries(ids: ids, cards: cards)
    }

    /// The queue's id of `parent`'s subfolder `name`: apart from every card's id (a path has no NUL).
    static func id(parent: String, name: String) -> String { prefix + parent + "\u{0}" + name }

    private static let prefix = "\u{0}ahead\u{0}"

    static func parent(of id: String) -> String? {
        guard id.hasPrefix(prefix), let end = id.lastIndex(of: "\u{0}") else { return nil }
        let start = id.index(id.startIndex, offsetBy: prefix.count)
        guard start <= end else { return nil }
        return String(id[start..<end])
    }
}
