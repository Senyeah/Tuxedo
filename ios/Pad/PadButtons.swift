import UIKit

/// The two keys. They take touches in their own views, so a finger on a key is never a pad
/// contact; elsewhere touches pass through to the pad. The look of a key (fill, edge, press)
/// is in the shader; these views carry the symbols, the labels and accessibility.
final class PadButtons: UIView {
    /// A key's press (true) and release.
    var onKey: ((Int, Bool) -> Void)?
    /// VoiceOver's "Hold" on the left key.
    var onHold: ((Bool) -> Void)?

    private(set) var keys: [KeyView] = []
    private let clip = CALayer()
    var tuning: PadTuning { didSet { restyle() } }
    var labels = false { didSet { if labels != oldValue { restyle() } } }
    var increaseContrast = false { didSet { if increaseContrast != oldValue { restyle() } } }

    init(tuning: PadTuning) {
        self.tuning = tuning
        super.init(frame: .zero)
        backgroundColor = .clear
        clip.backgroundColor = UIColor.black.cgColor
        layer.mask = clip
        keys = [KeyView(button: 0), KeyView(button: 1)]
        for k in keys {
            k.onPress = { [weak self] b, down in self?.onKey?(b, down) }
            k.onHold = { [weak self] held in self?.onHold?(held) }
            addSubview(k)
        }
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("made in code") }

    private func restyle() {
        let k = tuning.keys
        keys[0].style(symbol: k.leftSymbol, title: "Click", size: k.symbolSize, labels: labels)
        keys[1].style(symbol: k.rightSymbol, title: "Right-click", size: k.symbolSize, labels: labels)
        for key in keys { key.rest = increaseContrast ? tuning.contrast.symbolAlpha : k.symbolAlpha }
    }

    func apply(_ l: PadLayout) {
        keys[0].frame = CGRect(x: l.leftNow.x, y: l.leftNow.y, width: l.leftNow.w, height: l.leftNow.h)
        keys[1].frame = CGRect(x: l.rightNow.x, y: l.rightNow.y, width: l.rightNow.w, height: l.rightNow.h)
        alpha = CGFloat(l.keysOpacity)
        // Nothing of a key shows below the pad's edge, where the keyboard's row has gaps.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = CGRect(x: 0, y: 0, width: bounds.width, height: CGFloat(l.padBottom))
        CATransaction.commit()
        isUserInteractionEnabled = l.keysTakeTouches
        // Hidden keys are not accessibility elements.
        accessibilityElementsHidden = !l.keysTakeTouches
    }

    /// The press level from 0 to 1, as the shader draws it.
    func setPress(_ b: Int, _ level: Double) { keys[b].level = level }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        keys.contains { $0.frame.contains(point) }
    }

    final class KeyView: UIView {
        let button: Int
        var onPress: ((Int, Bool) -> Void)?
        var onHold: ((Bool) -> Void)?
        var rest = 0.6 { didSet { shade() } }
        var level = 0.0 { didSet { shade() } }
        private func shade() {
            let a = CGFloat(rest + (1 - rest) * min(max(level, 0), 1))
            symbol.alpha = a
            label.alpha = a
        }
        private let symbol = UIImageView()
        private let label = UILabel()
        private let stack = UIStackView()
        private var touch: UITouch?
        private var held = false

        init(button: Int) {
            self.button = button
            super.init(frame: .zero)
            isMultipleTouchEnabled = false
            backgroundColor = .clear
            symbol.tintColor = .white
            symbol.contentMode = .center
            label.textColor = .white
            label.font = .preferredFont(forTextStyle: .caption1)
            label.adjustsFontForContentSizeCategory = true
            label.textAlignment = .center
            label.numberOfLines = 1
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.7
            stack.axis = .vertical
            stack.alignment = .center
            stack.spacing = 2
            stack.isUserInteractionEnabled = false
            stack.addArrangedSubview(symbol)
            stack.addArrangedSubview(label)
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16),
            ])
            maximumContentSizeCategory = .accessibilityLarge
            isAccessibilityElement = true
            accessibilityTraits = .button
            if button == 0 {
                accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Hold") { [weak self] _ in self?.toggleHold() ?? false }]
            }
            level = 0
        }

        required init?(coder: NSCoder) { fatalError("made in code") }

        func style(symbol name: String, title: String, size: Double, labels: Bool) {
            symbol.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: CGFloat(size), weight: .medium))
            label.text = title
            label.isHidden = !labels
            accessibilityLabel = title
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard touch == nil, let t = touches.first else { return }
            touch = t
            onPress?(button, true)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { end(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { end(touches) }

        private func end(_ touches: Set<UITouch>) {
            guard let t = touch, touches.contains(t) else { return }
            touch = nil
            onPress?(button, false)
        }

        /// A VoiceOver double tap: down then up.
        override func accessibilityActivate() -> Bool {
            onPress?(button, true)
            onPress?(button, false)
            return true
        }

        private func toggleHold() -> Bool {
            held.toggle()
            onHold?(held)
            accessibilityValue = held ? "Held" : nil
            accessibilityCustomActions = [UIAccessibilityCustomAction(name: held ? "Release" : "Hold") { [weak self] _ in self?.toggleHold() ?? false }]
            return true
        }
    }
}
