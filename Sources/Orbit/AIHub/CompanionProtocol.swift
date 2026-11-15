import CryptoKit
import Foundation

// Phone companion (Phase 11) — conditional and deferred (D2). This is only the
// platform-independent part: versioned messages and their end-to-end
// encryption. There's no transport, no listener, no iOS project and no
// pairing UI; nothing here opens a port. The algorithms are standard —
// X25519 key agreement, HKDF-SHA256, ChaCha20-Poly1305 — so a non-Apple
// client can implement them with any common library; CryptoKit is just this
// Mac's implementation of `CompanionCipher`.

/// What a companion and Orbit say to each other, inside a sealed envelope.
struct CompanionMessage: Codable, Equatable, Sendable {
    enum Body: Codable, Equatable, Sendable {
        case ping
        /// Sessions as the dashboard shows them (no prompts, no file contents).
        case sessions([Session])
        case approvalRequest(id: UUID, agent: String, summary: String, options: [String], expiresAt: Date)
        /// From the phone: the user's decision ("allow", "deny" or one of the options).
        case approvalDecision(id: UUID, decision: String)
    }

    struct Session: Codable, Equatable, Sendable {
        let key: String
        let agent: String
        let title: String?
        let status: String
        let lastEventAt: Date
    }

    static let version = 1
    var v = Self.version
    let id: UUID
    let sentAt: Date
    let body: Body
}

/// A paired device's sealed message: who sent it, its sequence number, the ciphertext.
struct SealedMessage: Codable, Equatable, Sendable {
    let v: Int
    /// The sender's key ID (first 8 bytes of SHA-256 of its public key, hex).
    let kid: String
    /// Strictly increasing per sender: a replay or reordering is refused.
    let n: UInt64
    /// Nonce + ciphertext + tag (ChaCha20-Poly1305 combined form), base64.
    let ct: String
}

enum CompanionError: Error, Equatable {
    case badVersion, unknownDevice, revoked, replayed, tampered, malformed
}

/// The encryption interface; any platform implements the same algorithms.
protocol CompanionCipher {
    func seal(_ message: CompanionMessage, sequence: UInt64) throws -> SealedMessage
    func open(_ sealed: SealedMessage) throws -> CompanionMessage
}

/// One paired device, from this side: the shared key and the replay window.
struct CompanionChannel: CompanionCipher {
    static let info = Data("orbit-companion-v1".utf8)
    let localKeyID: String
    let peerKeyID: String
    private let key: SymmetricKey
    private(set) var lastSequence: UInt64 = 0

    /// X25519 agreement, then HKDF-SHA256 over both public keys (in sorted order, so both sides derive the same key).
    init(local: Curve25519.KeyAgreement.PrivateKey, peer: Curve25519.KeyAgreement.PublicKey) throws {
        let secret = try local.sharedSecretFromKeyAgreement(with: peer)
        let keys = [local.publicKey.rawRepresentation, peer.rawRepresentation].sorted { $0.lexicographicallyPrecedes($1) }
        key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: keys[0] + keys[1], sharedInfo: Self.info, outputByteCount: 32)
        localKeyID = Self.keyID(local.publicKey)
        peerKeyID = Self.keyID(peer)
    }

    static func keyID(_ key: Curve25519.KeyAgreement.PublicKey) -> String {
        SHA256.hash(data: key.rawRepresentation).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Pairing is commit-then-reveal, so the six digits can't be matched by a key search:
    /// 1. the phone sends `commitment(phoneKey, nonce)`; 2. the Mac sends its key;
    /// 3. the phone reveals its key and nonce, and the Mac checks them against the commitment;
    /// 4. both screens show `pairingCode`, and the user confirms they match.
    static func commitment(_ key: Curve25519.KeyAgreement.PublicKey, nonce: Data) -> Data {
        Data(SHA256.hash(data: info + key.rawRepresentation + nonce))
    }

    static func verify(_ commitment: Data, key: Curve25519.KeyAgreement.PublicKey, nonce: Data) -> Bool {
        nonce.count >= 16 && Self.commitment(key, nonce: nonce) == commitment
    }

    static func pairingCode(_ a: Curve25519.KeyAgreement.PublicKey, _ b: Curve25519.KeyAgreement.PublicKey, nonce: Data) -> String {
        let keys = [a.rawRepresentation, b.rawRepresentation].sorted { $0.lexicographicallyPrecedes($1) }
        let digest = Array(SHA256.hash(data: info + keys[0] + keys[1] + nonce))
        let number = (UInt32(digest[0]) << 16 | UInt32(digest[1]) << 8 | UInt32(digest[2])) % 1_000_000
        return String(format: "%06u", number)
    }

    private func aad(_ kid: String, _ n: UInt64) -> Data { Data("orbit-companion-v1|\(kid)|\(n)".utf8) }

    func seal(_ message: CompanionMessage, sequence: UInt64) throws -> SealedMessage {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let box = try ChaChaPoly.seal(try encoder.encode(message), using: key, authenticating: aad(localKeyID, sequence))
        return SealedMessage(v: CompanionMessage.version, kid: localKeyID, n: sequence, ct: box.combined.base64EncodedString())
    }

    func open(_ sealed: SealedMessage) throws -> CompanionMessage {
        try open(sealed, revoked: [])
    }

    func open(_ sealed: SealedMessage, revoked: Set<String>) throws -> CompanionMessage {
        guard sealed.v == CompanionMessage.version else { throw CompanionError.badVersion }
        guard !revoked.contains(sealed.kid) else { throw CompanionError.revoked }
        guard sealed.kid == peerKeyID else { throw CompanionError.unknownDevice }
        guard sealed.n > lastSequence else { throw CompanionError.replayed }
        guard let data = Data(base64Encoded: sealed.ct), let box = try? ChaChaPoly.SealedBox(combined: data) else { throw CompanionError.malformed }
        guard let plain = try? ChaChaPoly.open(box, using: key, authenticating: aad(sealed.kid, sealed.n)) else { throw CompanionError.tampered }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let message = try? decoder.decode(CompanionMessage.self, from: plain), message.v == CompanionMessage.version else {
            throw CompanionError.malformed
        }
        return message
    }

    /// Accepts a message: opens it and advances the replay window.
    mutating func receive(_ sealed: SealedMessage, revoked: Set<String> = []) throws -> CompanionMessage {
        let message = try open(sealed, revoked: revoked)
        lastSequence = sealed.n
        return message
    }
}
