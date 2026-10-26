import AppKit

extension Notification.Name {
    /// The prototype's knobs changed (`PocketTuning`): every pocket bar applies them.
    static let pocketTuningChanged = Notification.Name("PocketTuningChanged")
}

/// The knobs of the pocket bar prototype (`viewer-chrome=pocket`), all in one place so one build can be tuned by eye
/// from View › Pocket Tuning…. They are kept in the user defaults as one JSON value and applied live. Every number has a
/// range the panel keeps it to; the defaults are a first guess.
@MainActor final class PocketTuning {
    static let shared = PocketTuning()
    private static let key = "pocketTuning"

    /// What stands behind the bar's text.
    enum Backdrop: Int, CaseIterable {
        case native, custom, both, none
        var title: String {
            switch self {
            case .native: "System pocket"
            case .custom: "Own blur and tint"
            case .both: "Both"
            case .none: "Nothing"
            }
        }
    }

    struct Values: Codable, Equatable {
        // What is behind the text.
        var backdrop = Backdrop.native.rawValue
        // The system pocket (`NSScrollPocket`) and what it is fed.
        var nativeStyle = 0                 // `style`: 0, 1, 2, 3 (0 is the scroll view's own, 2 the title bar's)
        var appearance = 2                  // `appearanceBias`: 0 the system's, 1 light, 2 dark
        var solidHard = false               // `prefersSolidColorHardPocket`
        var adaptivity = true               // `allowsColorSchemeAdaptivity`
        var separators = false              // `_showSeparatorsOnHardPocket`
        var captureColor = 0                // `captureColor`: 0 none, 1 black, 2 white, 3 grey
        var portalSource = 1                // what the pocket's portal shows: 0 nothing, 1 the picture, 2 the whole window
        var portalMatchesPosition = false
        var portalMatchesTransform = false
        var forceBlur = false               // keep the pocket's blur view shown
        // Own blur and tint (`EdgeEffectView`).
        var customTint = 0.35
        var customBlur = true
        var customHard = false
        // The bar.
        var rowHeight = 44.0
        var fadeBelow = 40.0                // the pocket's reach below the row
        var sideInset = 14.0
        var rowInTitlebar = false           // the row stands in the title bar's height, beside the traffic lights
        var windowedLeftInset = 78.0        // clear of the traffic lights when it does
        var infoSize = 11.5
        var buttonSize = 15.0
        var buttonGap = 8.0                 // between groups of buttons
        var buttonGlass = 1                 // 0 none, 1 glass pills for the groups, 2 clear glass pills, 3 glass bezel on each
        var pillPadding = 3.0
        var buttonOpacity = 0.92
        var infoGap = 16.0

        // Each key is read so that a value an older build wrote does not stop the others from loading.
        init() {}
        init(from decoder: Decoder) throws {
            self.init()
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func read<T: Decodable>(_ key: CodingKeys, _ value: inout T) { if let v = try? container.decode(T.self, forKey: key) { value = v } }
            read(.backdrop, &backdrop); read(.nativeStyle, &nativeStyle); read(.appearance, &appearance)
            read(.solidHard, &solidHard); read(.adaptivity, &adaptivity); read(.separators, &separators)
            read(.captureColor, &captureColor); read(.portalSource, &portalSource)
            read(.portalMatchesPosition, &portalMatchesPosition); read(.portalMatchesTransform, &portalMatchesTransform)
            read(.forceBlur, &forceBlur); read(.customTint, &customTint); read(.customBlur, &customBlur)
            read(.customHard, &customHard); read(.rowHeight, &rowHeight); read(.fadeBelow, &fadeBelow)
            read(.sideInset, &sideInset); read(.rowInTitlebar, &rowInTitlebar); read(.windowedLeftInset, &windowedLeftInset); read(.infoSize, &infoSize)
            read(.buttonSize, &buttonSize); read(.buttonGap, &buttonGap); read(.buttonGlass, &buttonGlass); read(.pillPadding, &pillPadding); read(.buttonOpacity, &buttonOpacity)
            read(.infoGap, &infoGap)
        }
    }

    var values: Values {
        didSet {
            guard values != oldValue else { return }
            if let data = try? JSONEncoder().encode(values) { UserDefaults.standard.set(data, forKey: Self.key) }
            NotificationCenter.default.post(name: .pocketTuningChanged, object: nil)
        }
    }

    private init() {
        values = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Values.self, from: $0) }
            ?? Values()
    }

    func reset() { values = Values() }
}

/// What the bar shows: the information and the buttons, the information only, or nothing.
enum PocketBarState: Int, CaseIterable {
    case full, information, hidden

    var next: PocketBarState { PocketBarState(rawValue: (rawValue + 1) % Self.allCases.count) ?? .full }
    var title: String {
        switch self {
        case .full: "Information and buttons"
        case .information: "Information only"
        case .hidden: "Nothing"
        }
    }

    private static let key = "pocketBarState"
    static var stored: PocketBarState {
        get { PocketBarState(rawValue: UserDefaults.standard.object(forKey: key) as? Int ?? 0) ?? .full }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
