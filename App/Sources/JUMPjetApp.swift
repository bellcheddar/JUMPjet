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

    /// `JUMPJET_AUTORUN=2000` starts a run of that many sweeps as soon as the
    /// structure is on screen. The companion to `JUMPJET_AUTOLOAD`, and for the
    /// same reason: a screenshot of a run in progress otherwise needs somebody
    /// to tap a button.
    private static var autorunSweeps: Int? {
        ProcessInfo.processInfo.environment["JUMPJET_AUTORUN"].flatMap(Int.init)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task {
                    if let accession = Self.autoloadAccession {
                        model.load(accession)
                    }
                }
                .onChange(of: model.structure != nil) { _, hasStructure in
                    guard hasStructure, let sweeps = Self.autorunSweeps else { return }
                    model.run.configuration.sweeps = sweeps
                    model.launchEngines()
                }
                // Dark only. The build plan's design system is a night cockpit
                // and there is no light variant of it: letting the system flip
                // it would produce phosphor green on white.
                .preferredColorScheme(.dark)
                .tint(HUDPalette.primary)
        }
    }
}
