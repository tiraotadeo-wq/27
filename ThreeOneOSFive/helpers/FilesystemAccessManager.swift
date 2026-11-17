import Foundation
import SwiftUI

// MARK: - AccessBackend

enum AccessBackend: Equatable {
    case kernelExploit  // iOS 17.0 – 18.7.1 (opa334, opt-in)
    case mhaC2          // iOS 26.0 – 26.7.x (MobileHouseArrest sandbox extensions)
    case bookmarkManager // iOS 27.0+ ALL releases (Security-Scoped Folder Mounts)

    var displayName: String {
        switch self {
        case .kernelExploit: return "Kernel Exploit (opa334)"
        case .mhaC2: return "MHA-C2"
        case .bookmarkManager: return "BookmarkManager"
        }
    }

    var color: Color {
        switch self {
        case .kernelExploit: return .orange
        case .mhaC2: return .blue
        case .bookmarkManager: return .purple
        }
    }

    var shortName: String {
        switch self {
        case .kernelExploit: return "kexploit"
        case .mhaC2: return "MHA-C2"
        case .bookmarkManager: return "BookmarkManager"
        }
    }
}

// MARK: - FilesystemAccessManager

@MainActor
final class FilesystemAccessManager: ObservableObject {
    static let shared = FilesystemAccessManager()

    @Published private(set) var activeBackend: AccessBackend
    @Published private(set) var iosVersion: String

    private init() {
        let v = AppInfo.versionTuple
        iosVersion = AppInfo.osVersion
        activeBackend = ExploitSupportPolicy.accessBackend(
            major: v.major, minor: v.minor, patch: v.patch
        )
    }

    func refresh() {
        let v = AppInfo.versionTuple
        iosVersion = AppInfo.osVersion
        activeBackend = ExploitSupportPolicy.accessBackend(
            major: v.major, minor: v.minor, patch: v.patch
        )
    }

    // MARK: - File operations (dispatched to correct backend)

    func listDirectory(_ url: URL) async throws -> [FileBrowserItem] {
        switch activeBackend {
        case .kernelExploit, .mhaC2:
            return try await listDirectoryNative(url)
        case .bookmarkManager:
            return try await BookmarkManager.shared.listDirectory(url)
        }
    }

    func readFile(_ url: URL) async throws -> Data {
        switch activeBackend {
        case .kernelExploit, .mhaC2:
            return try Data(contentsOf: url)
        case .bookmarkManager:
            return try await BookmarkManager.shared.readFile(url)
        }
    }

    func writeFile(_ url: URL, data: Data) async throws {
        switch activeBackend {
        case .kernelExploit, .mhaC2:
            try data.write(to: url, options: .atomic)
        case .bookmarkManager:
            try await BookmarkManager.shared.writeFile(url, data: data)
        }
    }

    func deleteFile(_ url: URL) async throws {
        switch activeBackend {
        case .kernelExploit, .mhaC2:
            try FileManager.default.removeItem(at: url)
        case .bookmarkManager:
            try await BookmarkManager.shared.deleteItem(url)
        }
    }

    func createDirectory(_ url: URL) async throws {
        switch activeBackend {
        case .kernelExploit, .mhaC2:
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        case .bookmarkManager:
            try await BookmarkManager.shared.createDirectory(url)
        }
    }

    func moveItem(from: URL, to: URL) async throws {
        switch activeBackend {
        case .kernelExploit, .mhaC2:
            try FileManager.default.moveItem(at: from, to: to)
        case .bookmarkManager:
            try await BookmarkManager.shared.moveItem(from: from, to: to)
        }
    }

    func copyItem(from: URL, to: URL) async throws {
        switch activeBackend {
        case .kernelExploit, .mhaC2:
            try FileManager.default.copyItem(at: from, to: to)
        case .bookmarkManager:
            try await BookmarkManager.shared.copyItem(from: from, to: to)
        }
    }

    // MARK: - Rescan

