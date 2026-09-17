import XCTest
@testable import FarRelay

final class SSHSessionTests: XCTestCase {
    private func configuration(
        authentication: SSHAuthenticationConfiguration
    ) -> SSHSessionConfiguration {
        SSHSessionConfiguration(
            host: "example.invalid",
            port: 22,
            username: "tester",
            authentication: authentication
        )
    }

    func testPasswordAuthenticationSummary() throws {
        let summary = try SSHSession.authenticationSummary(
            for: configuration(authentication: .password("secret"))
        )

        XCTAssertEqual(summary.kind, "password")
        XCTAssertNil(summary.fingerprint)
    }

    func testHostKeyPolicyDefaultsToTrustOnFirstUse() {
        XCTAssertEqual(
            configuration(authentication: .password("secret")).hostKeyPolicy,
            .trustOnFirstUse
        )
    }

    func testEmptyPrivateKeyFailsWithMissingKey() {
        XCTAssertThrowsError(
            try SSHSession.authenticationSummary(
                for: configuration(authentication: .privateKey(pem: " \n", passphrase: ""))
            )
        ) { error in
            XCTAssertEqual(error as? SSHAuthenticationError, .missingKey)
        }
    }

    func testMalformedOpenSSHPrivateKeyFailsWithParsingError() {
        XCTAssertThrowsError(
            try SSHSession.authenticationSummary(
                for: configuration(authentication: .privateKey(
                    pem: "-----BEGIN OPENSSH PRIVATE KEY-----\nnot-a-key\n-----END OPENSSH PRIVATE KEY-----",
                    passphrase: ""
                ))
            )
        ) { error in
            guard let authenticationError = error as? SSHAuthenticationError,
                  case .unsupportedKey = authenticationError else {
                return XCTFail("Expected an unsupported-key parsing error, got \(error)")
            }
        }
    }
}
