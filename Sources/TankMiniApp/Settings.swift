import AppKit
import SwiftUI

/// User preferences, stored in the app's defaults.
@MainActor
final class AppSettings: ObservableObject {
    enum Theme: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
    }

    /// `system` follows the Mac's language order; the others pin the app to one language.
    enum Language: String, CaseIterable, Identifiable {
        case system
        case english = "en"
        case portuguese = "pt-BR"
        var id: String { rawValue }
    }

    private enum Key {
        static let theme = "theme"
        static let showModelNotes = "showModelNotes"
        static let confirmDiscard = "confirmDiscard"
        static let automaticBackups = "automaticBackups"
        static let languages = "AppleLanguages" // the key macOS itself reads for a per-app language
    }

    private let defaults = UserDefaults.standard

    @Published var theme: Theme {
        didSet { defaults.set(theme.rawValue, forKey: Key.theme); applyTheme() }
    }

    @Published var language: Language {
        didSet {
            if language == .system {
                defaults.removeObject(forKey: Key.languages)
            } else {
                defaults.set([language.rawValue], forKey: Key.languages)
            }
        }
    }

    @Published var showModelNotes: Bool {
        didSet { defaults.set(showModelNotes, forKey: Key.showModelNotes) }
    }

    @Published var confirmDiscard: Bool {
        didSet { defaults.set(confirmDiscard, forKey: Key.confirmDiscard) }
    }

    @Published var automaticBackups: Bool {
        didSet { defaults.set(automaticBackups, forKey: Key.automaticBackups) }
    }

    /// The language the running app started with. Text is loaded at launch, so a
    /// different choice only shows after the app is reopened.
    let launchLanguage: Language

    var languageNeedsRelaunch: Bool { language != launchLanguage }

    init() {
        let stored = UserDefaults.standard
        theme = Theme(rawValue: stored.string(forKey: Key.theme) ?? "") ?? .system
        showModelNotes = stored.object(forKey: Key.showModelNotes) as? Bool ?? true
        confirmDiscard = stored.object(forKey: Key.confirmDiscard) as? Bool ?? true
        automaticBackups = AppSettings.automaticBackupsEnabled

        // Only a language saved for this app counts; the Mac-wide list means "system".
        let own = Bundle.main.bundleIdentifier.flatMap { stored.persistentDomain(forName: $0) }
        let pinned = (own?[Key.languages] as? [String])?.first
        let current = pinned.flatMap { Language(rawValue: $0) } ?? .system
        language = current
        launchLanguage = current
    }

    /// Read without an instance, for code that runs off the main actor's view tree.
    nonisolated static var automaticBackupsEnabled: Bool {
        UserDefaults.standard.object(forKey: Key.automaticBackups) as? Bool ?? true
    }

    func applyTheme() {
        switch theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Open a fresh copy of the app, then quit this one.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// The Settings window (Tank Mini > Settings…, or Command-comma).
struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.theme) {
                    Text("System").tag(AppSettings.Theme.system)
                    Text("Light").tag(AppSettings.Theme.light)
                    Text("Dark").tag(AppSettings.Theme.dark)
                }
                .pickerStyle(.segmented)

                Picker("Language", selection: $settings.language) {
                    Text("System").tag(AppSettings.Language.system)
                    // Language names are shown in their own language.
                    Text(verbatim: "English").tag(AppSettings.Language.english)
                    Text(verbatim: "Português (Brasil)").tag(AppSettings.Language.portuguese)
                }

                if settings.languageNeedsRelaunch {
                    LabeledContent {
                        Button("Relaunch Now") { settings.relaunch() }
                    } label: {
                        Text("Reopen Tank Mini to change the language.")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Editing") {
                Toggle(isOn: $settings.showModelNotes) {
                    Text("Show notes about each model")
                    Text("Says which amp or cabinet a model appears to be based on.")
                }
                Toggle(isOn: $settings.confirmDiscard) {
                    Text("Ask before discarding unsaved changes")
                    Text("When you switch presets with edits that are not saved to the pedal.")
                }
            }

            Section("Backups") {
                Toggle(isOn: $settings.automaticBackups) {
                    Text("Back up presets automatically")
                    Text("Copies all 21 presets to this Mac whenever they have changed on the pedal.")
                }
                LabeledContent("Backup folder") {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: Backups.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Backups.folder)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
