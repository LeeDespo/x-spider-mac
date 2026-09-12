import Foundation

enum NavigationItem: String, CaseIterable, Identifiable {
    case home = "Home"
    case sync = "Sync"
    case downloads = "Downloads"
    case settings = "Settings"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: return "photo.on.rectangle.angled"
        case .sync: return "arrow.triangle.2.circlepath"
        case .downloads: return "arrow.down.circle"
        case .settings: return "gear"
        case .about: return "info.circle"
        }
    }
}
