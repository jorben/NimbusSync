import Foundation

/// Decoder for Cloudreve's obfuscated ("time flow") thumbnail URLs, ported
/// from the official clients. The server shuffles `"<unix seconds>|<url>"`
/// with the digits of the current time; decoding replays the shuffle in
/// reverse and validates the timestamp prefix. Clock skew of one second in
/// either direction is tolerated, matching the web client.
public enum CloudreveTimeFlow {
    public static func decode(_ value: String, now: Date = Date()) -> String? {
        let milliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        for delta: Int64 in [0, -1_000, 1_000] {
            if let decoded = decode(value, unixMilliseconds: milliseconds + delta) { return decoded }
        }
        return nil
    }

    static func decode(_ value: String, unixMilliseconds: Int64) -> String? {
        if value.isEmpty { return "" }
        var time = unixMilliseconds / 1_000
        let timestamp = time
        var digits: [Int64] = []
        while time > 0 {
            digits.append(time % 10)
            time /= 10
        }
        guard !digits.isEmpty else { return nil }

        let characters = Array(value)
        var result = characters
        var secret = characters
        var add = secret.count % 2 == 0
        var digitIndex = (secret.count - 1) % digits.count
        let length = secret.count

        for position in 0..<length {
            let resultIndex = length - 1 - position
            var newIndex = Int64(resultIndex)
            let digit = digits[digitIndex]
            if add {
                newIndex += digit * Int64(digitIndex)
            } else {
                newIndex = 2 * Int64(digitIndex) * digit - newIndex
            }
            if newIndex < 0 { newIndex = -newIndex }
            let target = Int(newIndex % Int64(secret.count))
            result[resultIndex] = secret[target]
            secret.swapAt(resultIndex, target)
            secret.removeLast()
            add.toggle()
            digitIndex -= 1
            if digitIndex < 0 { digitIndex = digits.count - 1 }
        }

        let decoded = String(result)
        guard let separator = decoded.firstIndex(of: "|"), decoded[decoded.startIndex..<separator] == String(timestamp) else { return nil }
        return String(decoded[decoded.index(after: separator)...])
    }
}
