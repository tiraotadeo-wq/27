import Foundation
import SwiftUI

// MARK: - MountedFolder

struct MountedFolder: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let containerInfo: AppContainerInfo?
    var isActive: Bool

    var displayName: String {
        containerInfo?.displayName ?? url.lastPathComponent
    }

    var bundleID: String? { containerInfo?.bundleID }
}

// MARK: - BookmarkManager
//
// Security-Scoped Folder Mounts — iOS 27+
//
// The MHA bundle ID (com.apple.mobile.MobileHouseArrest) is granted
// com.apple.private.security.storage.AppDataContainers, which allows the app
// to request security-scoped bookmark access on other apps' containers.
// Once a URL is bookmark-resolved and started-accessing, the kernel mounts
// the container read/write in the app's filesystem namespace.
//
// References:
//   - Security-Scoped Bookmarks: developer.apple.com/documentation/foundation/url/bookmarkcreationoptions
//   - Persistent mounts across launches: store bookmark data in UserDefaults / Keychain

@MainActor
final class BookmarkManager: ObservableObject {
    static let shared = BookmarkManager()

    @Published private(set) var mountedFolders: [MountedFolder] = []

    private let queue = DispatchQueue(label: "com.yangjiii.3105.bookmarks", qos: .userInitiated)
    private var accessingURLs: [URL: Bool] = [:]  // url → isAccessing
    private static let bookmarkStorageKey = "com.yangjiii.3105.bookmarks.stored"

    private init() {
        Task { await restoreBookmarks() }
    }

    // MARK: - Mount / Unmount

    /// Request access to a container directory.
    /// On iOS 27 this triggers a system prompt if not already granted.
    func mount(_ url: URL, containerInfo: AppContainerInfo? = nil) async throws -> URL {
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    // Create a security-scoped bookmark
                    let bookmarkData = try url.bookmarkData(
                        options: [.withSecurityScope],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    // Persist the bookmark
                    self.storeBookmark(bookmarkData, for: url)

                    // Resolve and start accessing
                    var isStale = false
                    let resolvedURL = try URL(
                        resolvingBookmarkData: bookmarkData,
                        options: [.withSecurityScope],
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )
                    let started = resolvedURL.startAccessingSecurityScopedResource()
                    let folder = MountedFolder(
                        url: resolvedURL,
                        containerInfo: containerInfo,
                        isActive: started
                    )
                    DispatchQueue.main.async {
                        self.accessingURLs[resolvedURL] = started
                        if !self.mountedFolders.contains(where: { $0.url == resolvedURL }) {
                            self.mountedFolders.append(folder)
                        }
                    }
                    log("BookmarkManager: mounted \(resolvedURL.path) (started=\(started))")
                    cont.resume(returning: resolvedURL)
                } catch {
                    log("BookmarkManager: mount failed for \(url.path) — \(error)")
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Stop accessing a mounted folder (releases the kernel mount).
    func unmount(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
        accessingURLs.removeValue(forKey: url)
        mountedFolders.removeAll { $0.url == url }
        removeStoredBookmark(for: url)
        log("BookmarkManager: unmounted \(url.path)")
    }

    func unmountAll() {
        for url in accessingURLs.keys {
            url.stopAccessingSecurityScopedResource()
        }
        accessingURLs.removeAll()
        mountedFolders.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.bookmarkStorageKey)
        log("BookmarkManager: unmounted all folders")
    }

    // MARK: - File Operations (require active mount)

    func listDirectory(_ url: URL) async throws -> [FileBrowserItem] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let fm = FileManager.default
                    let contents = try fm.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: [
                            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                            .isHiddenKey, .isSymbolicLinkKey
                        ],
                        options: []
                    )
                    let items = contents.compactMap { itemURL -> FileBrowserItem? in
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
                    cont.resume(returning: items)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func readFile(_ url: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let data = try Data(contentsOf: url)
                    cont.resume(returning: data)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func writeFile(_ url: URL, data: Data) async throws {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    try data.write(to: url, options: .atomic)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func deleteItem(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    try FileManager.default.removeItem(at: url)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func createDirectory(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    try FileManager.default.createDirectory(
                        at: url, withIntermediateDirectories: true
                    )
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func moveItem(from: URL, to: URL) async throws {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    try FileManager.default.moveItem(at: from, to: to)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func copyItem(from: URL, to: URL) async throws {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    try FileManager.default.copyItem(at: from, to: to)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Container Discovery (iOS 27+)

    func discoverContainers() async throws -> [AppContainerInfo] {
        // On iOS 27 with BookmarkManager, enumerate accessible container roots
        try await ContainerScanner.scan()
    }

    // MARK: - Bookmark Persistence

    private func storeBookmark(_ data: Data, for url: URL) {
        var stored = loadStoredBookmarks()
        stored[url.path] = data
        if let encoded = try? PropertyListSerialization.data(
            fromPropertyList: stored.mapValues { $0 as Any },
            format: .binary,
            options: 0
        ) {
            UserDefaults.standard.set(encoded, forKey: Self.bookmarkStorageKey)
        }
    }

    private func removeStoredBookmark(for url: URL) {
        var stored = loadStoredBookmarks()
        stored.removeValue(forKey: url.path)
        if let encoded = try? PropertyListSerialization.data(
            fromPropertyList: stored.mapValues { $0 as Any },
            format: .binary,
            options: 0
        ) {
            UserDefaults.standard.set(encoded, forKey: Self.bookmarkStorageKey)
        }
    }

    private func loadStoredBookmarks() -> [String: Data] {
        guard let encoded = UserDefaults.standard.data(forKey: Self.bookmarkStorageKey),
              let plist = try? PropertyListSerialization.propertyList(
                from: encoded, format: nil
              ) as? [String: Data] else {
            return [:]
        }
        return plist
    }

    private func restoreBookmarks() async {
        let stored = loadStoredBookmarks()
        guard !stored.isEmpty else { return }
        for (_, bookmarkData) in stored {
            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                let started = url.startAccessingSecurityScopedResource()
                let folder = MountedFolder(url: url, containerInfo: nil, isActive: started)
                await MainActor.run {
                    self.accessingURLs[url] = started
                    if !self.mountedFolders.contains(where: { $0.url == url }) {
                        self.mountedFolders.append(folder)
                    }
                }
                log("BookmarkManager: restored mount \(url.path) (started=\(started), stale=\(isStale))")
            } catch {
                log("BookmarkManager: failed to restore bookmark — \(error)")
            }
        }
    }
}
