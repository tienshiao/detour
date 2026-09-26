import Foundation

/// An extension manifest `version`, ordered the way Chrome orders them
/// (`base::Version`): one to four dot-separated non-negative integers, compared
/// component by component with missing trailing components read as 0 — so
/// "1.2" == "1.2.0" and "1.10" > "1.9". Anything else does not parse; an
/// unparsable candidate version can never count as newer (TASK-113).
struct ExtensionVersion: Equatable, Comparable, CustomStringConvertible {
    let components: [UInt32]
    let description: String

    init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var components: [UInt32] = []
        for part in parts {
            // Digits only: no signs, whitespace or exponents, which UInt32(_:)
            // would otherwise accept in some forms. Chrome caps components at
            // 65535 but accepts any 32-bit value in practice; the cap here is
            // "fits in a UInt32", which is what matters for ordering.
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = UInt32(part) else { return nil }
            components.append(value)
        }
        self.components = components
        self.description = string
    }

    static func == (lhs: ExtensionVersion, rhs: ExtensionVersion) -> Bool {
        compare(lhs, rhs) == 0
    }

    static func < (lhs: ExtensionVersion, rhs: ExtensionVersion) -> Bool {
        compare(lhs, rhs) < 0
    }

    private static func compare(_ lhs: ExtensionVersion, _ rhs: ExtensionVersion) -> Int {
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    /// Whether `candidate` is a strictly newer version than `installed`. False
    /// when either does not parse: an update can only be taken on a version both
    /// sides can order.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let c = ExtensionVersion(candidate), let i = ExtensionVersion(installed) else { return false }
        return c > i
    }
}
