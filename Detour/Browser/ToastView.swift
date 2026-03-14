import AppKit

class ToastManager {
    weak var parentView: NSView?
    private var currentToast: ToastView?
    private var hideGeneration = 0

    func show(message: String) {
        guard let parent = parentView else { return }

        currentToast?.removeFromSuperview()

        let toast = ToastView()
        toast.label.stringValue = message
        toast.alphaValue = 0
        parent.addSubview(toast)
        currentToast = toast

        NSLayoutConstraint.activate([
            toast.topAnchor.constraint(equalTo: parent.topAnchor, constant: 12),
            toast.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -12),
        ])

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            toast.animator().alphaValue = 1
        }

        hideGeneration &+= 1
        let gen = hideGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.hideGeneration == gen else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                toast.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.hideGeneration == gen else { return }
                toast.removeFromSuperview()
                if self.currentToast === toast { self.currentToast = nil }
            })
        }
    }
}

class ToastView: NSView {
    fileprivate let label = NSTextField(labelWithString: "")
    private var effectView: NSVisualEffectView!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 0.5
        effectView.layer?.borderColor = NSColor.separatorColor.cgColor
        effectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)

        wantsLayer = true
        shadow = NSShadow()
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow?.shadowOffset = NSSize(width: 0, height: -2)
        shadow?.shadowBlurRadius = 8
        layer?.shadowRadius = 8
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.25).cgColor
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        layer?.shadowOpacity = 1

        label.font = .boldSystemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(label)

        translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -14),
        ])
    }

    override func layout() {
        super.layout()
        effectView.layer?.cornerRadius = bounds.height / 2
    }
}
