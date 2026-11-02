import UIKit

/// Terminal keyboard accessory: Esc / Tab / Ctrl-chord / arrows / symbols.
/// Glass bar, monospace keys, no labels beyond glyphs.
final class KeyboardAccessoryView: UIInputView {

    var onSend: ([UInt8]) -> Void = { _ in }

    private var ctrlActive = false
    private var ctrlButton: KeyButton?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44), inputViewStyle: .keyboard)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        backgroundColor = .clear
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
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
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -5),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -10)
        ])

        stack.addArrangedSubview(key("esc", glyph: "escape") { [weak self] in self?.emit([0x1B]) })
        let ctrl = key("ctrl", glyph: "control") { [weak self] in self?.toggleCtrl() }
        ctrlButton = ctrl
        stack.addArrangedSubview(ctrl)
        stack.addArrangedSubview(key("tab", glyph: "arrow.right.to.line") { [weak self] in self?.emit([0x09]) })

        stack.addArrangedSubview(sep())

        for symbol in ["|", "/", "-", "~", "_", "=", "`", "$", "&", "*"] {
            stack.addArrangedSubview(key(symbol) { [weak self] in self?.emitString(symbol) })
        }

        stack.addArrangedSubview(sep())

        stack.addArrangedSubview(key("home", glyph: "arrowtriangle.left.fill") { [weak self] in self?.emitCSI("H") })
        stack.addArrangedSubview(key("up", glyph: "chevron.up") { [weak self] in self?.emitArrow("A") })
        stack.addArrangedSubview(key("down", glyph: "chevron.down") { [weak self] in self?.emitArrow("B") })
        stack.addArrangedSubview(key("left", glyph: "chevron.left") { [weak self] in self?.emitArrow("D") })
        stack.addArrangedSubview(key("right", glyph: "chevron.right") { [weak self] in self?.emitArrow("C") })
        stack.addArrangedSubview(key("end", glyph: "arrowtriangle.right.fill") { [weak self] in self?.emitCSI("F") })

        stack.addArrangedSubview(sep())

        // Ctrl chord row — letters send control bytes while ctrl is held
        for letter in ["c", "d", "z", "l", "a", "e", "k", "u", "w", "r", "x"] {
            stack.addArrangedSubview(key(letter) { [weak self] in self?.emitLetter(letter) })
        }
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
            view.heightAnchor.constraint(equalToConstant: 22)
        ])
        return view
    }

    private func toggleCtrl() {
        ctrlActive.toggle()
        ctrlButton?.isToggled = ctrlActive
        Haptics.select()
    }

    private func emit(_ bytes: [UInt8]) {
        onSend(bytes)
    }

    private func emitString(_ s: String) {
        onSend([UInt8](s.utf8))
    }

    private func emitLetter(_ letter: String) {
        guard let byte = letter.utf8.first else { return }
        if ctrlActive {
            onSend([byte & 0x1f])
            toggleCtrl()
        } else {
            onSend([byte])
        }
    }

    private func emitArrow(_ code: String) {
        if ctrlActive {
            emitString("\u{1B}[1;5\(code)")
            toggleCtrl()
        } else {
            emitString("\u{1B}[\(code)")
        }
    }

    private func emitCSI(_ code: String) {
        emitString("\u{1B}[\(code)")
    }
}

/// A single accessory key — squircle chip, monospace, pressed animation.
final class KeyButton: UIControl {
    var onTap: () -> Void = {}
    var isToggled = false {
        didSet { updateStyle() }
    }

    private let label = UILabel()

    init(title: String, glyph: String? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UIColor.white.withAlphaComponent(0.08)
        layer.cornerRadius = 7
        layer.cornerCurve = .continuous

        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        label.textAlignment = .center
        label.isUserInteractionEnabled = false
        addSubview(label)

        if let glyph, let image = UIImage(systemName: glyph) {
            let imageView = UIImageView(image: image)
            imageView.tintColor = .white
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
            label.text = title
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 34),
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
            backgroundColor = UIColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 0.35)
        } else {
            backgroundColor = isHighlighted
                ? UIColor.white.withAlphaComponent(0.25)
                : UIColor.white.withAlphaComponent(0.08)
        }
    }

    @objc private func tapped() {
        onTap()
    }
}
