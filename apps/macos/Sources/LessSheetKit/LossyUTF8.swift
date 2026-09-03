import Foundation

public extension String {
    /// Decodes borrowed core bytes as UTF-8, substituting U+FFFD for any invalid
    /// sequence. The single display-boundary decoder for every cell, label and
    /// copy string that originates in the core: the core's UTF-8 path hands back
    /// raw, un-validated file bytes and places the substitution obligation on the
    /// consumer (`api/lesssheet.h`, "Option A").
    ///
    /// The failable `String(bytes:encoding:)` the `optional_data_string_conversion`
    /// rule prefers returns nil on invalid input, so `?? ""` there would silently
    /// discard the whole cell — a data-loss bug. Hence the one disable below.
    init(lossyUTF8 bytes: some Collection<UInt8>) {
        // swiftlint:disable:next optional_data_string_conversion
        self = String(decoding: bytes, as: UTF8.self)
    }
}
