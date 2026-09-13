import SwiftUI

/// Light, dark, or whatever the phone is doing.
///
/// The web client has had a theme toggle in the corner of its rail since the
/// start; the phone simply followed iOS, so the two clients could not be made
/// to look the same on the same desk. Stored as a raw string in `UserDefaults`
/// under one key, read through `@AppStorage` wherever it is needed.
///
/// The whole palette in `DesignSystem.swift` resolves through
/// `UITraitCollection.userInterfaceStyle`, so nothing here has to touch a
/// colour: applying `.preferredColorScheme` at the root flips the trait and
/// every `dynamicColor` in the app follows it in one pass.
enum GraftTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "graft.theme"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: return "iphone"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    /// `nil` means "don't override", which is what `.preferredColorScheme`
    /// wants for the system case.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
