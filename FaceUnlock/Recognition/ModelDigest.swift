import CryptoKit
import Foundation

/// SHA-256 helper used to identify an optional Core ML model.
public enum ModelDigest {
    public static func shortHex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.prefix(16).joined()
    }
}
