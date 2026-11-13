import SwiftUI

/// The Lab's stand-in for the guest: a pointer that the pad moves, a box to drag, a list to
/// scroll with two fingers, so that the owner can judge the feel.
final class LabPointer: ObservableObject {
    @Published var position = CGPoint(x: 160, y: 120)
    @Published var box = CGRect(x: 40, y: 60, width: 72, height: 72)
    @Published var scroll: CGFloat = 0
    @Published var left = false
    @Published var right = false
    @Published var clicks = 0
    @Published var menu: CGPoint?
    @Published var typed = ""
    var size = CGSize(width: 320, height: 240)
    var gain: CGFloat = 1.4
    private var grabbed = false

    func move(_ dx: CGFloat, _ dy: CGFloat) {
        let p = CGPoint(x: min(max(position.x + dx * gain, 0), size.width), y: min(max(position.y + dy * gain, 0), size.height))
        if grabbed {
            box.origin.x += p.x - position.x
            box.origin.y += p.y - position.y
        }
        position = p
    }

    func scroll(by dy: CGFloat) { scroll = min(max(scroll + dy * gain, -600), 0) }

    func button(_ b: Int, _ down: Bool) {
        if b == 0 {
            left = down
            if down {
                clicks += 1
                menu = nil
                grabbed = box.insetBy(dx: -6, dy: -6).contains(position)
            } else {
                grabbed = false
            }
        } else {
            right = down
            if down { menu = position }
        }
    }
}

struct LabPointerView: View {
    @ObservedObject var pointer: LabPointer
    var log: [String]
    var showLog: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.09))
                list(geo.size)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(pointer.left && pointer.box.contains(pointer.position) ? Color(red: 0.18, green: 0.42, blue: 1) : Color(white: 0.22))
                    .frame(width: pointer.box.width, height: pointer.box.height)
                    .offset(x: pointer.box.minX, y: pointer.box.minY)
                if let m = pointer.menu {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Copy"); Text("Paste"); Text("Inspect")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.2)))
                    .offset(x: m.x + 4, y: m.y + 4)
                }
                Circle()
                    .stroke(Color.white.opacity(pointer.left ? 0.8 : 0), lineWidth: 2)
                    .frame(width: 26, height: 26)
                    .offset(x: pointer.position.x - 13, y: pointer.position.y - 13)
                Image(systemName: "cursorarrow")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .offset(x: pointer.position.x - 5, y: pointer.position.y - 3)
                if !pointer.typed.isEmpty {
                    Text(pointer.typed.suffix(40))
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(10)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                if showLog {
                    VStack(alignment: .trailing, spacing: 1) {
                        ForEach(Array(log.suffix(8).enumerated()), id: \.offset) { Text($0.element) }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onAppear { pointer.size = geo.size }
            .onChange(of: geo.size) { _, s in pointer.size = s }
        }
    }

    private func list(_ size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<40) { i in
                Text("Row \(i + 1)")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(height: 28)
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            }
        }
        .frame(width: size.width * 0.38, alignment: .leading)
        .offset(x: size.width * 0.58, y: pointer.scroll + 10)
    }
}
