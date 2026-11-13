import XCTest
import Foundation
import CloudreveDomainKit

/// Cloudreve (Go `url.ParseQuery`) decodes `+` as a space. Foundation leaves
/// `+` literal in `queryItems`, so a folder named `C++` was requested as
/// `C  ` and every reconcile scan failed with api_code 40016.
final class CloudreveQueryEncodingTests: XCTestCase {
    /// Mirrors Go's form decoding: `+` is a space, then percent-decoding.
    private func goFormDecode(_ encodedQuery: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in encodedQuery.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            }
            result[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return result
    }

    func testValuesRoundTripThroughGoFormDecoding() throws {
        let uri = "cloudreve://account@my/%E5%B7%A5%E4%BD%9C/C++ notes/PPT&Book=1?#"
        var components = try XCTUnwrap(URLComponents(string: "https://cloudreve.example/api/v4/file"))
        components.setCloudreveQueryItems([URLQueryItem(name: "uri", value: uri), URLQueryItem(name: "page", value: "1")])
        let encoded = try XCTUnwrap(components.percentEncodedQuery)
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertEqual(goFormDecode(encoded), ["uri": uri, "page": "1"])
    }

    func testDefaultFoundationEncodingWouldCorruptPlus() throws {
        // Documents the Foundation behaviour the helper exists to correct.
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "uri", value: "cloudreve://my/C++")]
        XCTAssertNotEqual(goFormDecode(try XCTUnwrap(components.percentEncodedQuery))["uri"], "cloudreve://my/C++")
    }

    func testAppendKeepsSignedQueryByteForByte() throws {
        let signed = "https://storage.example/upload?sig=ab%2Bcd%2F%3D&expires=10"
        var components = try XCTUnwrap(URLComponents(string: signed))
        components.appendCloudreveQueryItem(URLQueryItem(name: "chunk", value: "3"))
        XCTAssertEqual(components.percentEncodedQuery, "sig=ab%2Bcd%2F%3D&expires=10&chunk=3")
    }

    func testAppendToURLWithoutQuery() throws {
        var components = try XCTUnwrap(URLComponents(string: "https://storage.example/upload"))
        components.appendCloudreveQueryItem(URLQueryItem(name: "chunk", value: "0"))
        XCTAssertEqual(components.url?.absoluteString, "https://storage.example/upload?chunk=0")
    }
}
