import CryptoKit
import Foundation
import Security

nonisolated protocol ClipboardEncryptionKeyProviding: Sendable {
    func encryptionKey() throws -> SymmetricKey
}

nonisolated enum ClipboardEncryptionError: Error, Equatable {
    case invalidKey
    case keychain(OSStatus)
    case invalidEnvelope
}

nonisolated struct SystemClipboardEncryptionKeyProvider: ClipboardEncryptionKeyProviding {
    private let service: String
    private let account = "clipboard-history-encryption-key-v1"

    init(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.oontz.SnipSnipSnip") {
        service = "\(bundleIdentifier).clipboard-history"
    }

    func encryptionKey() throws -> SymmetricKey {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let lookupStatus = SecItemCopyMatching(query as CFDictionary, &result)
        if lookupStatus == errSecSuccess {
            guard let data = result as? Data, data.count == 32 else {
                throw ClipboardEncryptionError.invalidKey
            }
            return SymmetricKey(data: data)
        }
        guard lookupStatus == errSecItemNotFound else {
            throw ClipboardEncryptionError.keychain(lookupStatus)
        }

        let keyData = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        query.removeValue(forKey: kSecReturnData as String)
        query.removeValue(forKey: kSecMatchLimit as String)
        query[kSecValueData as String] = keyData
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)

        if addStatus == errSecDuplicateItem {
            return try encryptionKey()
        }
        guard addStatus == errSecSuccess else {
            throw ClipboardEncryptionError.keychain(addStatus)
        }
        return SymmetricKey(data: keyData)
    }
}

nonisolated struct ClipboardHistoryCryptor: Sendable {
    static let envelopeMagic = Data("SSSC1".utf8)
    let keyProvider: any ClipboardEncryptionKeyProviding

    func encrypt(_ plaintext: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: keyProvider.encryptionKey())
        guard let combined = sealed.combined else {
            throw ClipboardEncryptionError.invalidEnvelope
        }
        return Self.envelopeMagic + combined
    }

    func decryptIfNeeded(_ data: Data) throws -> (data: Data, wasEncrypted: Bool) {
        guard data.starts(with: Self.envelopeMagic) else {
            return (data, false)
        }
        let combined = data.dropFirst(Self.envelopeMagic.count)
        guard !combined.isEmpty else {
            throw ClipboardEncryptionError.invalidEnvelope
        }
        let sealed = try AES.GCM.SealedBox(combined: combined)
        return (try AES.GCM.open(sealed, using: keyProvider.encryptionKey()), true)
    }
}

