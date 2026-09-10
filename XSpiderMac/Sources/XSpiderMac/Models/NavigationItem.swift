import Foundation

enum NavigationItem: String, CaseIterable, Identifiable {
    case home = "Home"
    case downloads = "Downloads"
    case settings = "Settings"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: return "photo.on.rectangle.angled"
        case .downloads: return "arrow.down.circle"
        case .settings: return "gear"
        case .about: return "info.circle"
        }
    }
}
