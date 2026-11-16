// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// Machines whose first start opens Tuxedo Additions, asked for by the prompt on the Installed screen.
@MainActor
enum SetupHint {
    private static var ids: Set<UUID> = []

    static func request(_ id: UUID) { ids.insert(id) }

    /// True once for a machine that asked.
    static func take(_ id: UUID) -> Bool { ids.remove(id) != nil }
}

/// The glass card that rises from the bottom of the Installed screen and offers the wizard.
struct SetupPrompt: View {
    let name: String
    /// nil when the machine can start; else why not.
    let blocker: String?
    let setUp: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "wand.and.sparkles")
                    .font(.system(size: 26, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Desk.accentLight)
                    .frame(width: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up \(name)")
                        .font(.system(size: 20, weight: .bold))
                    Text("Tuxedo Additions makes your account, then adds a desktop and apps. It opens as soon as the machine starts.")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            primary
            if let blocker {
                Text(blocker).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button("Not now", action: dismiss)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .padding(.vertical, 2)
        }
        .padding(20)
        .deskGlass(in: .rect(cornerRadius: 32))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var primary: some View {
        let button = Button(action: setUp) {
            Text("Start and set up").font(.system(size: 17, weight: .bold)).frame(maxWidth: .infinity)
        }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            button.buttonStyle(.glassProminent).tint(Desk.accent).controlSize(.large)
                .disabled(blocker != nil)
                .accessibilityHint("Starts the machine and opens Tuxedo Additions")
        } else {
            button.buttonStyle(DeskButtonStyle(enabled: blocker == nil)).disabled(blocker != nil)
        }
        #else
        button.buttonStyle(DeskButtonStyle(enabled: blocker == nil)).disabled(blocker != nil)
        #endif
    }
}
