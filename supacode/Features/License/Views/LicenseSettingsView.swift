import ComposableArchitecture
import SwiftUI

struct LicenseSettingsView: View {
  @Bindable var store: StoreOf<LicenseFeature>

  var body: some View {
    Form {
      if store.snapshot.entitlement?.status == .active {
        Section {
          Text(
            "Owned versions work offline. Transfers and refunds apply after this Mac next refreshes its license."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          Button("Deactivate This Mac") { store.send(.deactivate) }
            .disabled(store.isBusy)
            .help("Deactivate this Mac so you can activate your license on another Mac.")
          Button("Refresh License") { store.send(.refresh) }
            .disabled(store.isBusy)
            .help("Check the license server for renewed updates or license changes.")
        }
      } else {
        Section("Activate") {
          TextField("License key", text: $store.keyInput)
            .textFieldStyle(.roundedBorder)
            .monospaced()
            .onSubmit { store.send(.activate) }
          Button("Activate License") { store.send(.activate) }
            .keyboardShortcut(.return)
            .disabled(
              store.isBusy || store.keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .help("Activate your license on this Mac. Return.")
        }
      }

      if let error = store.errorMessage {
        Text(error).foregroundStyle(.red)
      }
      if store.isBusy { ProgressView().controlSize(.small) }
      Section {
        Button("Buy Supacode") { store.send(.buy) }
          .help("Purchase a Supacode license in your browser.")
        Button("License Portal") { store.send(.portal) }
          .help("Recover your key, renew updates, or manage your license.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("License")
  }
}
