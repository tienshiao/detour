import XCTest
@testable import Detour

/// TASK-113: which updates are taken, and which permissions an update must have
/// approved before it runs.
final class ExtensionUpdatePolicyTests: XCTestCase {

    private func manifest(_ json: String) throws -> ExtensionManifest {
        try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
    }

    // MARK: - Added permissions (AC #4)

    func testNoChangeIsNoDelta() throws {
        let m = try manifest("""
        {"manifest_version":3,"name":"x","version":"1","permissions":["tabs","storage"],"host_permissions":["https://a.example/*"]}
        """)
        XCTAssertTrue(ExtensionUpdatePolicy.addedPermissions(from: m, to: m).isEmpty)
    }

    func testAddedAPIPermissionIsReportedUnlessWarningFree() throws {
        let old = try manifest("""
        {"manifest_version":3,"name":"x","version":"1","permissions":["tabs"]}
        """)
        let new = try manifest("""
        {"manifest_version":3,"name":"x","version":"2","permissions":["tabs","history","storage","alarms","history"]}
        """)
        let delta = ExtensionUpdatePolicy.addedPermissions(from: old, to: new)
        XCTAssertEqual(delta.permissions, ["history"], "storage and alarms carry no warning; history is listed once")
        XCTAssertTrue(delta.hostPermissions.isEmpty)
        XCTAssertFalse(delta.isEmpty)
    }

    func testRemovedPermissionsAreNotADelta() throws {
        let old = try manifest("""
        {"manifest_version":3,"name":"x","version":"1","permissions":["tabs","history"],"host_permissions":["<all_urls>"]}
        """)
        let new = try manifest("""
        {"manifest_version":3,"name":"x","version":"2","permissions":["tabs"]}
        """)
        XCTAssertTrue(ExtensionUpdatePolicy.addedPermissions(from: old, to: new).isEmpty)
    }

    func testHostPatternCoveredByAnExistingBroaderPatternIsNotNew() throws {
        let old = try manifest("""
        {"manifest_version":3,"name":"x","version":"1","host_permissions":["<all_urls>"]}
        """)
        let new = try manifest("""
        {"manifest_version":3,"name":"x","version":"2","host_permissions":["https://mail.example/*","*://*.example.org/*"]}
        """)
        XCTAssertTrue(ExtensionUpdatePolicy.addedPermissions(from: old, to: new).isEmpty)

        let oldNarrow = try manifest("""
        {"manifest_version":3,"name":"x","version":"1","host_permissions":["https://*.example.com/*"]}
        """)
        let newWider = try manifest("""
        {"manifest_version":3,"name":"x","version":"2","host_permissions":["https://docs.example.com/*","https://other.test/*"]}
        """)
        XCTAssertEqual(ExtensionUpdatePolicy.addedPermissions(from: oldNarrow, to: newWider).hostPermissions,
                       ["https://other.test/*"])
    }

    func testContentScriptMatchesCountAsHostAccessOnBothSides() throws {
        let old = try manifest("""
        {"manifest_version":3,"name":"x","version":"1",
         "content_scripts":[{"matches":["https://*.example.com/*"],"js":["c.js"]}]}
        """)
        let newSame = try manifest("""
        {"manifest_version":3,"name":"x","version":"2","host_permissions":["https://app.example.com/*"]}
        """)
        XCTAssertTrue(ExtensionUpdatePolicy.addedPermissions(from: old, to: newSame).isEmpty,
                      "a content script already ran there")
        let newScript = try manifest("""
        {"manifest_version":3,"name":"x","version":"2",
         "content_scripts":[{"matches":["https://*.example.com/*","https://bank.test/*"],"js":["c.js"]}]}
        """)
        XCTAssertEqual(ExtensionUpdatePolicy.addedPermissions(from: old, to: newScript).hostPermissions,
                       ["https://bank.test/*"])
    }

    func testOptionalPermissionsAreNotCounted() throws {
        let old = try manifest("""
        {"manifest_version":3,"name":"x","version":"1"}
        """)
        let new = try manifest("""
        {"manifest_version":3,"name":"x","version":"2","optional_permissions":["history"],"optional_host_permissions":["<all_urls>"]}
        """)
        XCTAssertTrue(ExtensionUpdatePolicy.addedPermissions(from: old, to: new).isEmpty)
    }

