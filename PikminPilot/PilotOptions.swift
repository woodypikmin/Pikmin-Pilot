import Foundation
import CoreGraphics

enum PilotPikminType: String, CaseIterable, Identifiable {
    case pink
    case white
    case purple
    case rock

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pink: return "粉紅"
        case .white: return "白"
        case .purple: return "紫"
        case .rock: return "岩"
        }
    }

    var shortName: String { "\(displayName)皮" }

    var minimumCount: Int {
        switch self {
        case .pink, .white:
            return 6
        case .purple, .rock:
            return 2
        }
    }

    /// Logical order in the live filter row. Stage 11.5 no longer converts
    /// these to fixed screen coordinates; ImageAutomationDetector derives the
    /// actual row spacing from the purple/pink anchors in each screenshot.
    var filterRowOrdinal: Int {
        switch self {
        case .purple: return 4
        case .white:  return 5
        case .pink:   return 6
        case .rock:   return 7
        }
    }
}

enum PilotCargoMode: String, CaseIterable, Identifiable {
    case fruit
    case seedling
    case both

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fruit: return "水果"
        case .seedling: return "花苗"
        case .both: return "水果＋花苗"
        }
    }

    var scanDescription: String {
        switch self {
        case .fruit: return "可用水果"
        case .seedling: return "可用花苗"
        case .both: return "可搬運項目"
        }
    }
}
