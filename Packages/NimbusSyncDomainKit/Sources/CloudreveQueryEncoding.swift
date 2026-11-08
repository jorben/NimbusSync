import Foundation

/// Foundation leaves `+` literal in `URLComponents.queryItems`, but Go's
/// `url.ParseQuery` (Cloudreve) and browser `URLSearchParams` decode it as a
/// space. A folder such as `C++` was therefore listed as `C  ` and Cloudreve
/// answered 40016 (parent not found), failing every reconcile scan.
public extension URLComponents {
    /// Sets query items so every value round-trips through form decoding.
    /// Spaces are already `%20`, so any remaining `+` came from a value.
    mutating func setCloudreveQueryItems(_ items: [URLQueryItem]) {
        queryItems = items
        percentEncodedQuery = percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    }

    /// Appends one item while leaving the existing (possibly signed) query
    /// byte-for-byte untouched. Re-assigning `queryItems` would decode `%2B`
    /// in a signature to `+` and corrupt it.
    mutating func appendCloudreveQueryItem(_ item: URLQueryItem) {
        var addition = URLComponents()
        addition.setCloudreveQueryItems([item])
        guard let encoded = addition.percentEncodedQuery, !encoded.isEmpty else { return }
        if let existing = percentEncodedQuery, !existing.isEmpty {
            percentEncodedQuery = existing + "&" + encoded
        } else {
            percentEncodedQuery = encoded
        }
    }
}
