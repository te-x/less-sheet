import Foundation

public extension String {
    /// Decodes borrowed core bytes as UTF-8, substituting the Unicode
    /// replacement character (U+FFFD) for any invalid byte sequence — it never
    /// fails and never drops content.
    ///
    /// This is the single display-boundary decoder for every cell / label /
    /// copy string that originates in the core. The core's default UTF-8 path
    /// (`api/lesssheet.h` "Option A") hands back RAW, UN-VALIDATED file bytes
    /// and explicitly places the obligation on the consumer to "replace invalid
    /// sequences with U+FFFD at the display boundary" — detection is head-only
    /// and a forced-UTF-8 override bypasses it, so genuinely invalid UTF-8 does
    /// reach the frontend. `String(decoding:as:)` performs exactly that lossy
    /// substitution.
    ///
    /// The failable `String(bytes:encoding:)` the `optional_data_string_conversion`
    /// lint rule prefers returns `nil` on invalid input, so routing it through
    /// `?? ""` would silently discard the whole cell/label — a data-loss bug.
    /// The rule is therefore deliberately disabled for this one call, which is
    /// the documented ABI obligation, not a style preference.
    init(lossyUTF8 bytes: some Collection<UInt8>) {
        // swiftlint:disable:next optional_data_string_conversion
        self = String(decoding: bytes, as: UTF8.self)
    }
}
