import SwiftUI

/// The tuning sheet: a control for each number in PadTuning, live, with Export and Reset.
/// It walks the tuning's JSON, so a new number in PadTuning shows here with no new code.
struct LabTuningView: View {
    @ObservedObject var model: LabModel
    @State private var stats = ""

    private static let touchDowns: [(String, String, Double)] = [
        ("Soft tick", "soft", 0.35), ("Light tick", "light", 0.5), ("Rigid tick", "rigid", 0.3), ("No tick", "none", 0),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Feel") {
                    Picker("Touch-down", selection: touchDown) {
                        ForEach(Self.touchDowns, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    Picker("Haptics", selection: $model.hapticLevel) {
                        Text("All").tag(PadHaptics.Level.all)
                        Text("Clicks only").tag(PadHaptics.Level.clicksOnly)
                        Text("Off").tag(PadHaptics.Level.off)
                    }
                    Picker("Input mode", selection: $model.inputMode) {
                        Text("Touchscreen").tag(PadInputMode.touchscreen)
                        Text("Volume buttons").tag(PadInputMode.volumeButtons)
                    }
                    Toggle("Pad on the full screen", isOn: $model.full)
                    Toggle("Event log", isOn: $model.showLog)
                }
                Section {
                    Button("Raise the keyboard in 2 s") {
                        model.showTuning = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.keyboard.show() }
                    }
                    Button("Play the first-use stroke") {
                        model.showTuning = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.host?.playGhost(after: 0.3) }
                    }
                }
                Section("Frame time") {
                    Text(stats.isEmpty ? "No frames yet" : stats).font(.footnote.monospacedDigit())
                    Button("Reset the counts") { model.host?.surface.resetStats(); stats = model.statsText }
                }
                ForEach(sections, id: \.self) { s in
                    Section(s) {
                        ForEach(keys(s), id: \.self) { k in row(s, k) }
                    }
                }
                Section {
                    Button("Export") { model.export() }
                    if !model.saved.isEmpty { Text(model.saved).font(.footnote) }
                    Button("Reset to the defaults", role: .destructive) { model.reset() }
                }
            }
            .navigationTitle("Tuning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.showTuning = false } } }
            .onAppear { stats = model.statsText }
        }
        .presentationDetents([.medium, .large])
    }

    private var touchDown: Binding<String> {
        Binding(get: { model.tuning.haptics.touchDown }, set: { v in
            model.tuning.haptics.touchDown = v
            if let e = Self.touchDowns.first(where: { $0.1 == v }), v != "none" { model.tuning.haptics.touchDownIntensity = e.2 }
        })
    }

    // MARK: The JSON walk

    private var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(model.tuning))) as? [String: Any] ?? [:]
    }

    /// In the struct's own order.
    private var sections: [String] { Mirror(reflecting: model.tuning).children.compactMap(\.label) }

    private func keys(_ section: String) -> [String] {
        guard let child = Mirror(reflecting: model.tuning).children.first(where: { $0.label == section }) else { return [] }
        var out: [String] = []
        for c in Mirror(reflecting: child.value).children {
            guard let l = c.label else { continue }
            if c.value is PadTuning.Haptics.Event { out += ["\(l).style", "\(l).intensity"] } else { out.append(l) }
        }
        return out
    }

    private func value(_ s: String, _ k: String) -> Any? {
        let parts = k.split(separator: ".").map(String.init)
        var v: Any? = (json[s] as? [String: Any])?[parts[0]]
        if parts.count > 1 { v = (v as? [String: Any])?[parts[1]] }
        return v
    }

    private func set(_ s: String, _ k: String, _ v: Any) {
        var j = json
        var sec = j[s] as? [String: Any] ?? [:]
        let parts = k.split(separator: ".").map(String.init)
        if parts.count > 1 {
            var inner = sec[parts[0]] as? [String: Any] ?? [:]
            inner[parts[1]] = v
            sec[parts[0]] = inner
        } else {
            sec[parts[0]] = v
        }
        j[s] = sec
        if let d = try? JSONSerialization.data(withJSONObject: j), let t = try? PadTuning.load(d) { model.tuning = t }
    }

    private func defaultValue(_ s: String, _ k: String) -> Double {
        let d = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(PadTuning()))) as? [String: Any] ?? [:]
        let parts = k.split(separator: ".").map(String.init)
        var v: Any? = (d[s] as? [String: Any])?[parts[0]]
        if parts.count > 1 { v = (v as? [String: Any])?[parts[1]] }
        return (v as? NSNumber)?.doubleValue ?? 1
    }

    @ViewBuilder private func row(_ s: String, _ k: String) -> some View {
        if let n = value(s, k) as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let top = max(defaultValue(s, k) * 3, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(k).font(.footnote)
                    Spacer()
                    TextField("", value: Binding(get: { n.doubleValue }, set: { set(s, k, $0) }), format: .number.precision(.significantDigits(1...5)))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .font(.footnote.monospacedDigit())
                        .frame(width: 90)
                }
                Slider(value: Binding(get: { n.doubleValue }, set: { set(s, k, $0) }), in: 0...max(top, n.doubleValue))
            }
        } else if let str = value(s, k) as? String {
            HStack {
                Text(k).font(.footnote)
                Spacer()
                TextField("", text: Binding(get: { str }, set: { set(s, k, $0) }))
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.footnote.monospaced())
            }
        }
    }
}
