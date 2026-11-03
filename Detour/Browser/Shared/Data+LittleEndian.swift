import Foundation

/// Little-endian `UInt32` fields read and written one byte at a time through
/// `Data`'s bounds-checked subscript, for the two formats that carry them in
/// bytes from outside the app: the CRX3 container header (a download) and
/// Chrome's native-messaging length prefix (another process's stdout).
///
/// These replace `withUnsafeBytes { $0.load(as: UInt32.self) }` and
/// `Data(bytes: &value, count: 4)`, which strict memory safety checking
/// (SE-0458) flags: a raw-pointer load reads whatever the buffer holds past
/// its end, and `load(as:)` also traps on a misaligned address. Here a short
/// buffer is a nil, never a read out of bounds (TASK-231.8).
extension Data {

    /// The four bytes at `offset` (counted from `startIndex`, so a slice reads
    /// its own bytes) as a little-endian `UInt32`; nil when fewer than four
    /// bytes are there.
    nonisolated func littleEndianUInt32(at offset: Int = 0) -> UInt32? {
        guard offset >= 0, offset <= count - 4 else { return nil }
        let i = startIndex + offset
        return UInt32(self[i])
            | UInt32(self[i + 1]) << 8
            | UInt32(self[i + 2]) << 16
            | UInt32(self[i + 3]) << 24
    }

    /// The four little-endian bytes of `value`.
    nonisolated init(littleEndianBytesOf value: UInt32) {
        self.init([
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ])
    }
}
