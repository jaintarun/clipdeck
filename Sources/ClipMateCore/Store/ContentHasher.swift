import Foundation
import CryptoKit

/// SHA-256 over payload bytes. Used to detect "you copied the same thing twice"
/// (spec §6). Not security-sensitive — this is a dedupe key, not a credential.
public enum ContentHasher {
    public static func hash(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}
