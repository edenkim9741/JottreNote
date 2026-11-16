import SwiftUI
import UniformTypeIdentifiers

private enum ZoteroNoteOrientation: String, CaseIterable, Identifiable {
    case portrait
    case landscape

    var id: String { rawValue }

    var title: String {
        String(localized: "zotero.create.orientation.\(rawValue)")
    }

    var pageSize: CGSize {
        switch self {
        case .portrait: CGSize(width: 1200, height: 1600)
        case .landscape: CGSize(width: 1600, height: 1200)
        }
    }
}

struct ZoteroCreateDocumentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var orientation: ZoteroNoteOrientation = .portrait
    @State private var errorMessage: String?
    @State private var isCreating = false
    let onCreate: @MainActor (String, CGSize) async -> String?

    var body: some View {
        NavigationStack {
            Form {
                HStack {
                    TextField(String(localized: "zotero.create.titlePlaceholder"), text: $title)
                        .textInputAutocapitalization(.sentences)
                    if !title.isEmpty {
                        Button {
                            title = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "zotero.create.clearTitle"))
                    }
                }
                Picker(String(localized: "zotero.create.orientation"), selection: $orientation) {
                    ForEach(ZoteroNoteOrientation.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(String(localized: "zotero.create.newDocument"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action.cancel")) { dismiss() }
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            isCreating = true
                            defer { isCreating = false }
                            if let message = await onCreate(title, orientation.pageSize) {
                                errorMessage = message
                            } else {
                                dismiss()
                            }
                        }
                    } label: {
                        if isCreating { ProgressView() } else { Text(String(localized: "zotero.create.create")) }
                    }
                    .disabled(isCreating || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct ZoteroPDFItemCreationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var types: [ZoteroItemTypeDefinition] = []
    @State private var selectedTypeID = ""
    @State private var schema: ZoteroItemTypeSchema?
    @State private var metadata: [String: String]
    @State private var creators: [CreatorDraft] = []
    @State private var isLoading = true
    @State private var isCreating = false
    @State private var didConfirmItemType = false
    @State private var errorMessage: String?

    let filename: String
    let loadTypes: @MainActor () async -> [ZoteroItemTypeDefinition]
    let loadSchema: @MainActor (ZoteroItemTypeDefinition) async -> ZoteroItemTypeSchema?
    let onCreate: @MainActor (ZoteroItemTypeSchema, [String: String], [ZoteroCreator]) async -> String?

    init(
        filename: String,
        loadTypes: @escaping @MainActor () async -> [ZoteroItemTypeDefinition],
        loadSchema: @escaping @MainActor (ZoteroItemTypeDefinition) async -> ZoteroItemTypeSchema?,
        onCreate: @escaping @MainActor (ZoteroItemTypeSchema, [String: String], [ZoteroCreator]) async -> String?
    ) {
        self.filename = filename
        self.loadTypes = loadTypes
        self.loadSchema = loadSchema
        self.onCreate = onCreate
        let title = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        _metadata = State(initialValue: ["title": title])
    }

    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    ProgressView(String(localized: "zotero.import.loadingSchema"))
                } else if types.isEmpty {
                    ContentUnavailableView(
                        String(localized: "zotero.import.schemaUnavailable"),
                        systemImage: "wifi.exclamationmark",
                        description: Text(String(localized: "zotero.import.schemaUnavailableDetail"))
                    )
                } else {
                    Section(String(localized: "zotero.import.itemType")) {
                        Picker(String(localized: "zotero.import.itemType"), selection: $selectedTypeID) {
                            Text(String(localized: "zotero.import.selectItemType")).tag("")
                            ForEach(types) { type in
                                Text(type.localized).tag(type.itemType)
                            }
                        }
                        .onChange(of: selectedTypeID) { _, typeID in
                            Task { await selectType(typeID) }
                        }
                    }

                    if didConfirmItemType, let schema {
                        metadataSection(schema: schema)
                        creatorSection(schema: schema)
                    }
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle(String(localized: "zotero.import.createItemFromPDF"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action.cancel")) { dismiss() }
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if didConfirmItemType {
                            Task { await createItem() }
                        } else {
                            didConfirmItemType = true
                        }
                    } label: {
                        if isCreating || isLoading {
                            ProgressView()
                        } else {
                            Text(
                                String(
                                    localized: didConfirmItemType
                                        ? "zotero.create.create"
                                        : "zotero.import.continue"
                                )
                            )
                        }
                    }
                    .disabled(
                        isCreating || isLoading || schema == nil || selectedTypeID.isEmpty
                            || (didConfirmItemType && (titleValue.isEmpty || !creatorsAreValid))
                    )
                }
            }
        }
        .presentationDetents([.large])
        .task { await loadSchemaCatalog() }
    }

    private var titleValue: String {
        metadata["title"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var creatorsAreValid: Bool {
        guard let schema else { return false }
        return creators.allSatisfy { draft in
            let hasName = !draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return !hasName || schema.creatorTypes.contains(where: { $0.creatorType == draft.creatorType })
        }
    }

    private func metadataSection(schema: ZoteroItemTypeSchema) -> some View {
        let supported = Set(schema.fields.map(\.field))
        let hiddenFields = metadata.keys.filter { !supported.contains($0) }
        return Group {
            Section(String(localized: "zotero.import.metadata")) {
                if supported.contains("title") {
                    TextField(String(localized: "zotero.document.metadata.title"), text: textBinding(for: "title"))
                        .textInputAutocapitalization(.sentences)
                }
                if supported.contains("date") {
                    TextField(String(localized: "zotero.document.metadata.date"), text: textBinding(for: "date"))
                        .keyboardType(.numbersAndPunctuation)
                }
                ForEach(schema.fields.filter { $0.field != "title" && $0.field != "date" }) { field in
                    TextField(field.localized, text: textBinding(for: field.field))
                }
                if !hiddenFields.isEmpty {
                    Text(String(localized: "zotero.import.fieldsNotSavedForType"))
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func creatorSection(schema: ZoteroItemTypeSchema) -> some View {
        Section(String(localized: "zotero.import.creators")) {
            ForEach($creators) { $draft in
                VStack(alignment: .leading, spacing: 10) {
                    Picker(String(localized: "zotero.import.creatorRole"), selection: $draft.creatorType) {
                        ForEach(schema.creatorTypes) { type in
                            Text(type.localized).tag(type.creatorType)
                        }
                        if !schema.creatorTypes.contains(where: { $0.creatorType == draft.creatorType }) {
                            Text(String(localized: "zotero.import.unsupportedCreatorRole")).tag(draft.creatorType)
                        }
                    }
                    Toggle(String(localized: "zotero.import.organizationCreator"), isOn: $draft.isOrganization)
                    if draft.isOrganization {
                        TextField(String(localized: "zotero.import.creatorName"), text: $draft.name)
                    } else {
                        TextField(String(localized: "zotero.import.creatorFirstName"), text: $draft.firstName)
                        TextField(String(localized: "zotero.import.creatorLastName"), text: $draft.lastName)
                    }
                    Button(role: .destructive) {
                        creators.removeAll { $0.id == draft.id }
                    } label: {
                        Label(String(localized: "zotero.import.removeCreator"), systemImage: "minus.circle")
                    }
                    .font(.footnote)
                }
                .padding(.vertical, 4)
            }
            if let firstCreatorType = schema.creatorTypes.first?.creatorType {
                Button {
                    creators.append(CreatorDraft(creatorType: firstCreatorType))
                } label: {
                    Label(String(localized: "zotero.import.addCreator"), systemImage: "plus.circle")
                }
            }
            if !creators.isEmpty && !creatorsAreValid {
                Text(String(localized: "zotero.import.invalidCreatorRole"))
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private func textBinding(for field: String) -> Binding<String> {
        Binding(
            get: { metadata[field] ?? "" },
            set: { metadata[field] = $0 }
        )
    }

    private func loadSchemaCatalog() async {
        types = await loadTypes()
        isLoading = false
        guard !types.isEmpty else {
            errorMessage = String(localized: "zotero.import.schemaUnavailableDetail")
            return
        }
    }

    private func selectType(_ typeID: String) async {
        guard let type = types.first(where: { $0.itemType == typeID }) else {
            schema = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        guard let loaded = await loadSchema(type) else {
            schema = nil
            errorMessage = String(localized: "zotero.import.schemaUnavailableDetail")
            return
        }
        schema = loaded
        errorMessage = nil
        if creators.isEmpty, let firstCreatorType = loaded.creatorTypes.first?.creatorType {
            creators = [CreatorDraft(creatorType: firstCreatorType, isOrganization: loaded.creatorUsesSingleName)]
        }
    }

    private func createItem() async {
        guard let schema else { return }
        isCreating = true
        defer { isCreating = false }
        let validFields = Set(schema.fields.map(\.field))
        let payload = metadata.filter { validFields.contains($0.key) }
        let creatorValues = creators.map(\.zoteroCreator)
        if let message = await onCreate(schema, payload, creatorValues) {
            errorMessage = message
        } else {
            dismiss()
        }
    }

    private struct CreatorDraft: Identifiable {
        let id = UUID()
        var creatorType: String
        var firstName = ""
        var lastName = ""
        var name = ""
        var isOrganization = false

        init(creatorType: String, isOrganization: Bool = false) {
            self.creatorType = creatorType
            self.isOrganization = isOrganization
        }

        var displayName: String {
            isOrganization ? name : [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
        }

        var zoteroCreator: ZoteroCreator {
            ZoteroCreator(
                creatorType: creatorType,
                firstName: isOrganization ? "" : firstName,
                lastName: isOrganization ? "" : lastName,
                name: isOrganization ? name : ""
            )
        }
    }
}

struct ZoteroMetadataEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var creators: String
    @State private var date: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    let item: ZoteroItem
    let onSave: @MainActor (String, [String], String) async -> Void

    init(item: ZoteroItem, onSave: @escaping @MainActor (String, [String], String) async -> Void) {
        self.item = item
        self.onSave = onSave
        _title = State(initialValue: item.title)
        _creators = State(initialValue: item.creators.joined(separator: ", "))
        _date = State(initialValue: item.year ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(String(localized: "zotero.document.metadata.title"), text: $title)
                TextField(String(localized: "zotero.document.metadata.creators"), text: $creators)
                TextField(String(localized: "zotero.document.metadata.date"), text: $date)
                    .keyboardType(.numbersAndPunctuation)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle(String(localized: "zotero.document.editMetadata"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action.cancel")) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "action.save")) {
                        Task {
                            isSaving = true
                            await onSave(
                                title.trimmingCharacters(in: .whitespacesAndNewlines),
                                creators.split(separator: ",").map {
                                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                                },
                                date.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct ZoteroCollectionPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let collections: [ZoteroCollection]
    let onSelect: (String?) -> Void

    private var orderedCollections: [ZoteroCollection] {
        collections.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onSelect(nil)
                    dismiss()
                } label: {
                    Label(String(localized: "zotero.document.move.unfiled"), systemImage: "tray")
                }
                ForEach(orderedCollections) { collection in
                    Button {
                        onSelect(collection.key)
                        dismiss()
                    } label: {
                        Label(collection.name, systemImage: "folder")
                    }
                }
            }
            .navigationTitle(String(localized: "zotero.document.move"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action.cancel")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
