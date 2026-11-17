import Foundation

enum ExploitSupportPolicy {
    static let verifiedIOS17Range = "17.0–17.7.x"
    static let verifiedIOS18Range = "18.0–18.7.1"
    static let verifiedIOS26Range = "26.0–26.7.x"
    // iOS 27+: BookmarkManager — works on ALL 27.x releases, no build allowlist

    static func supportsKernelExploit(major: Int, minor: Int, patch: Int) -> Bool {
        guard minor >= 0, patch >= 0 else { return false }
        if major == 17 { return minor <= 7 }
        if major == 18 { return minor < 7 || (minor == 7 && patch <= 1) }
        return false
    }

    static func isSupported(major: Int, minor: Int, patch: Int, build: String) -> Bool {
        // iOS 17/18: kernel exploit
        if supportsKernelExploit(major: major, minor: minor, patch: patch) {
            return true
        }
        // iOS 26: MHA-C2
        if major == 26 { return true }
        // iOS 27+: BookmarkManager — ALL releases supported, no allowlist
        if major >= 27 { return true }
        return false
    }

    static func accessBackend(major: Int, minor: Int, patch: Int) -> AccessBackend {
        if major <= 18 { return .kernelExploit }
        if major == 26 { return .mhaC2 }
        if major >= 27 { return .bookmarkManager }
        return .mhaC2
    }
}