    func testAnUnparsablePatternCountsAsNewWhenAddedAndCoversNothingWhenOld() throws {
        let old = try manifest("""
        {"manifest_version":3,"name":"x","version":"1","host_permissions":["not a pattern"]}
        """)
        let new = try manifest("""
        {"manifest_version":3,"name":"x","version":"2","host_permissions":["not a pattern","https://a.example/*"]}
        """)
        XCTAssertEqual(ExtensionUpdatePolicy.addedPermissions(from: old, to: new).hostPermissions,
                       ["not a pattern", "https://a.example/*"])
    }

    func testDeltaMergeDeduplicatesInOrder() {
        let a = ExtensionUpdatePolicy.PermissionDelta(permissions: ["tabs"], hostPermissions: ["https://a/*"])
        let b = ExtensionUpdatePolicy.PermissionDelta(permissions: ["history", "tabs"], hostPermissions: ["https://a/*", "https://b/*"])
        XCTAssertEqual(a.merged(with: b),
                       .init(permissions: ["tabs", "history"], hostPermissions: ["https://a/*", "https://b/*"]))
        XCTAssertEqual(ExtensionUpdatePolicy.PermissionDelta.none.merged(with: .none), .none)
    }

    func testPendingApprovalRoundTripsThroughJSON() throws {
        let pending = ExtensionUpdatePolicy.PendingApproval(
            version: "2.0", delta: .init(permissions: ["history"], hostPermissions: ["<all_urls>"]))
        let data = try JSONEncoder().encode(pending)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionUpdatePolicy.PendingApproval.self, from: data), pending)
    }

    // MARK: - Candidate validation (AC #3)

    func testCandidateMustDeriveTheSameIDAndBeNewer() {
        XCTAssertNoThrow(try ExtensionUpdatePolicy.validateCandidate(
            installedID: "abc", installedVersion: "1.0", candidateID: "abc", candidateVersion: "1.0.1"))
        XCTAssertThrowsError(try ExtensionUpdatePolicy.validateCandidate(
            installedID: "abc", installedVersion: "1.0", candidateID: "xyz", candidateVersion: "2.0")) {
            XCTAssertEqual($0 as? ExtensionUpdatePolicy.CandidateRejection, .idMismatch(expected: "abc", actual: "xyz"))
        }
        XCTAssertThrowsError(try ExtensionUpdatePolicy.validateCandidate(
            installedID: "abc", installedVersion: "1.0", candidateID: "abc", candidateVersion: "1.0")) {
            XCTAssertEqual($0 as? ExtensionUpdatePolicy.CandidateRejection, .notNewer(installed: "1.0", candidate: "1.0"))
        }
        XCTAssertThrowsError(try ExtensionUpdatePolicy.validateCandidate(
            installedID: "abc", installedVersion: "2.0", candidateID: "abc", candidateVersion: "1.9"))
    }

    func testSHA256IsCheckedOnlyWhenAnnounced() throws {
        let data = Data("crx bytes".utf8)
        XCTAssertNoThrow(try ExtensionUpdatePolicy.validateSHA256(expected: nil, of: data))
        let good = Data(hex: "1c8d0e5b3c8b3aefbd5a7d93a26d5bd8b2ae7a2c1fa12e6a2ec6d2e66d0a4a95")
        // Compute the real hash rather than trusting the literal above.
        let real = Data(CryptoKitSHA256.hash(data))
        XCTAssertNoThrow(try ExtensionUpdatePolicy.validateSHA256(expected: real, of: data))
        XCTAssertThrowsError(try ExtensionUpdatePolicy.validateSHA256(expected: good, of: data)) {
            XCTAssertEqual($0 as? ExtensionUpdatePolicy.CandidateRejection, .hashMismatch)
        }
    }
}

import CryptoKit
private enum CryptoKitSHA256 {
    static func hash(_ data: Data) -> SHA256Digest { SHA256.hash(data: data) }
}
