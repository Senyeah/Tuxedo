// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// Type a machine's memory in GB, or step it by half a GB. A size that does not pass MemoryAmount.parse is
/// not applied: the field says why, and goes back to the machine's size when it loses focus.
struct MemoryField: View {
    @Binding var mb: Int
    /// Runs when a size is final: a step, Return, or the field losing focus.
    var commit: () -> Void = {}

    @State private var text = ""
    @State private var problem: MemoryAmount.Problem?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Memory").font(.system(size: 16))
                Spacer()
                TextField("2", text: $text)
                    .font(.system(size: 16, weight: .semibold))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focused)
                    .frame(width: 56)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Desk.dim.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Desk.bad, lineWidth: problem == nil ? 0 : 1.5))
                    .accessibilityLabel("Memory in GB")
                Text("GB").font(.system(size: 16, weight: .semibold))
                Stepper("Memory", onIncrement: { step(MemoryAmount.stepMB) }, onDecrement: { step(-MemoryAmount.stepMB) })
                    .labelsHidden()
            }
            if let problem {
                Text(problem.message).font(.system(size: 13)).foregroundStyle(Desk.bad)
            }
        }
        .onAppear { text = MemoryAmount.text(mb) }
        .onChange(of: text) { _, new in
            switch MemoryAmount.parse(new) {
            case .success(let value):
                problem = nil
                if value != mb { mb = value }
            case .failure(let why):
                problem = why
            }
        }
        .onChange(of: mb) { _, new in
            if case .success(let typed) = MemoryAmount.parse(text), typed == new { return }
            text = MemoryAmount.text(new)
            problem = nil
        }
        .onChange(of: focused) { _, now in
            guard !now else { return }
            text = MemoryAmount.text(mb)
            problem = nil
            commit()
        }
        .onSubmit { focused = false }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }
            }
        }
    }

    private func step(_ delta: Int) {
        mb = MemoryAmount.clamped(mb + delta)
        text = MemoryAmount.text(mb)
        problem = nil
        commit()
    }
}
