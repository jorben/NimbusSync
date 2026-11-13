import XCTest
import Foundation
import CloudreveDesignSystem
import CloudreveDomainKit

/// The Add Domain window turns what was typed into an address to check, and failures into words.
final class AddDomainTextTests: XCTestCase {
    func testSubmittableOriginAddsHTTPSOnlyWhenNoSchemeWasTyped() {
        XCTAssertEqual(AddDomainText.submittableOrigin("cloud.example.com"), "https://cloud.example.com")
        XCTAssertEqual(AddDomainText.submittableOrigin("  nas.example.org:5212/cloud \n"), "https://nas.example.org:5212/cloud")
        XCTAssertEqual(AddDomainText.submittableOrigin("https://cloud.example.com"), "https://cloud.example.com")
        XCTAssertEqual(AddDomainText.submittableOrigin("http://localhost:5212"), "http://localhost:5212", "a typed scheme is left for the validator to judge")
        XCTAssertEqual(AddDomainText.submittableOrigin("   "), "")
    }

    func testCommonFailuresReadAsPlainWords() {
        XCTAssertTrue(AddDomainText.message(for: .unsupportedServer)?.contains("Cloudreve 4.12") == true)
        XCTAssertNotNil(AddDomainText.message(for: .network))
        XCTAssertNil(AddDomainText.message(for: .database), "anything else keeps the generic text")
        XCTAssertNotNil(AddDomainText.message(forURLError: .cannotFindHost))
        XCTAssertNotNil(AddDomainText.message(forURLError: .serverCertificateUntrusted))
        XCTAssertNil(AddDomainText.message(forURLError: .cancelled))
    }

    func testStepFollowsWhatTheAppKnows() {
        func view(phase: AddDomainAuthorizationPhase?, review: AddDomainReview?) -> AddDomainView {
            AddDomainView(origin: .constant(""), displayName: .constant(""), authorizationPhase: phase, review: review, isAdding: false, errorMessage: nil, onContinue: { _ in }, onCancelSignIn: {}, onBack: {}, onAdd: {}, onClose: {}, onOpenFileProviderSettings: {})
        }
        XCTAssertEqual(view(phase: nil, review: nil).step, .server)
        XCTAssertEqual(view(phase: .waitingForBrowser, review: nil).step, .signIn)
        XCTAssertEqual(view(phase: nil, review: AddDomainReview(origin: "https://cloud.example.com", serverVersion: nil, remotePath: "/")).step, .review)
    }
}
