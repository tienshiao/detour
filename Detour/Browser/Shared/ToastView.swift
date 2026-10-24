import AppKit

class ToastManager {
    weak var parentView: NSView?
    static let defaultTopInset: CGFloat = 12
    static let trailingInset: CGFloat = 12
    /// How far below the parent's top the toast sits, given its size; read
    /// when it shows.
    var topInset: (NSSize) -> CGFloat = { _ in ToastManager.defaultTopInset }
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
            toast.topAnchor.constraint(equalTo: parent.topAnchor, constant: topInset(toast.fittingSize)),
            toast.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Self.trailingInset),
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
    private let glassContainer = GlassContainerView(cornerRadius: .infinity)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        label.font = .boldSystemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        translatesAutoresizingMaskIntoConstraints = false

        glassContainer.contentView.addSubview(label)
        addSubview(glassContainer)

        NSLayoutConstraint.activate([
            glassContainer.topAnchor.constraint(equalTo: topAnchor),
            glassContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            glassContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassContainer.trailingAnchor.constraint(equalTo: trailingAnchor),

            label.topAnchor.constraint(equalTo: glassContainer.contentView.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: glassContainer.contentView.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: glassContainer.contentView.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: glassContainer.contentView.trailingAnchor, constant: -14),
        ])
    }
}
