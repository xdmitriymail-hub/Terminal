import UIKit

/// Sticky Ctrl / Alt state shared between the accessory bar and the
/// terminal input path: tapping Ctrl, then a letter, sends a control
/// byte; Alt sends an ESC prefix (Meta).
final class ModifierState {
    private(set) var ctrl = false
    private(set) var alt = false
    var onChange: () -> Void = {}

    func toggleCtrl() { ctrl.toggle(); alt = false; onChange() }
    func toggleAlt() { alt.toggle(); ctrl = false; onChange() }

    /// Applies the held modifiers to typed bytes. One-shot: modifiers
    /// reset after a single key, like a hardware chord.
    func apply(to bytes: [UInt8]) -> [UInt8] {
        if ctrl {
            let out = bytes.map { $0 & 0x1f }
            reset()
            return out
        }
        if alt {
            var out: [UInt8] = [0x1B]
            out.append(contentsOf: bytes)
            reset()
            return out
        }
        return bytes
    }

    /// Escape-sequence variant for special keys (arrows etc.) that are
    /// already CSI — Ctrl+arrow becomes CSI 1;5X.
    func arrow(_ code: String) -> [UInt8] {
        let seq = ctrl ? "\u{1B}[1;5\(code)" : "\u{1B}[\(code)"
        reset()
        return [UInt8](seq.utf8)
    }

    func reset() {
        guard ctrl || alt else { return }
        ctrl = false
        alt = false
        onChange()
    }
}

/// Terminal keyboard bar: modifier keys, arrows, symbols, hide button.
/// Material adapts to light/dark; flush with the keyboard — no gaps.
final class KeyboardAccessoryView: UIInputView {

    /// Injected by the session so sticky state survives bar rebuilds.
    var modifiers = ModifierState()
    var onSend: ([UInt8]) -> Void = { _ in }

    private var ctrlButton: KeyButton?
    private var altButton: KeyButton?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 46), inputViewStyle: .keyboard)
        accessibilityIdentifier = "keyboardAccessory"
        modifiers.onChange = { [weak self] in self?.syncModifiers() }
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        backgroundColor = .clear
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: blur.contentView.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor)
        ])

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -6),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -12)
        ])

        stack.addArrangedSubview(key("esc") { [weak self] in self?.emit([0x1B]) })
        let ctrl = key("ctrl") { [weak self] in self?.modifiers.toggleCtrl(); Haptics.select() }
        ctrlButton = ctrl
        stack.addArrangedSubview(ctrl)
        let alt = key("alt") { [weak self] in self?.modifiers.toggleAlt(); Haptics.select() }
        altButton = alt
        stack.addArrangedSubview(alt)
        stack.addArrangedSubview(key("tab", glyph: "arrow.right.to.line") { [weak self] in self?.emit([0x09]) })

        stack.addArrangedSubview(sep())

        stack.addArrangedSubview(key("left", glyph: "chevron.left") { [weak self] in self?.emitArrow("D") })
        stack.addArrangedSubview(key("down", glyph: "chevron.down") { [weak self] in self?.emitArrow("B") })
        stack.addArrangedSubview(key("up", glyph: "chevron.up") { [weak self] in self?.emitArrow("A") })
        stack.addArrangedSubview(key("right", glyph: "chevron.right") { [weak self] in self?.emitArrow("C") })

        stack.addArrangedSubview(sep())

        for symbol in ["`", "|", "/", "-", "~", "_", "=", "&", "$"] {
            stack.addArrangedSubview(key(symbol) { [weak self] in self?.emitString(symbol) })
        }

        stack.addArrangedSubview(sep())

        stack.addArrangedSubview(key("home", glyph: "arrowtriangle.left.fill") { [weak self] in self?.emitString("\u{1B}[H") })
        stack.addArrangedSubview(key("end", glyph: "arrowtriangle.right.fill") { [weak self] in self?.emitString("\u{1B}[F") })

        stack.addArrangedSubview(sep())

        stack.addArrangedSubview(key("hide", glyph: "keyboard.chevron.compact.down") {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        })
    }

    private func key(_ title: String, glyph: String? = nil, action: @escaping () -> Void) -> KeyButton {
        let button = KeyButton(title: title, glyph: glyph)
        button.onTap = action
        return button
    }

    private func sep() -> UIView {
        let view = UIView()
        view.backgroundColor = .separator
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 0.5),
            view.heightAnchor.constraint(equalToConstant: 24)
        ])
        return view
    }

    private func syncModifiers() {
        ctrlButton?.isToggled = modifiers.ctrl
        altButton?.isToggled = modifiers.alt
    }

    private func emit(_ bytes: [UInt8]) {
        modifiers.reset()
        onSend(bytes)
    }

    private func emitString(_ s: String) {
        modifiers.reset()
        onSend([UInt8](s.utf8))
    }

    private func emitArrow(_ code: String) {
        onSend(modifiers.arrow(code))
    }
}

/// A single accessory key — keycap chip, adapts to light/dark.
final class KeyButton: UIControl {
    var onTap: () -> Void = {}
    var isToggled = false {
        didSet { updateStyle() }
    }

    private static let fill = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.12)
            : UIColor.white.withAlphaComponent(0.85)
    }
    private static let fillPressed = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.28)
            : UIColor.white.withAlphaComponent(0.45)
    }

    init(title: String, glyph: String? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = Self.fill
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: 0, height: 1)

        if let glyph, let image = UIImage(systemName: glyph) {
            let imageView = UIImageView(image: image)
            imageView.tintColor = .label
            imageView.contentMode = .scaleAspectFit
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.isUserInteractionEnabled = false
            addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
                imageView.heightAnchor.constraint(equalToConstant: 15)
            ])
        } else {
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.textColor = .label
            label.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
            label.textAlignment = .center
            label.text = title
            label.isUserInteractionEnabled = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 38),
            heightAnchor.constraint(equalToConstant: 34)
        ])

        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.08) { self.updateStyle() }
        }
    }

    private func updateStyle() {
        if isToggled {
            backgroundColor = UIColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 0.4)
        } else {
            backgroundColor = isHighlighted ? Self.fillPressed : Self.fill
        }
    }

    @objc private func tapped() {
        onTap()
    }
}
