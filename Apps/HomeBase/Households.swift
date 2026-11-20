import SovereignShell
import SwiftUI

/// The households this phone has joined (the current one first) and what the home can do with them.
struct Households {
    let known: KnownHouseholds
    /// Switches to a household, or joins a new one.
    let open: (HomeBaseAddress) -> Void
    /// Keeps the name a household's Home Base gives it.
    let name: (HomeBaseAddress, String) -> Void
    /// Forgets a household other than the current one.
    let forget: (HomeBaseAddress) -> Void

    /// The others, most recently used first.
    func others(than current: HomeBaseAddress) -> [KnownHouseholds.Entry] {
        known.entries.filter { $0.address != current }
    }
}

/// Every household this phone has joined: tap one to switch, swipe one away to forget it, or join another.
/// Leaving is by `choose`, which the home runs once this sheet has gone.
struct HouseholdsView: View {
    let current: HomeBaseAddress
    let households: Households
    let choose: (HomeBaseAddress) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(households.known.entries, id: \.address) { entry in
                        Button {
                            if entry.address != current { choose(entry.address) }
                            dismiss()
                        } label: {
                            HouseholdRow(entry: entry, current: entry.address == current)
                        }
                        .foregroundStyle(.primary)
                        .deleteDisabled(entry.address == current)
                    }
                    .onDelete { offsets in
                        offsets.map { households.known.entries[$0].address }.forEach(households.forget)
                    }
                } footer: {
                    Text("Swipe left to forget a household on this phone. Your membership in it doesn't change.")
                }
                Section {
                    NavigationLink {
                        JoinForm(welcome: false) { address in
                            choose(address)
                            dismiss()
                        }
                    } label: {
                        Label("Join another household", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("Households")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct HouseholdRow: View {
    let entry: KnownHouseholds.Entry
    let current: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.headline)
                Text(entry.address.host)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if current {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Current household")
            }
        }
        .contentShape(Rectangle())
    }
}
