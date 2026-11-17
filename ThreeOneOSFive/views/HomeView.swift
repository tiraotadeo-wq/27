import SwiftUI

struct HomeView: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var accessManager = FilesystemAccessManager.shared
    @ObservedObject private var bookmarkManager = BookmarkManager.shared

    @State private var containers: [AppContainerInfo] = []
    @State private var isScanning = false
    @State private var scanError: String?
    @State private var showMountPicker = false

    let onOpenSettings: () -> Void
    let onOpenLogs: () -> Void

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if accessManager.activeBackend == .kernelExploit {
                    kernelExploitSection
                }
                if accessManager.activeBackend == .bookmarkManager {
                    mountedFoldersSection
                }
                quickActionsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("3105")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppUtilityToolbar(
                    language: language,
                    onOpenSettings: onOpenSettings,
                    onOpenLogs: onOpenLogs
                )
            }
        }
    }

    // MARK: - Status Section

    private var statusSection: some View {
        Section("Device & Access") {
            HStack {
                Label("iOS Version", systemImage: "iphone")
                Spacer()
                Text("iOS \(AppInfo.osVersion)")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Label("Access Method", systemImage: "lock.open.fill")
                Spacer()
                Text(accessManager.activeBackend.displayName)
                    .foregroundStyle(accessManager.activeBackend.color)
                    .fontWeight(.semibold)
            }
            if let unsupported = appState.unsupportedMessage {
                Label("Unsupported: \(unsupported)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
            } else {
                Label("Supported", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
            if let error = scanError {
                Label(error, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        }
    }

    // MARK: - Kernel Exploit Section (iOS 17/18)

    private var kernelExploitSection: some View {
        Section {
            HStack {
                Label("Kernel Exploit", systemImage: "cpu")
                Spacer()
                exploitStatusBadge
            }
            if !appState.exploitStatus.isSuccess {
                Button {
                    appState.runKernelExploitIfNeeded()
                } label: {
                    if appState.kernelExploitRunning {
                        Label("Running…", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("Activate Kernel Exploit", systemImage: "bolt.fill")
                    }
                }
                .disabled(appState.kernelExploitRunning || appState.exploitStatus.isSuccess)
            }
        } header: {
            Text("Kernel Exploit (opa334)")
        } footer: {
            Text("Required for filesystem access on iOS 17–18. Runs once per reboot.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private var exploitStatusBadge: some View {
        switch appState.exploitStatus {
        case .notStarted:
            Text("Not Started").foregroundStyle(.secondary)
        case .success:
            Text("Active").foregroundStyle(.green).fontWeight(.semibold)
        case .failed:
            Text("Failed").foregroundStyle(.red)
        case .unsupported:
            Text("Unsupported").foregroundStyle(.orange)
        }
    }

    // MARK: - Mounted Folders Section (iOS 27+)

    private var mountedFoldersSection: some View {
        Section {
            if bookmarkManager.mountedFolders.isEmpty {
                Text("No folders mounted yet.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(bookmarkManager.mountedFolders) { folder in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.displayName)
                                .font(.subheadline.weight(.medium))
                            if let bid = folder.bundleID {
                                Text(bid)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(folder.url.path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Circle()
                            .fill(folder.isActive ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            bookmarkManager.unmount(folder.url)
                        } label: {
                            Label("Unmount", systemImage: "eject.fill")
                        }
                    }
                }
            }

            Button {
                Task { await rescanContainers() }
            } label: {
                if isScanning {
                    Label("Scanning…", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("Rescan & Mount Containers", systemImage: "plus.circle")
                }
            }
            .disabled(isScanning)

            if !bookmarkManager.mountedFolders.isEmpty {
                Button(role: .destructive) {
                    bookmarkManager.unmountAll()
                } label: {
                    Label("Unmount All", systemImage: "eject.circle.fill")
                }
            }
        } header: {
            Text("Mounted Folders (BookmarkManager)")
        } footer: {
            Text("Security-Scoped Folder Mounts give full read/write access to other app containers on iOS 27+. Mounts persist across launches.")
                .font(.caption)
        }
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        Section("Quick Actions") {
            Button {
                accessManager.refresh()
            } label: {
                Label("Refresh Access Status", systemImage: "arrow.clockwise.circle")
            }
            if accessManager.activeBackend != .kernelExploit {
                Button {
                    Task { await rescanContainers() }
                } label: {
                    if isScanning {
                        Label("Scanning…", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("Rescan Containers", systemImage: "magnifyingglass.circle")
                    }
                }
                .disabled(isScanning)
            }
        }
    }

    // MARK: - Rescan

    private func rescanContainers() async {
        isScanning = true
        scanError = nil
        defer { isScanning = false }
        do {
            let found = try await accessManager.rescanContainers()
            // For BookmarkManager: auto-mount the first batch of containers found
            if accessManager.activeBackend == .bookmarkManager {
                for container in found.prefix(5) {
                    _ = try? await BookmarkManager.shared.mount(container.url, containerInfo: container)
                }
            }
        } catch {
            scanError = error.localizedDescription
        }
    }
}
