import JumpjetHUD
import SwiftUI

@main
struct JUMPjetApp: App {
    @State private var model = AppModel()

    /// A development and test seam: `JUMPJET_AUTOLOAD=P69905` loads that
    /// accession on launch.
    ///
    /// This exists so a screenshot or a UI test can reach a loaded structure
    /// without driving the keyboard, which is the flakiest part of any iOS
    /// interface test. It reads an environment variable rather than a build
    /// flag so a release build behaves identically when nothing sets it.
    private static var autoloadAccession: String? {
        let value = ProcessInfo.processInfo.environment["JUMPJET_AUTOLOAD"]?
            .trimmingCharacters(in: .whitespaces)
        return (value?.isEmpty == false) ? value : nil
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task {
                    if let accession = Self.autoloadAccession {
                        model.load(accession)
                    }
                }
                // Dark only. The build plan's design system is a night cockpit
                // and there is no light variant of it: letting the system flip
                // it would produce phosphor green on white.
                .preferredColorScheme(.dark)
                .tint(HUDPalette.primary)
        }
    }
}
