import SwiftUI

/// Terminal state after the engine has released the previous guest (a Linux machine).
struct StoppedMachineView: View {
    let outcome: Int32
    let reason: String
    var start: (() -> Void)? = nil
    let close: () -> Void

    private var stop: StopKind {
        switch outcome {
        case Int32(HENGE_VM_OUTCOME_SHUTDOWN.rawValue): return .shutdown
        case Int32(HENGE_VM_OUTCOME_RESTART.rawValue): return .restart
        case Int32(HENGE_VM_OUTCOME_HOST_STOP.rawValue): return .hostStop
        default: return .error
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "power").font(.system(size: 30))
            Text(StopText.title(stop)).font(.headline)
            Text(StopText.detail(stop, reason: reason)).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            if let start { Button(StopText.startLabel, action: start).buttonStyle(.borderedProminent) }
            Button("Close", action: close).buttonStyle(.bordered)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 360)
        .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 22))
        .accessibilityIdentifier("stopped-machine")
    }
}
