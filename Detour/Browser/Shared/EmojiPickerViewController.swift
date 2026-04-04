import AppKit

class EmojiPickerViewController: NSViewController {
    var onEmojiSelected: ((String) -> Void)?

    private static let columns = 8
    private static let buttonSize: CGFloat = 32
    private static let emojiCategories: [(name: String, emojis: [String])] = [
        ("Smileys", [
            "😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂",
            "🙂", "😉", "😊", "😇", "🥰", "😍", "🤩", "😘",
            "😋", "😛", "😜", "🤪", "😝", "🤑", "🤗", "🤭",
            "🤔", "🫡", "🤐", "😐", "😑", "😶", "🫠", "😏",
            "😒", "🙄", "😬", "😮‍💨", "🤥", "😌", "😔", "😪",
            "🤤", "😴", "😷", "🤒", "🤕", "🤢", "🤮", "🥵",
            "🥶", "🥴", "😵", "🤯", "🤠", "🥳", "🥸", "😎",
            "🤓", "🧐", "😈", "👿", "👹", "👺", "🤡", "💩",
            "👻", "💀", "☠️", "👽", "🤖", "🎃", "😺", "😸",
        ]),
        ("People & Gestures", [
            "👋", "🤚", "🖐️", "✋", "🖖", "🫱", "🫲", "👌",
            "🤌", "🤏", "✌️", "🤞", "🫰", "🤟", "🤘", "🤙",
            "👈", "👉", "👆", "👇", "☝️", "👍", "👎", "✊",
            "👊", "🤛", "🤜", "👏", "🙌", "🫶", "👐", "🤲",
            "🙏", "💪", "🦾", "🧠", "👀", "👁️", "👤", "👥",
            "🧑‍💻", "🧑‍🎨", "🧑‍🚀", "🧑‍🔬", "🧑‍🍳", "🧑‍🔧", "🧑‍🏫", "🧑‍⚕️",
            "🧑‍🚒", "🧑‍✈️", "🧑‍🎤", "🧑‍🏭", "🧑‍💼", "🧑‍🎓", "🧙", "🧛",
            "🧜", "🧝", "🧞", "🧟", "🦸", "🦹", "🥷", "🎅",
        ]),
        ("Animals", [
            "🐶", "🐕", "🐩", "🐺", "🦊", "🦝", "🐱", "🐈",
            "🦁", "🐯", "🐅", "🐆", "🐴", "🦄", "🦓", "🐮",
            "🐂", "🐃", "🐄", "🐷", "🐖", "🐗", "🐏", "🐑",
            "🐐", "🐪", "🐫", "🦙", "🦒", "🐘", "🦣", "🦏",
            "🦛", "🐭", "🐹", "🐰", "🐇", "🐿️", "🦫", "🦔",
            "🐻", "🐻‍❄️", "🐼", "🦥", "🦘", "🦡", "🐸", "🐊",
            "🐢", "🦎", "🐍", "🐉", "🦕", "🦖", "🐙", "🦑",
            "🐳", "🐋", "🐬", "🦭", "🐟", "🦈", "🐠", "🐡",
            "🦋", "🐛", "🐝", "🪲", "🐞", "🦗", "🪳", "🕷️",
            "🐦", "🐧", "🕊️", "🦅", "🦆", "🦢", "🦉", "🦩",
        ]),
        ("Nature", [
            "🌸", "💮", "🏵️", "🌹", "🥀", "🌺", "🌻", "🌼",
            "🌷", "🌱", "🪴", "🌲", "🌳", "🌴", "🌵", "🌾",
            "🍀", "☘️", "🍃", "🍂", "🍁", "🪺", "🪹", "🍄",
            "🌍", "🌎", "🌏", "🌕", "🌖", "🌗", "🌘", "🌑",
            "🌒", "🌓", "🌔", "🌙", "🌚", "🌛", "🌜", "⭐️",
            "🌟", "💫", "✨", "☀️", "🌤️", "⛅️", "🌥️", "☁️",
            "🌦️", "🌧️", "⛈️", "🌩️", "🌈", "❄️", "🌊", "🔥",
        ]),
        ("Food & Drink", [
            "🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓",
            "🫐", "🍈", "🍒", "🍑", "🥭", "🍍", "🥥", "🥝",
            "🥑", "🍆", "🥦", "🥬", "🌶️", "🫑", "🌽", "🥕",
            "🧄", "🧅", "🥔", "🍠", "🫘", "🥜", "🍞", "🥐",
            "🥖", "🫓", "🥨", "🥯", "🧇", "🥞", "🧀", "🍖",
            "🍗", "🥩", "🥓", "🍔", "🍟", "🍕", "🌭", "🥪",
            "🌮", "🌯", "🫔", "🥙", "🧆", "🥚", "🍳", "🥘",
            "🍲", "🫕", "🥣", "🥗", "🍿", "🧈", "🍱", "🍘",
            "🍙", "🍚", "🍛", "🍜", "🍝", "🍣", "🍤", "🍩",
            "🍪", "🎂", "🍰", "🧁", "🥧", "🍫", "🍬", "🍭",
            "🍮", "🍯", "🍼", "🥛", "☕️", "🫖", "🍵", "🧃",
            "🥤", "🧋", "🍺", "🍻", "🥂", "🍷", "🍸", "🍹",
        ]),
        ("Activities", [
            "⚽️", "🏀", "🏈", "⚾️", "🥎", "🎾", "🏐", "🏉",
            "🥏", "🎱", "🪀", "🏓", "🏸", "🏒", "🥊", "🥋",
            "🥅", "⛳️", "⛸️", "🎣", "🎿", "🛷", "🥌", "🎯",
            "🪁", "🏄", "🏊", "🚴", "🏋️", "🤸", "🧗", "🤺",
            "🏇", "⛷️", "🏂", "🪂", "🤿", "🚣", "🧘", "🛹",
            "🎮", "🕹️", "🎲", "🧩", "♟️", "🎰", "🎳", "🎵",
            "🎶", "🎼", "🎹", "🥁", "🪘", "🎷", "🎺", "🪗",
            "🎸", "🎻", "🪕", "🎨", "🎭", "🎬", "📸", "🏆",
        ]),
        ("Travel & Places", [
            "🚗", "🚕", "🚙", "🚌", "🚎", "🏎️", "🚓", "🚑",
            "🚒", "🚐", "🛻", "🚚", "🚛", "🚜", "🏍️", "🛵",
            "🚲", "🛴", "🛺", "🚂", "🚃", "🚄", "🚅", "🚆",
            "🚇", "🚈", "✈️", "🛩️", "🚀", "🛸", "🚁", "🛶",
            "⛵️", "🚤", "🛥️", "🛳️", "⛴️", "🚢", "⚓️", "🪝",
            "🏠", "🏡", "🏢", "🏣", "🏤", "🏥", "🏦", "🏨",
            "🏩", "🏪", "🏫", "🏬", "🏭", "🏯", "🏰", "💒",
            "🗼", "🗽", "⛪️", "🕌", "🛕", "🕍", "⛩️", "🕋",
            "⛲️", "⛺️", "🏕️", "🌁", "🌃", "🏙️", "🌄", "🌅",
            "🌆", "🌇", "🌉", "🎠", "🛝", "🎡", "🎢", "🎪",
            "🗺️", "🗻", "🏔️", "🌋", "🏖️", "🏜️", "🏝️", "🗾",
        ]),
        ("Objects", [
            "💻", "🖥️", "🖨️", "⌨️", "🖱️", "🖲️", "💾", "💿",
            "📱", "☎️", "📟", "📠", "📺", "📻", "🎙️", "🎚️",
            "📷", "📹", "🎥", "📽️", "🎞️", "📀", "🔍", "🔎",
            "💡", "🔦", "🕯️", "🪔", "📔", "📕", "📖", "📗",
            "📘", "📙", "📚", "📓", "📒", "📃", "📄", "📰",
            "🗞️", "📑", "🔖", "🏷️", "✏️", "🖊️", "🖋️", "✒️",
            "📝", "📁", "📂", "🗂️", "📅", "📆", "📇", "📈",
            "📉", "📊", "📋", "📌", "📍", "📎", "🖇️", "✂️",
            "🔑", "🗝️", "🔒", "🔓", "🔐", "🔧", "🪛", "🔩",
            "⚙️", "🧲", "🪜", "🧰", "🛡️", "🗡️", "🔫", "🪃",
            "🎒", "👓", "🕶️", "🥽", "👑", "👒", "🎩", "🧢",
            "💰", "💳", "💎", "🔬", "🔭", "📡", "🪄", "📦",
        ]),
        ("Symbols", [
            "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍",
            "🤎", "💔", "❤️‍🔥", "❤️‍🩹", "💕", "💞", "💓", "💗",
            "💖", "💘", "💝", "💟", "☮️", "✝️", "☪️", "🕉️",
            "☸️", "✡️", "🔯", "🕎", "☯️", "☦️", "🛐", "⛎",
            "♈️", "♉️", "♊️", "♋️", "♌️", "♍️", "♎️", "♏️",
            "♐️", "♑️", "♒️", "♓️", "🆔", "⚛️", "🉑", "☢️",
            "☣️", "📴", "📳", "🈶", "🈚️", "🈸", "🈺", "🈷️",
            "✴️", "🆚", "💮", "🉐", "㊙️", "㊗️", "🈴", "🈵",
            "🈹", "🈲", "🅰️", "🅱️", "🆎", "🆑", "🅾️", "🆘",
            "❌", "⭕️", "🛑", "⛔️", "📛", "🚫", "💯", "💢",
            "♨️", "🚷", "🚯", "🚳", "🚱", "🔞", "📵", "🚭",
            "❗️", "❕", "❓", "❔", "‼️", "⁉️", "💤", "♻️",
            "✅", "☑️", "✔️", "❎", "➕", "➖", "➗", "➰",
            "🏁", "🚩", "🎌", "🏴", "🏳️", "🏳️‍🌈", "🏴‍☠️", "🇺🇸",
        ]),
    ]

