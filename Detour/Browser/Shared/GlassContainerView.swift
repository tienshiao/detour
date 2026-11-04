import AppKit

class GlassContainerView: NSView {
    let contentView = NSView()
    private var effectView: NSVisualEffectView?
    private var glassView: NSView?

    /// Tints the glass. Liquid Glass takes its brightness from what is behind
    /// it, so a palette alone in a transparent panel over a light window reads
    /// light even in dark mode; a tint that follows the appearance keeps it
    /// dark there (TASK-193.1). Nil leaves the glass as it is.
    var tintColor: NSColor? {
        didSet {
            if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView {
                glass.tintColor = tintColor
            } else {
                effectView?.layer?.backgroundColor = tintColor?.cgColor
            }
        }
    }
    private var _cornerRadius: CGFloat

    var cornerRadius: CGFloat {
        get { _cornerRadius }
        set {
            _cornerRadius = newValue
            needsLayout = true
        }
    }

    init(cornerRadius: CGFloat = 12) {
        self._cornerRadius = cornerRadius
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = _cornerRadius
            glass.translatesAutoresizingMaskIntoConstraints = false
            glass.contentView = contentView
            addSubview(glass)
            glassView = glass

            NSLayoutConstraint.activate([
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor),
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        } else {
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            shadow = NSShadow()
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.5
            layer?.shadowOffset = CGSize(width: 0, height: -2)
            layer?.shadowRadius = 20

            let vev = NSVisualEffectView()
            vev.material = .hudWindow
            vev.blendingMode = .withinWindow
            vev.state = .active
            vev.wantsLayer = true
            vev.layer?.masksToBounds = true
            vev.layer?.borderWidth = 0.5
            vev.layer?.borderColor = NSColor.separatorColor.cgColor
            vev.translatesAutoresizingMaskIntoConstraints = false
            addSubview(vev)
            vev.addSubview(contentView)
            self.effectView = vev

            NSLayoutConstraint.activate([
                vev.topAnchor.constraint(equalTo: topAnchor),
                vev.bottomAnchor.constraint(equalTo: bottomAnchor),
                vev.leadingAnchor.constraint(equalTo: leadingAnchor),
                vev.trailingAnchor.constraint(equalTo: trailingAnchor),

                contentView.topAnchor.constraint(equalTo: vev.topAnchor),
                contentView.bottomAnchor.constraint(equalTo: vev.bottomAnchor),
                contentView.leadingAnchor.constraint(equalTo: vev.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: vev.trailingAnchor),
            ])
        }
    }

    override func layout() {
        super.layout()
        if _cornerRadius == .infinity {
            effectView?.layer?.cornerRadius = bounds.height / 2
        } else {
            effectView?.layer?.cornerRadius = _cornerRadius
        }
    }
}
