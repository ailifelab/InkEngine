// Compile with NearbyService.swift and the built InkCore module.
// All preferences and keychain operations are isolated/injected; no real keys or network.
import Foundation
import CryptoKit

@main struct NearbyIdentityChecks {
    @MainActor static func main() throws {
        let suite = "org.ailifelab.InkEngine.IdentityChecks." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let stored = Curve25519.Signing.PrivateKey()
        let peerID = UUID().uuidString
        let trust = [peerID: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()]
        var reads: [Bool] = [], writes = 0, passed = 0
        func check(_ condition: Bool, _ note: String) throws {
            guard condition else { throw NSError(domain: "IdentityChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: note]) }
            passed += 1; print("PASS: " + note)
        }
        func rememberFixture() {
            preferences.set(trust, forKey: "trustedPeers")
            preferences.set([peerID: "Fixture peer"], forKey: "trustedNames")
        }
        let temporary = NearbyService(preferences: preferences, loadIdentity: { allowed in
            reads.append(allowed); return stored
        }, saveIdentity: { _ in writes += 1 })
        try check(reads.isEmpty && writes == 0, "Normal launch performs no keychain read or write")
        let first = try temporary.connectionIdentity(allowInteraction: false)
        let second = try temporary.connectionIdentity(allowInteraction: true)
        try check(reads.isEmpty && writes == 0 && first.rawRepresentation == second.rawRepresentation,
                  "Temporary pairing uses one session identity without keychain access")
        rememberFixture()
        let remembered = NearbyService(preferences: preferences, loadIdentity: { allowed in
            reads.append(allowed)
            if !allowed { throw NSError(domain: NSOSStatusErrorDomain, code: -25308) }
            return stored
        }, saveIdentity: { _ in writes += 1 })
        try check(reads.isEmpty && remembered.trustedNames == ["Fixture peer"], "Remembered-device launch defers its keychain read")
        var denied = false
        do { _ = try remembered.connectionIdentity(allowInteraction: false) } catch { denied = true }
        try check(denied && reads == [false] && remembered.trustedNames == ["Fixture peer"] && writes == 0,
                  "Background access denial preserves trust and never replaces or saves an identity")
        let restored = try remembered.connectionIdentity(allowInteraction: true)
        try check(restored.rawRepresentation == stored.rawRepresentation && reads == [false, true],
                  "Explicit connection can authorize and restore the original identity")
        _ = try remembered.connectionIdentity(allowInteraction: false)
        try check(reads == [false, true], "Restored identity is cached for later connections in this process")
        remembered.forgetAll()
        let revoked = try remembered.connectionIdentity(allowInteraction: false)
        try check(preferences.dictionary(forKey: "trustedPeers") == nil && remembered.trustedNames.isEmpty
                  && revoked.rawRepresentation != stored.rawRepresentation && reads == [false, true] && writes == 0,
                  "Revoking trust rotates the temporary identity without accessing or deleting a keychain item")
        rememberFixture()
        let missing = NearbyService(preferences: preferences, loadIdentity: { _ in nil }, saveIdentity: { _ in writes += 1 })
        var missingRejected = false
        do { _ = try missing.connectionIdentity(allowInteraction: true) } catch { missingRejected = true }
        try check(missingRejected && missing.trustedNames == ["Fixture peer"] && writes == 0,
                  "Missing remembered key blocks authentication without silently rotating it")
        let cancelled = NearbyService(preferences: preferences, loadIdentity: { _ in
            throw NSError(domain: NSOSStatusErrorDomain, code: -128)
        }, saveIdentity: { _ in writes += 1 })
        var cancelRejected = false
        do { _ = try cancelled.connectionIdentity(allowInteraction: true) } catch { cancelRejected = true }
        try check(cancelRejected && cancelled.trustedNames == ["Fixture peer"] && writes == 0,
                  "Cancelled authorization preserves existing trust and key")
        let testing = NearbyService(preferences: preferences, loadIdentity: { allowed in reads.append(allowed); return stored },
                                    saveIdentity: { _ in writes += 1 })
        testing.isTesting = true
        _ = try testing.connectionIdentity(allowInteraction: true)
        try check(reads == [false, true] && writes == 0, "UI testing never loads a real pairing identity")
        print("Nearby identity checks passed: \(passed)")
    }
}
