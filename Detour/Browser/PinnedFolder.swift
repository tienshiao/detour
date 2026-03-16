import Foundation

class PinnedFolder {
    let id: UUID
    var name: String
    var parentFolderID: UUID?
    var isCollapsed: Bool
    var sortOrder: Int

    init(id: UUID = UUID(), name: String, parentFolderID: UUID? = nil, isCollapsed: Bool = false, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.parentFolderID = parentFolderID
        self.isCollapsed = isCollapsed
        self.sortOrder = sortOrder
    }
}
