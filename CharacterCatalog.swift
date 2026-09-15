import Foundation

enum CharacterCollection: String, CaseIterable {
    case basic, halloween

    // The display name can change with a seasonal edition; persisted IDs and ownership stay stable.
    var title: String {
        switch self {
        case .basic: return String(localized: "Basic Characters")
        case .halloween: return String(localized: "2026 Halloween")
        }
    }
    var motionPack: CharacterPack {
        switch self { case .basic: return .baseMotion; case .halloween: return .halloween }
    }
}
enum CharacterDisplayMode: String { case numbers, characters }

enum HalloweenCharacter: String, CaseIterable {
    case pumpkin = "pumpkin_zero", staff = "one_staff", bicycle = "two_wheel_bicycle"
    case hound = "three_head_hound", desk = "four_leg_desk", star = "five_point_witch"
    case web = "six_spoke_web", scythe = "seven_scythe", spider = "eight_leg_spider", fox = "nine_tail_fox"

    var driveCount: Int {
        switch self {
        case .pumpkin: return 0; case .staff: return 1; case .bicycle: return 2; case .hound: return 3
        case .desk: return 4; case .star: return 5; case .web: return 6; case .scythe: return 7
        case .spider: return 8; case .fox: return 9
        }
    }
    static func character(for count: Int) -> HalloweenCharacter? {
        allCases.first { $0.driveCount == count }
    }
    var title: String {
        switch self {
        case .pumpkin: return String(localized: "Pumpkin")
        case .staff: return String(localized: "Witch's Broom")
        case .bicycle: return String(localized: "Halloween Bicycle")
        case .hound: return String(localized: "Cerberus")
        case .desk: return String(localized: "Four-Legged Desk")
        case .star: return String(localized: "Witch-Hat Star")
        case .web: return String(localized: "Six-Spoke Web")
        case .scythe: return String(localized: "Seven-Shaped Scythe")
        case .spider: return String(localized: "Eight-Legged Spider")
        case .fox: return String(localized: "Nine-Tailed Fox")
        }
    }
    var previewTitle: String { "\(driveCount) · \(title)" }
}

struct CharacterSelection: Equatable {
    var display: CharacterDisplayMode = .characters
    var collection: CharacterCollection = .basic
    var basicReactive = false
    var halloweenAnimated = true

    init() {}
    init(defaults: UserDefaults) {
        display = CharacterDisplayMode(rawValue: defaults.string(forKey: "character.display") ?? "") ?? .characters
        collection = CharacterCollection(rawValue: defaults.string(forKey: "character.collection") ?? "") ?? .basic
        // The old character.halloween choice is deliberately ignored: live artwork follows count.
        basicReactive = defaults.bool(forKey: "character.basicReactive")
        halloweenAnimated = defaults.object(forKey: "character.halloweenAnimated") as? Bool ?? true
    }
    func save(to defaults: UserDefaults) {
        defaults.set(display.rawValue, forKey: "character.display")
        defaults.set(collection.rawValue, forKey: "character.collection")
        defaults.removeObject(forKey: "character.halloween")
        defaults.set(basicReactive, forKey: "character.basicReactive")
        defaults.set(halloweenAnimated, forKey: "character.halloweenAnimated")
    }
}

enum CharacterVisual: Equatable {
    case numbers
    case basic(count: Int, reactive: Bool)
    case halloween(HalloweenCharacter, animated: Bool)
}

enum CharacterPresentationPolicy {
    static func visual(selection: CharacterSelection, owned: Set<CharacterPack>, count: Int) -> CharacterVisual {
        guard selection.display == .characters else { return .numbers }
        if selection.collection == .halloween, owned.contains(.halloween) {
            guard let character = HalloweenCharacter.character(for: count) else { return .numbers }
            return .halloween(character, animated: selection.halloweenAnimated)
        }
        guard (0...12).contains(count) else { return .numbers }
        return .basic(count: count, reactive: selection.basicReactive && owned.contains(.baseMotion))
    }
}
