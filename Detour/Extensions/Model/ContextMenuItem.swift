import Foundation

/// In-memory representation of a context menu item registered by an extension.
struct ContextMenuItem {
    let id: String
    var title: String
    var contexts: [String]
    var parentId: String?
    var type: String  // "normal", "separator", "checkbox", "radio"
    let extensionID: String
}
