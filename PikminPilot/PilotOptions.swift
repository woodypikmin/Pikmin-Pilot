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

    /// Calibrated against the user's real iPhone selection screenshots after
    /// the existing filter-row reveal swipe. The row has eight evenly-spaced
    /// circles; these are the four types Pikmin Pilot currently exposes.
    var filterNormalizedX: CGFloat {
        switch self {
        case .purple: return 0.5894
        case .white:  return 0.6727
        case .pink:   return 0.7560
        case .rock:   return 0.8395
        }
    }

    var filterNormalizedY: CGFloat { 0.4226 }
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
