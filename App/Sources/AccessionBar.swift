import JumpjetHUD
import SwiftUI

/// The accession entry, styled as an instrument input rather than a search bar.
struct AccessionBar: View {
    @Bindable var model: AppModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HUDPanel {
            HStack(spacing: 10) {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(HUDPalette.primary)
                    .rotationEffect(.degrees(90))

                // Short enough not to truncate at compact width, where the
                // lamp and the launch control take most of the row.
                TextField("ACCESSION", text: $model.accessionText)
                    .textFieldStyle(.plain)
                    .font(HUDTypography.readout(20))
                    .foregroundStyle(HUDPalette.text)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .focused($isFocused)
                    .submitLabel(.go)
                    .onSubmit(launch)
                    .accessibilityLabel("UniProt accession")

                if model.status.isLoading {
                    Button {
                        model.cancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(HUDPalette.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel")
                } else {
                    // The validity lamp is live as the user types, so a typo is
                    // visible before it costs a round trip.
                    HUDLamp(
                        role: model.accessionText.isEmpty
                            ? .inactive : (model.canLaunch ? .nominal : .caution),
                        text: model.accessionText.isEmpty
                            ? "standby" : (model.canLaunch ? "valid" : "check"))
                }

                HUDActionButton(
                    "Launch", systemImage: "paperplane.fill", isEnabled: model.canLaunch,
                    action: launch
                )
                .frame(width: 140)
            }
        }
    }

    private func launch() {
        guard model.canLaunch else { return }
        isFocused = false
        model.load()
    }
}
