import AppKit

/// Whether to reduce motion: the system's Reduce Motion setting, which every
/// animation that honours it reads here.
///
/// A Debug build can override it for this process (`reduceMotionOverride`),
/// so the automation endpoint can check the reduced animations without
/// changing the system-wide setting, which is protected (TASK-228.1). A
/// Release build has no override and always follows the system.
enum MotionPreference {

    static var reduceMotion: Bool {
        #if DEBUG
        if let reduceMotionOverride { return reduceMotionOverride }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    #if DEBUG
    /// Debug only: true or false wins over the system setting; nil follows it.
    static var reduceMotionOverride: Bool?
    #endif
}
