import SwiftUI

struct ZoteroAccountSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var userID: String
    @State private var apiKey: String
    @State private var webDAVURL: String
    @State private var webDAVUsername: String
    @State private var webDAVPassword: String
    @State private var defaultAuthorFirstName: String
    @State private var defaultAuthorLastName: String
    @State private var defaultAuthorFullName: String
    @State private var isResolvingUserID = false
    @State private var statusMessage: String?
    @State private var localSnapshot: ZoteroCacheSnapshot
    @State private var selectedLocalKeys = Set<String>()
    @State private var localCacheMessage: String?

    private let defaults: DefaultsService
    private let keychain = KeychainCredentialStore()
    private let cacheStore = ZoteroCacheStore()
    private let onSaved: @MainActor () -> Void

    init(defaults: DefaultsService, onSaved: @escaping @MainActor () -> Void) {
        self.defaults = defaults
        self.onSaved = onSaved
        _userID = State(initialValue: defaults.getValue(.zoteroUserID) ?? "")
        _apiKey = State(initialValue: KeychainCredentialStore().value(for: "zotero_api_key") ?? "")
        _webDAVURL = State(initialValue: defaults.getValue(.webDAVURL) ?? "")
        _webDAVUsername = State(initialValue: defaults.getValue(.webDAVUsername) ?? "")
        _webDAVPassword = State(initialValue: KeychainCredentialStore().value(for: "webdav_password") ?? "")
        _defaultAuthorFirstName = State(initialValue: defaults.getValue(.zoteroDefaultAuthorFirstName) ?? "")
        _defaultAuthorLastName = State(initialValue: defaults.getValue(.zoteroDefaultAuthorLastName) ?? "")
        _defaultAuthorFullName = State(initialValue: defaults.getValue(.zoteroDefaultAuthorFullName) ?? "")
        _localSnapshot = State(initialValue: .empty(userID: defaults.getValue(.zoteroUserID) ?? ""))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "zotero.settings.account")) {
                    TextField(String(localized: "zotero.settings.userID"), text: $userID)
                        .keyboardType(.numberPad)
                    SecureField(String(localized: "zotero.settings.apiKey"), text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await resolveUserID() }
                    } label: {
                        if isResolvingUserID {
                            ProgressView(String(localized: "zotero.settings.resolvingUserID"))
                        } else {
                            Text(String(localized: "zotero.settings.findUserID"))
                        }
                    }
                    .disabled(apiKey.isEmpty || isResolvingUserID)
                }

                Section(String(localized: "zotero.settings.webdav")) {
                    TextField(String(localized: "zotero.settings.serverURL"), text: $webDAVURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(String(localized: "zotero.settings.username"), text: $webDAVUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(String(localized: "zotero.settings.password"), text: $webDAVPassword)
                }

                Section(String(localized: "zotero.settings.defaultAuthor")) {
                    TextField(String(localized: "zotero.settings.authorFirstName"), text: $defaultAuthorFirstName)
                        .textContentType(.givenName)
                    TextField(String(localized: "zotero.settings.authorLastName"), text: $defaultAuthorLastName)
                        .textContentType(.familyName)
                    TextField(String(localized: "zotero.settings.authorFullName"), text: $defaultAuthorFullName)
                }

                Section {
                    if localDocuments.isEmpty {
                        Text(String(localized: "zotero.settings.localDocumentsEmpty"))
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text(String.localizedStringWithFormat(
                                String(localized: "zotero.settings.localDocumentCount"),
                                localDocuments.count
                            ))
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: localDocuments.reduce(Int64(0)) {
                                $0 + localDocumentSize($1)
                            }, countStyle: .file))
                                .foregroundStyle(.secondary)
                        }

                        Button(role: .destructive) {
                            offloadAll()
                        } label: {
                            Text(String(localized: "zotero.settings.offloadAll"))
                        }
                        .disabled(offloadableKeys.isEmpty)

                        Button(role: .destructive) {
                            offloadSelected()
                        } label: {
                            HStack {
                                Text(String(localized: "zotero.settings.offloadSelected"))
                                Spacer()
                                Text("\(selectedLocalKeys.count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(selectedLocalKeys.isEmpty)

                        ForEach(localDocuments) { attachment in
                            localDocumentRow(attachment)
                        }
                    }
                    if let localCacheMessage {
                        Text(localCacheMessage).foregroundStyle(.secondary)
                    }
                } header: {
                    Text(String(localized: "zotero.settings.localDocuments"))
                } footer: {
                    Text(String(localized: "zotero.settings.localDocumentsFooter"))
                }

                Section {
                    LabeledContent(
                        String(localized: "zotero.settings.appVersion"),
                        value: appVersionDescription
                    )
                }

                if let statusMessage {
                    Section { Text(statusMessage).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(String(localized: "zotero.settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: refreshLocalSnapshot)
            .onReceive(NotificationCenter.default.publisher(for: .zoteroAttachmentCacheChanged)) { _ in
                refreshLocalSnapshot()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "zotero.settings.save")) { save() }
                }
            }
        }
    }

    @MainActor
    private func resolveUserID() async {
        isResolvingUserID = true
        defer { isResolvingUserID = false }
        do {
            userID = try await ZoteroAPIClient(apiKey: apiKey, userID: "").resolveUserID()
            statusMessage = String(localized: "zotero.settings.userIDFound")
        } catch {
            statusMessage = String(localized: "zotero.settings.userIDLookupFailed")
        }
    }

    @MainActor
    private func save() {
        defaults.set(.zoteroUserID, value: userID.trimmingCharacters(in: .whitespacesAndNewlines))
        defaults.set(.webDAVURL, value: webDAVURL.trimmingCharacters(in: .whitespacesAndNewlines))
        defaults.set(.webDAVUsername, value: webDAVUsername.trimmingCharacters(in: .whitespacesAndNewlines))
        defaults.set(.zoteroDefaultAuthorFirstName, value: defaultAuthorFirstName.trimmingCharacters(in: .whitespacesAndNewlines))
        defaults.set(.zoteroDefaultAuthorLastName, value: defaultAuthorLastName.trimmingCharacters(in: .whitespacesAndNewlines))
        defaults.set(.zoteroDefaultAuthorFullName, value: defaultAuthorFullName.trimmingCharacters(in: .whitespacesAndNewlines))
        _ = keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: "zotero_api_key")
        _ = keychain.set(webDAVPassword, for: "webdav_password")
        onSaved()
        dismiss()
    }

    private var appVersionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var localDocuments: [ZoteroAttachment] {
        localSnapshot.attachments.values
            .filter { attachment in
                guard let path = attachment.localCachePath else { return false }
                return FileManager.default.fileExists(atPath: path)
            }
            .sorted { localDocumentTitle($0).localizedCaseInsensitiveCompare(localDocumentTitle($1)) == .orderedAscending }
    }

    private var offloadableKeys: Set<String> {
        Set(localDocuments.filter { $0.syncStatus != .dirty }.map(\.key))
    }

    private func localDocumentRow(_ attachment: ZoteroAttachment) -> some View {
        let isDirty = attachment.syncStatus == .dirty
        let isSelected = selectedLocalKeys.contains(attachment.key)
        return Button {
            guard !isDirty else { return }
            if isSelected { selectedLocalKeys.remove(attachment.key) }
            else { selectedLocalKeys.insert(attachment.key) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(localDocumentTitle(attachment))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Text(attachment.filename)
                        Text(ByteCountFormatter.string(fromByteCount: localDocumentSize(attachment), countStyle: .file))
                        if isDirty {
                            Text(String(localized: "zotero.settings.localDocumentPending"))
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: isDirty ? "arrow.triangle.2.circlepath" : (isSelected ? "checkmark.circle.fill" : "circle"))
                    .foregroundStyle(isDirty ? Color.orange : (isSelected ? Color.accentColor : Color.secondary))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDirty)
    }

    private func localDocumentTitle(_ attachment: ZoteroAttachment) -> String {
        attachment.parentItemKey.flatMap { localSnapshot.items[$0]?.title } ?? attachment.filename
    }

    private func localDocumentSize(_ attachment: ZoteroAttachment) -> Int64 {
        guard let path = attachment.localCachePath,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    @MainActor
    private func refreshLocalSnapshot() {
        let userID = defaults.getValue(.zoteroUserID) ?? ""
        localSnapshot = cacheStore.load(userID: userID)
        selectedLocalKeys.formIntersection(offloadableKeys)
    }

    @MainActor
    private func offloadAll() {
        offload(keys: offloadableKeys, skippedDirtyCount: localDocuments.filter { $0.syncStatus == .dirty }.count)
    }

    @MainActor
    private func offloadSelected() {
        offload(keys: selectedLocalKeys, skippedDirtyCount: 0)
    }

    @MainActor
    private func offload(keys: Set<String>, skippedDirtyCount: Int) {
        guard !keys.isEmpty else { return }
        let userID = defaults.getValue(.zoteroUserID) ?? ""
        do {
            localSnapshot = try cacheStore.offload(keys: keys, userID: userID)
            selectedLocalKeys.subtract(keys)
            localCacheMessage = skippedDirtyCount > 0
                ? String(localized: "zotero.settings.offloadSkippedPending")
                : String(localized: "zotero.settings.offloadComplete")
            NotificationCenter.default.post(name: .zoteroAttachmentCacheChanged, object: nil)
        } catch {
            localCacheMessage = String(localized: "zotero.settings.offloadFailed")
        }
    }
}