    static func showPicker(relativeTo button: NSButton, onSelect: @escaping (String) -> Void) {
        let popover = NSPopover()
        popover.behavior = .transient
        let picker = EmojiPickerViewController()
        picker.onEmojiSelected = { [weak popover] emoji in
            onSelect(emoji)
            popover?.close()
        }
        popover.contentViewController = picker
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    override func loadView() {
        let padding: CGFloat = 12
        let spacing: CGFloat = 2
        let gridWidth = CGFloat(Self.columns) * Self.buttonSize + CGFloat(Self.columns - 1) * spacing
        let contentWidth = gridWidth + padding * 2

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)

        var constraints: [NSLayoutConstraint] = []

        for category in Self.emojiCategories {
            let label = NSTextField(labelWithString: category.name)
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            stack.addArrangedSubview(label)

            let rows = stride(from: 0, to: category.emojis.count, by: Self.columns).map {
                Array(category.emojis[$0..<min($0 + Self.columns, category.emojis.count)])
            }

            for row in rows {
                let rowStack = NSStackView()
                rowStack.orientation = .horizontal
                rowStack.spacing = spacing
                rowStack.translatesAutoresizingMaskIntoConstraints = false

                for emoji in row {
                    let btn = NSButton(title: emoji, target: self, action: #selector(emojiTapped(_:)))
                    btn.bezelStyle = .recessed
                    btn.isBordered = false
                    btn.font = .systemFont(ofSize: 20)
                    btn.translatesAutoresizingMaskIntoConstraints = false
                    constraints.append(btn.widthAnchor.constraint(equalToConstant: Self.buttonSize))
                    constraints.append(btn.heightAnchor.constraint(equalToConstant: Self.buttonSize))
                    rowStack.addArrangedSubview(btn)
                }
                stack.addArrangedSubview(rowStack)
            }
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let clipView = FlippedClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.documentView = stack

        constraints.append(stack.widthAnchor.constraint(equalToConstant: contentWidth))
        NSLayoutConstraint.activate(constraints)

        self.view = scrollView
        preferredContentSize = NSSize(width: contentWidth, height: 400)
    }

    @objc private func emojiTapped(_ sender: NSButton) {
        onEmojiSelected?(sender.title)
    }
}
