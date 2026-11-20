import SovereignShell
import SwiftUI

/// The households this phone has joined (the current one first) and what the home can do with them.
struct Households {
    let known: KnownHouseholds
    /// Switches to a household, or joins a new one.
    let open: (HomeBaseAddress) -> Void
    /// Keeps the name a household's Home Base gives it.
    let name: (HomeBaseAddress, String) -> Void
    /// Forgets a household; the current one leaves the home, so the home asks for that after its sheet.
    let forget: (HomeBaseAddress) -> Void

    /// The others, most recently used first.
    func others(than current: HomeBaseAddress) -> [KnownHouseholds.Entry] {
        known.entries.filter { $0.address != current }
    }
}

/// Every household this phone has joined: tap one to switch, swipe one away to forget it, join another,
/// or forget the current one. Leaving the current household is by `choose` or `forgetCurrent`, which the
/// home runs once this sheet has gone.
struct HouseholdsView: View {
    let current: HomeBaseAddress
    let households: Households
    let choose: (HomeBaseAddress) -> Void
    let forgetCurrent: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForget = false

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
                Section {
                    Button("Forget this household", role: .destructive) { confirmForget = true }
                }
            }
            .confirmationDialog("Forget this household?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget \(households.known.entry(for: current)?.title ?? current.shortName)", role: .destructive) {
                    forgetCurrent()
                    dismiss()
                }
            } message: {
                Text(households.known.entries.count > 1
                    ? "This phone forgets \(current.host) and goes to your next household. Your membership doesn't change."
                    : "This phone forgets \(current.host) and goes back to joining a household. Your membership doesn't change.")
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
