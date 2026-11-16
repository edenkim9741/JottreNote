import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ZoteroLibraryView: View {
    @StateObject private var model: ZoteroLibraryViewModel
    @ObservedObject private var syncProgress: ZoteroSyncProgress
    @State private var showingSettings = false
    @State private var showingNewDocument = false
    @State private var newNoteParentKey: String?
    @State private var showingPDFImporter = false
    @State private var showingAttachmentImporter = false
    @State private var showingPDFCreation = false
    @State private var pendingAttachmentParentKey: String?
    @State private var importedPDFData: Data?
    @State private var importedPDFName: String?
    @State private var creationNotice: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var expandedAttachmentGroups = Set<String>()
    @State private var editingItem: ZoteroItem?
    @State private var movingItemKeys = Set<String>()
    @State private var showingMovePicker = false
    @State private var pendingTrashKeys = Set<String>()
    @State private var showingTrashConfirmation = false
    @State private var resolvingConflict: ZoteroAttachment?
    @State private var pendingRemoteRestore: ZoteroAttachment?
    @State private var remoteRestoreBackupURLs: [URL]?
    @State private var showingRemoteRestoreBackupShare = false

    init(
        cacheStore: ZoteroCacheStore,
        engine: ZoteroSyncEngine,
        syncProgress: ZoteroSyncProgress,
        defaults: DefaultsService,
        onOpenJot: @escaping (JotFile.Info) -> Void
    ) {
        let viewModel = ZoteroLibraryViewModel(cacheStore: cacheStore, engine: engine, defaults: defaults)
        viewModel.onOpenJot = onOpenJot
        _model = StateObject(wrappedValue: viewModel)
        _syncProgress = ObservedObject(wrappedValue: syncProgress)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List {
                locationButton(
                    String(localized: "zotero.sidebar.myLibrary"),
                    symbol: "books.vertical",
                    location: .myLibrary
                )
                ForEach(model.childCollections(of: nil)) { collection in
                    ZoteroCollectionTreeRow(
                        collection: collection,
                        children: { model.childCollections(of: $0) },
                        onSelect: { model.selection = .collection($0) }
                    )
                }
                locationButton(
                    String(localized: "zotero.sidebar.unfiled"),
                    symbol: "tray",
                    location: .unfiled
                )
                locationButton(
                    String(localized: "zotero.sidebar.trash"),
                    symbol: "trash",
                    location: .trash
                )
            }
            .listStyle(.sidebar)
            .contentMargins(.top, 0, for: .scrollContent)
            .toolbar(removing: .sidebarToggle)
            .safeAreaInset(edge: .bottom, alignment: .leading, spacing: 0) {
                HStack(spacing: 20) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(String(localized: "zotero.sidebar.accountSettings"))

                    if syncProgress.isSyncing {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(syncProgress.syncStatusMessage).lineLimit(1)
                                Spacer(minLength: 4)
                                if syncProgress.syncProgress > 0 {
                                    Text("\(Int((syncProgress.syncProgress * 100).rounded()))%")
                                        .monospacedDigit()
                                }
                            }
                            .font(.caption)
                            ProgressView(value: syncProgress.syncProgress > 0 ? syncProgress.syncProgress : nil)
                                .tint(.accentColor)
                        }
                        .frame(maxWidth: 260)
                        .accessibilityElement(children: .combine)
                    } else {
                        Button {
                            Task { await model.synchronize(trigger: .manual) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel(String(localized: "zotero.sidebar.syncLibrary"))
                    }
                }
                .buttonStyle(.plain)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.regularMaterial)
            }
        } detail: {
            attachmentList
                .toolbar(removing: .sidebarToggle)
        }
        .sheet(isPresented: $showingSettings) {
            ZoteroAccountSettingsView(defaults: DefaultsService(userDefaults: .standard)) {
                Task { await model.reloadAccountAndSynchronize() }
            }
        }
        .sheet(
            isPresented: $showingNewDocument,
            onDismiss: {
                newNoteParentKey = nil
            }
        ) {
            ZoteroCreateDocumentSheet { title, pageSize in
                let result = await model.createDocument(
                    title: title,
                    pageSize: pageSize,
                    parentItemKey: newNoteParentKey
                )
                if result == String(localized: "zotero.create.offlineDraft") {
                    creationNotice = result
                    return nil
                }
                return result
            }
        }
        .sheet(
            isPresented: $showingPDFCreation,
            onDismiss: {
                importedPDFData = nil
                importedPDFName = nil
            }
        ) {
            if let importedPDFData, let importedPDFName {
                ZoteroPDFItemCreationSheet(
                    filename: importedPDFName,
                    loadTypes: { await model.itemTypes() },
                    loadSchema: { await model.itemTypeSchema(for: $0) },
                    onCreate: { schema, metadata, creators in
                        let result = await model.createImportedPDF(
                            data: importedPDFData,
                            filename: importedPDFName,
                            schema: schema,
                            metadata: metadata,
                            creators: creators
                        )
                        if result == String(localized: "zotero.create.offlineDraft") {
                            creationNotice = result
                            return nil
                        }
                        return result
                    }
                )
            }
        }
        .fileImporter(isPresented: $showingPDFImporter, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url):
                do {
                    let data = try ExternalFileImportService().readExternalFile(
                        sourceURL: url,
                        maximumFileSize: 128 * 1_024 * 1_024
                    )
                    guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else {
                        creationNotice = String(localized: "zotero.import.invalidPDF")
                        return
                    }
                    importedPDFData = data
                    importedPDFName = url.lastPathComponent
                    showingPDFCreation = true
                } catch ExternalFileImportService.Failure.fileTooLarge {
                    creationNotice = String(localized: "zotero.import.pdfTooLarge")
                } catch {
                    creationNotice = error.localizedDescription
                }
            case .failure(let error):
                showImportErrorUnlessCancelled(error)
            }
        }
        .fileImporter(isPresented: $showingAttachmentImporter, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url):
                guard let parentKey = pendingAttachmentParentKey else { return }
                do {
                    let data = try ExternalFileImportService().readExternalFile(
                        sourceURL: url,
                        maximumFileSize: 128 * 1_024 * 1_024
                    )
                    Task {
                        if let message = await model.addPDFAttachment(
                            data: data,
                            filename: url.lastPathComponent,
                            to: parentKey
                        ) {
                            creationNotice = message
                        }
                    }
                } catch ExternalFileImportService.Failure.fileTooLarge {
                    creationNotice = String(localized: "zotero.import.pdfTooLarge")
                } catch {
                    creationNotice = error.localizedDescription
                }
                pendingAttachmentParentKey = nil
            case .failure(let error):
                pendingAttachmentParentKey = nil
                showImportErrorUnlessCancelled(error)
            }
        }
        .sheet(item: $editingItem) { item in
            ZoteroMetadataEditorSheet(item: item) { title, creators, date in
                await model.updateMetadata(itemKey: item.key, title: title, creators: creators, date: date)
            }
        }
        .sheet(isPresented: $showingMovePicker) {
            ZoteroCollectionPickerSheet(collections: Array(model.snapshot.collections.values)) { collectionKey in
                Task { await model.moveItems(movingItemKeys, to: collectionKey) }
            }
        }
        .sheet(item: $resolvingConflict) { conflict in
            ZoteroConflictResolverView(
                attachment: conflict,
                item: model.snapshot.items[conflict.key],
                original: model.originalAttachment(for: conflict),
                onKeepLocal: { await model.keepConflictLocal(conflict.key) },
                onKeepServer: { await model.keepConflictServer(conflict.key) },
                onKeepBoth: { await model.keepConflictBoth(conflict.key) },
                onDeleteConflictCopy: { await model.deleteConflictCopy(conflict.key) }
            )
        }
        .confirmationDialog(
            String(
                localized: model.selection == .trash
                    ? "zotero.document.deletePermanently.confirmTitle"
                    : "zotero.document.trash.confirmTitle"
            ),
            isPresented: $showingTrashConfirmation,
            titleVisibility: .visible
        ) {
            if model.selection == .trash {
                Button(String(localized: "zotero.document.deletePermanently"), role: .destructive) {
                    Task { await model.permanentlyDeleteItems(pendingTrashKeys) }
                }
            } else {
                Button(String(localized: "zotero.document.trash"), role: .destructive) {
                    Task { await model.trashItems(pendingTrashKeys) }
                }
            }
            Button(String(localized: "action.cancel"), role: .cancel) {}
        } message: {
            Text(
                String(
                    localized: model.selection == .trash
                        ? "zotero.document.deletePermanently.confirmMessage"
                        : "zotero.document.trash.confirmMessage"
                )
            )
        }
        .confirmationDialog(
            String(localized: "zotero.forceRestore.confirm.title", defaultValue: "원격 버전으로 복구하시겠습니까?"),
            isPresented: Binding(
                get: { pendingRemoteRestore != nil },
                set: { if !$0 { pendingRemoteRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let attachment = pendingRemoteRestore {
                Button(
                    String(localized: "zotero.forceRestore.confirm.action", defaultValue: "원격 버전으로 복구"),
                    role: .destructive
                ) {
                    pendingRemoteRestore = nil
                    Task {
                        do {
                            remoteRestoreBackupURLs = try await model.restoreRemoteVersion(attachment)
                            creationNotice = String(
                                localized: "zotero.forceRestore.success",
                                defaultValue: "원격 PDF를 복구했습니다. 백업은 공유하거나 보관할 수 있습니다."
                            )
                        } catch {
                            remoteRestoreBackupURLs = model.remoteRestoreBackupURLs
                            creationNotice = error.localizedDescription
                        }
                    }
                }
                .disabled(model.restoringAttachmentKey != nil || model.isSyncing)
            }
            Button(String(localized: "action.cancel"), role: .cancel) { pendingRemoteRestore = nil }
        } message: {
            Text(
                String(
                    localized: "zotero.forceRestore.confirm.message",
                    defaultValue:
                        "서버에 저장된 PDF를 다시 다운로드하여 현재 로컬 버전을 대체합니다. 서버에 동기화되지 않은 필기나 수정 내용은 현재 문서에 표시되지 않을 수 있습니다. 복구 가능한 로컬 데이터는 별도 백업으로 보존합니다."
                )
            )
        }
        .alert(
            "Zotero",
            isPresented: Binding(
                get: { creationNotice != nil },
                set: { if !$0 { creationNotice = nil } }
            )
        ) {
            if remoteRestoreBackupURLs != nil {
                Button(String(localized: "zotero.forceRestore.shareBackup", defaultValue: "로컬 백업 공유")) {
                    creationNotice = nil
                    showingRemoteRestoreBackupShare = true
                }
            }
            Button(String(localized: "action.ok"), role: .cancel) { creationNotice = nil }
        } message: {
            Text(creationNotice ?? "")
        }
        .sheet(isPresented: $showingRemoteRestoreBackupShare) {
            if let remoteRestoreBackupURLs {
                ZoteroRestoreBackupShareSheet(items: remoteRestoreBackupURLs)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoteroAttachmentCacheChanged)) { _ in
            model.refreshCacheState()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            model.refreshCacheState()
            Task { await model.synchronize(trigger: .periodic) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoteroEditorDidEnd)) { _ in
            Task { await model.synchronize(trigger: .editorFinished) }
        }
    }

    private func locationButton(
        _ title: String,
        symbol: String,
        location: ZoteroLibraryLocation
    ) -> some View {
        Button {
            model.selection = location
        } label: {
            Label(title, systemImage: symbol)
                .foregroundStyle(model.selection == location ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func showImportErrorUnlessCancelled(_ error: Error) {
        let cocoaError = error as NSError
        guard cocoaError.domain != NSCocoaErrorDomain || cocoaError.code != NSUserCancelledError else { return }
        creationNotice = error.localizedDescription
    }

    private var attachmentList: some View {
        let groups = model.attachmentGroups(for: model.selection)
        return List {
            HStack(spacing: 12) {
                Text(title(for: model.selection))
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Button(
                    model.isSelecting
                        ? String(localized: "zotero.document.selection.done")
                        : String(localized: "zotero.document.selection.select")
                ) {
                    model.setSelectionMode(!model.isSelecting)
                }
                .buttonStyle(.borderless)
                Menu {
                    Button {
                        showingNewDocument = true
                    } label: {
                        Label(String(localized: "zotero.create.newDocument"), systemImage: "doc.badge.plus")
                    }
                    Button {
                        showingPDFImporter = true
                    } label: {
                        Label(String(localized: "zotero.import.createItemFromPDF"), systemImage: "doc.viewfinder")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "zotero.create.newDocument"))
                Menu {
                    ForEach(ZoteroAttachmentSortOrder.allCases) { order in
                        Button {
                            model.selectSortOrder(order)
                        } label: {
                            if model.sortOrder == order {
                                let isAscending = order == .title ? !model.isSortReversed : model.isSortReversed
                                Label(order.title, systemImage: isAscending ? "arrow.up" : "arrow.down")
                            } else {
                                Text(order.title)
                            }
                        }
                        .accessibilityIdentifier("zotero.sort.\(order.rawValue)")
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "zotero.sort.menu"))
                .accessibilityIdentifier("zotero.sort")
                .accessibilityValue(Text(model.sorting.accessibilityDescription))
                Button {
                    withAnimation {
                        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(
                    String(
                        localized: columnVisibility == .detailOnly
                            ? "zotero.sidebar.showSidebar"
                            : "zotero.sidebar.hideSidebar"
                    )
                )
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 12, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityAddTraits(.isHeader)

            ForEach(groups) { group in
                DisclosureGroup(isExpanded: expandedBinding(for: group.key)) {
                    ForEach(group.attachments) { attachment in
                        attachmentRow(
                            attachment,
                            title: attachment.filename,
                            subtitle: "",
                            selectionKey: attachmentSelectionKey(attachment, groupKey: group.key)
                        )
                    }
                    if !model.isSelecting,
                        model.selection != .trash,
                        let groupItem = model.snapshot.items[group.key],
                        groupItem.parentItemKey == nil,
                        !["attachment", "note", "annotation"].contains(groupItem.itemType),
                        !groupItem.isTrashed
                    {
                        Menu {
                            Button {
                                pendingAttachmentParentKey = group.key
                                expandedAttachmentGroups.insert(group.key)
                                showingAttachmentImporter = true
                            } label: {
                                Label(String(localized: "zotero.import.addPDF"), systemImage: "doc.badge.plus")
                            }
                            Button {
                                newNoteParentKey = group.key
                                expandedAttachmentGroups.insert(group.key)
                                showingNewDocument = true
                            } label: {
                                Label(String(localized: "zotero.import.addNote"), systemImage: "square.and.pencil")
                            }
                        } label: {
                            Label(String(localized: "zotero.import.addAttachment"), systemImage: "plus")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.borderless)
                    }
                } label: {
                    HStack(spacing: 10) {
                        if model.isSelecting { selectionIndicator(for: group.key) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.title).font(.headline).lineLimit(2)
                            if !group.subtitle.isEmpty {
                                Text(group.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        Text("\(group.attachments.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        if model.selection != .trash || model.snapshot.items[group.key]?.isTrashed == true {
                            documentContextMenu(itemKey: group.key)
                        }
                    }
                }
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isSelecting {
                HStack(spacing: 16) {
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "zotero.document.selection.count"),
                            model.selectedItemKeys.count
                        )
                    )
                    Spacer()
                    Button {
                        movingItemKeys = model.selectedItemKeys
                        showingMovePicker = true
                    } label: {
                        Label(String(localized: "zotero.document.move"), systemImage: "folder")
                    }
                    .disabled(model.selectedItemKeys.isEmpty)
                    if model.selection == .trash {
                        Button {
                            Task { await model.restoreItems(model.selectedItemKeys) }
                        } label: {
                            Label(String(localized: "zotero.document.restore"), systemImage: "arrow.uturn.backward")
                        }
                        .disabled(model.selectedItemKeys.isEmpty)
                        Button(role: .destructive) {
                            pendingTrashKeys = model.selectedItemKeys
                            showingTrashConfirmation = true
                        } label: {
                            Label(String(localized: "zotero.document.deletePermanently"), systemImage: "trash")
                        }
                        .disabled(model.selectedItemKeys.isEmpty)
                    } else {
                        Button(role: .destructive) {
                            pendingTrashKeys = model.selectedItemKeys
                            showingTrashConfirmation = true
                        } label: {
                            Label(String(localized: "zotero.document.trash"), systemImage: "trash")
                        }
                        .disabled(model.selectedItemKeys.isEmpty)
                    }
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView(
                    String(localized: "zotero.empty.title"),
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(
                        model.errorMessage
                            ?? (model.isSyncing
                                ? String(localized: "zotero.empty.syncing")
                                : String(localized: "zotero.empty.noPDF"))
                    )
                )
            }
        }
        .alert(
            String(localized: "zotero.error.title"),
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.clearError() } }
            )
        ) {
            Button(String(localized: "zotero.common.ok"), role: .cancel) { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func attachmentRow(
        _ attachment: ZoteroAttachment,
        title: String,
        subtitle: String,
        selectionKey: String
    ) -> some View {
        let displayStatus = model.displayStatus(for: attachment)
        return Button {
            if model.isSelecting {
                model.toggleSelection(for: selectionKey)
            } else if attachment.isConflict {
                resolvingConflict = attachment
            } else {
                Task { await model.open(attachment) }
            }
        } label: {
            HStack(spacing: 12) {
                if model.isSelecting { selectionIndicator(for: selectionKey) }
                Image(systemName: statusSymbol(displayStatus))
                    .foregroundStyle(statusColor(displayStatus))
                    .frame(width: 24)
                    .accessibilityLabel(statusDescription(displayStatus))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).lineLimit(2)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                if attachment.isConflict {
                    Label(String(localized: "zotero.conflict.badge"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                if model.openingAttachmentKey == attachment.key || model.restoringAttachmentKey == attachment.key {
                    ProgressView()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            documentContextMenu(itemKey: selectionKey)
            if model.shouldOfferRemoteRestore(for: attachment) {
                Button {
                    model.recordRemoteRestoreRequest(for: attachment)
                    pendingRemoteRestore = attachment
                } label: {
                    Label(
                        String(localized: "zotero.forceRestore.menu", defaultValue: "원격 버전으로 복구"),
                        systemImage: "arrow.clockwise.icloud"
                    )
                }
                .disabled(model.restoringAttachmentKey != nil || model.isSyncing)
            }
        }
    }

    private func attachmentSelectionKey(_ attachment: ZoteroAttachment, groupKey: String) -> String {
        if model.selection == .trash,
            model.snapshot.items[attachment.key]?.isTrashed == true
        {
            return attachment.key
        }
        return groupKey
    }

    @ViewBuilder
    private func selectionIndicator(for key: String) -> some View {
        Image(systemName: model.selectedItemKeys.contains(key) ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(model.selectedItemKeys.contains(key) ? Color.accentColor : Color.secondary)
            .font(.title3)
            .accessibilityLabel(
                model.selectedItemKeys.contains(key)
                    ? String(localized: "zotero.document.selection.selected")
                    : String(localized: "zotero.document.selection.notSelected")
            )
    }

    @ViewBuilder
    private func documentContextMenu(itemKey: String) -> some View {
        if let item = model.snapshot.items[itemKey], ZoteroSyncService.isValidKey(itemKey) {
            if model.selection == .trash || item.isTrashed {
                Button {
                    Task { await model.restoreItems([itemKey]) }
                } label: {
                    Label(String(localized: "zotero.document.restore"), systemImage: "arrow.uturn.backward")
                }
                Button(role: .destructive) {
                    pendingTrashKeys = [itemKey]
                    showingTrashConfirmation = true
                } label: {
                    Label(String(localized: "zotero.document.deletePermanently"), systemImage: "trash")
                }
            } else {
                if item.parentItemKey == nil,
                    !["attachment", "note", "annotation"].contains(item.itemType)
                {
                    Menu {
                        Button {
                            pendingAttachmentParentKey = itemKey
                            expandedAttachmentGroups.insert(itemKey)
                            showingAttachmentImporter = true
                        } label: {
                            Label(String(localized: "zotero.import.addPDF"), systemImage: "doc.badge.plus")
                        }
                        Button {
                            newNoteParentKey = itemKey
                            expandedAttachmentGroups.insert(itemKey)
                            showingNewDocument = true
                        } label: {
                            Label(String(localized: "zotero.import.addNote"), systemImage: "square.and.pencil")
                        }
                    } label: {
                        Label(String(localized: "zotero.import.addAttachment"), systemImage: "plus")
                    }
                }
                Button {
                    editingItem = item
                } label: {
                    Label(String(localized: "zotero.document.editMetadata"), systemImage: "pencil")
                }
                Button {
                    movingItemKeys = [itemKey]
                    showingMovePicker = true
                } label: {
                    Label(String(localized: "zotero.document.move"), systemImage: "folder")
                }
                Button(role: .destructive) {
                    pendingTrashKeys = [itemKey]
                    showingTrashConfirmation = true
                } label: {
                    Label(String(localized: "zotero.document.trash"), systemImage: "trash")
                }
            }
        }
    }

    private func expandedBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { expandedAttachmentGroups.contains(key) },
            set: { expanded in
                if expanded { expandedAttachmentGroups.insert(key) } else { expandedAttachmentGroups.remove(key) }
            }
        )
    }

    private func title(for location: ZoteroLibraryLocation) -> String {
        switch location {
        case .myLibrary: String(localized: "zotero.sidebar.myLibrary")
        case .collection(let key):
            model.snapshot.collections[key]?.name ?? String(localized: "zotero.sidebar.collectionFallback")
        case .unfiled: String(localized: "zotero.sidebar.unfiled")
        case .trash: String(localized: "zotero.sidebar.trash")
        }
    }

    private func statusDescription(_ status: ZoteroAttachmentDisplayStatus) -> String {
        switch status {
        case .cloudOnly: String(localized: "zotero.status.cloudOnly")
        case .downloaded: String(localized: "zotero.status.downloaded")
        case .pendingSync: String(localized: "zotero.status.pendingSync")
        case .missingLocalChanges: String(localized: "zotero.status.missingLocalChanges")
        }
    }

    private func statusSymbol(_ status: ZoteroAttachmentDisplayStatus) -> String {
        switch status {
        case .cloudOnly: "icloud"
        case .downloaded: "arrow.down.circle.fill"
        case .pendingSync: "arrow.triangle.2.circlepath"
        case .missingLocalChanges: "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(_ status: ZoteroAttachmentDisplayStatus) -> Color {
        switch status {
        case .pendingSync, .missingLocalChanges: .orange
        case .cloudOnly, .downloaded: .secondary
        }
    }
}

private struct ZoteroCollectionTreeRow: View {
    let collection: ZoteroCollection
    let children: (String) -> [ZoteroCollection]
    let onSelect: (String) -> Void

    private var childCollections: [ZoteroCollection] {
        children(collection.key)
    }

    var body: some View {
        if childCollections.isEmpty {
            Button {
                onSelect(collection.key)
            } label: {
                Label(collection.name, systemImage: "folder")
            }
            .buttonStyle(.plain)
        } else {
            DisclosureGroup {
                ForEach(childCollections) { child in
                    ZoteroCollectionTreeRow(
                        collection: child,
                        children: children,
                        onSelect: onSelect
                    )
                }
            } label: {
                Button {
                    onSelect(collection.key)
                } label: {
                    Label(collection.name, systemImage: "folder")
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ZoteroRestoreBackupShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