    func rescanContainers() async throws -> [AppContainerInfo] {
        switch activeBackend {
        case .kernelExploit, .mhaC2:
            return try await ContainerScanner.scan()
        case .bookmarkManager:
            return try await BookmarkManager.shared.discoverContainers()
        }
    }

    // MARK: - Private

    private func listDirectoryNative(_ url: URL) async throws -> [FileBrowserItem] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                .isHiddenKey, .isSymbolicLinkKey
            ],
            options: []
        )
        return contents.compactMap { itemURL in
            guard let values = try? itemURL.resourceValues(forKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                .isHiddenKey, .isSymbolicLinkKey
            ]) else { return nil }
            return FileBrowserItem(
                url: itemURL,
                isDirectory: values.isDirectory ?? false,
                fileSize: Int64(values.fileSize ?? 0),
                modificationDate: values.contentModificationDate,
                isHidden: values.isHidden ?? false,
                isSymlink: values.isSymbolicLink ?? false
            )
        }
    }
}

// MARK: - FileBrowserItem

struct FileBrowserItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let isDirectory: Bool
    let fileSize: Int64
    let modificationDate: Date?
    let isHidden: Bool
    let isSymlink: Bool

    var name: String { url.lastPathComponent }
    var path: String { url.path }
}

// MARK: - AppContainerInfo

struct AppContainerInfo: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let bundleID: String?
    let appName: String?
    let containerType: ContainerType

    enum ContainerType: String {
        case appData = "Application"
        case appGroup = "AppGroup"
        case system = "System"
        case internalDaemon = "InternalDaemon"
        case pluginKitPlugin = "PluginKitPlugin"
    }

    var displayName: String {
        appName ?? bundleID ?? url.lastPathComponent
    }
}

// MARK: - ContainerScanner (native, for iOS 17/18/26)

enum ContainerScanner {
    static func scan() async throws -> [AppContainerInfo] {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                var results: [AppContainerInfo] = []
                let bases: [(String, AppContainerInfo.ContainerType)] = [
                    ("/var/mobile/Containers/Data/Application", .appData),
                    ("/var/mobile/Containers/Shared/AppGroup", .appGroup),
                    ("/var/mobile/Containers/Data/InternalDaemon", .internalDaemon),
                    ("/var/mobile/Containers/Data/PluginKitPlugin", .pluginKitPlugin),
                ]
                for (base, type) in bases {
                    guard let uuids = try? fm.contentsOfDirectory(atPath: base) else { continue }
                    for uuid in uuids {
                        let containerPath = "\(base)/\(uuid)"
                        let metaPath = "\(containerPath)/.com.apple.mobile_container_manager.metadata.plist"
                        var bundleID: String?
                        if let meta = NSDictionary(contentsOfFile: metaPath),
                           let bid = meta["MCMMetadataIdentifier"] as? String {
                            bundleID = bid
                        }
                        results.append(AppContainerInfo(
                            url: URL(fileURLWithPath: containerPath),
                            bundleID: bundleID,
                            appName: bundleID.flatMap { ContainerNameResolver.appName(for: $0) },
                            containerType: type
                        ))
                    }
                }
                cont.resume(returning: results)
            }
        }
    }
}

// MARK: - ContainerNameResolver

enum ContainerNameResolver {
    static func appName(for bundleID: String) -> String? {
        // Try to look up the app name from the installed app bundle
        let appPaths = [
            "/var/containers/Bundle/Application",
            "/var/mobile/Library/PreferenceBundles",
        ]
        let fm = FileManager.default
        for base in appPaths {
            guard let uuids = try? fm.contentsOfDirectory(atPath: base) else { continue }
            for uuid in uuids {
                let candidates = (try? fm.contentsOfDirectory(atPath: "\(base)/\(uuid)")) ?? []
                for item in candidates where item.hasSuffix(".app") {
                    let plistPath = "\(base)/\(uuid)/\(item)/Info.plist"
                    if let plist = NSDictionary(contentsOfFile: plistPath),
                       let bid = plist["CFBundleIdentifier"] as? String,
                       bid == bundleID,
                       let name = plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String {
                        return name
                    }
                }
            }
        }
        return nil
    }
}
