import UIKit

private enum CellExpansionState { case none, collapsed, expanded }

final class FolderPickerViewController: UIViewController {

    private struct FolderNode {
        let folder: FolderBusinessModel
        let depth: Int
        let children: [FolderNode]
    }

    private let pageTitle: String
    private var allFolders: [FolderBusinessModel]
    private let onCreateFolder: (@MainActor (String, URL) async throws -> FolderBusinessModel)?
    private let onConfirm: @MainActor (FolderBusinessModel?) -> Void

    private var rootNodes: [FolderNode] = []
    private var visibleItems: [FolderNode] = []
    private var expandedFolderURLs: Set<URL> = []
    private var hasSelection = false
    private var selectedFolder: FolderBusinessModel?

    init(
        title: String,
        folders: [FolderBusinessModel],
        onCreateFolder: (@MainActor (String, URL) async throws -> FolderBusinessModel)? = nil,
        onConfirm: @escaping @MainActor (FolderBusinessModel?) -> Void
    ) {
        self.pageTitle = title
        self.allFolders = folders
        self.onCreateFolder = onCreateFolder
        self.onConfirm = onConfirm
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("\(#function) has not been implemented") }

    private lazy var tableView: UITableView = {
        let tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(FolderPickerCell.self, forCellReuseIdentifier: FolderPickerCell.reuseIdentifier)
        tableView.rowHeight = 52
        return tableView
    }()

    private lazy var confirmButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = String(localized: "folder.picker.confirm", defaultValue: "Select")
        config.cornerStyle = .medium
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isEnabled = false
        return button
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = pageTitle
        setupNavigationBar()
        setupLayout()
        buildTree()
        rebuildVisibleItems()
    }

    private func setupNavigationBar() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: L10n.Action.cancel, style: .plain, target: self, action: #selector(didTapCancel)
        )
        if onCreateFolder != nil {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: String(localized: "folder.picker.new_folder", defaultValue: "New Folder"),
                style: .plain, target: self, action: #selector(didTapNewFolder)
            )
        }
    }

    private func setupLayout() {
        view.addSubview(tableView)
        view.addSubview(confirmButton)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: confirmButton.topAnchor, constant: -8),
            confirmButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            confirmButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            confirmButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            confirmButton.heightAnchor.constraint(equalToConstant: 50)
        ])
        confirmButton.addTarget(self, action: #selector(didTapConfirm), for: .touchUpInside)
    }

    @objc private func didTapCancel() { dismiss(animated: true) }

    @objc private func didTapConfirm() {
        let folder = selectedFolder
        dismiss(animated: true) { [onConfirm, folder] in onConfirm(folder) }
    }

    @objc private func didTapNewFolder() {
        let alert = UIAlertController(
            title: String(localized: "folder.picker.new_folder", defaultValue: "New Folder"),
            message: nil, preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.placeholder = String(
                localized: "folder.picker.new_folder.placeholder", defaultValue: "Folder Name"
            )
            textField.autocapitalizationType = .sentences
            textField.returnKeyType = .done
        }
        alert.addAction(UIAlertAction(title: L10n.Action.create, style: .default) { [weak self, weak alert] _ in
            guard let self, let name = alert?.textFields?.first?.text, !name.isEmpty else { return }
            self.createFolder(named: name)
        })
        alert.addAction(UIAlertAction(title: L10n.Action.cancel, style: .cancel))
        present(alert, animated: true)
    }

    private func createFolder(named name: String) {
        guard let onCreateFolder else { return }
        let parentURL = selectedFolder?.url
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let newFolder = try await onCreateFolder(name, parentURL)
                allFolders.append(newFolder)
                hasSelection = true
                selectedFolder = newFolder
                confirmButton.isEnabled = true
                buildTree()
                rebuildVisibleItems()
                tableView.reloadData()
            } catch {}
        }
    }

    private func selectFolder(_ folder: FolderBusinessModel?) {
        hasSelection = true
        selectedFolder = folder
        confirmButton.isEnabled = true
        tableView.reloadData()
    }

    // MARK: - Tree Building

    private func buildTree() {
        guard let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let sorted = allFolders.sorted { $0.url.path < $1.url.path }
        rootNodes = makeChildNodes(from: sorted, parentURL: docsURL.resolvingSymlinksInPath(), depth: 0)
    }

    private func makeChildNodes(from allFolders: [FolderBusinessModel], parentURL: URL, depth: Int) -> [FolderNode] {
        allFolders
            .filter { $0.url.resolvingSymlinksInPath().deletingLastPathComponent().path == parentURL.path }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { folder in
                let children = makeChildNodes(
                    from: allFolders, parentURL: folder.url.resolvingSymlinksInPath(), depth: depth + 1
                )
                return FolderNode(folder: folder, depth: depth, children: children)
            }
    }

    // MARK: - Visible Items

    private func rebuildVisibleItems() {
        visibleItems = []
        appendVisible(nodes: rootNodes)
    }

    private func appendVisible(nodes: [FolderNode]) {
        for node in nodes {
            visibleItems.append(node)
            if expandedFolderURLs.contains(node.folder.url.standardized) {
                appendVisible(nodes: node.children)
            }
        }
    }

    // MARK: - Toggle

    private func toggle(at row: Int) {
        let node = visibleItems[row]
        guard !node.children.isEmpty else { return }
        let url = node.folder.url.standardized
        let isExpanded = expandedFolderURLs.contains(url)
        tableView.performBatchUpdates {
            if isExpanded {
                collapseNode(node, at: row)
            } else {
                expandNode(node, at: row)
            }
        }
        tableView.reloadRows(at: [IndexPath(row: row, section: 1)], with: .none)
    }

    private func expandNode(_ node: FolderNode, at row: Int) {
        expandedFolderURLs.insert(node.folder.url.standardized)
        var insertedItems: [FolderNode] = []
        collectVisible(nodes: node.children, into: &insertedItems)
        for (offset, child) in insertedItems.enumerated() {
            visibleItems.insert(child, at: row + 1 + offset)
        }
        tableView.insertRows(at: insertedItems.indices.map { IndexPath(row: row + 1 + $0, section: 1) }, with: .fade)
    }

    private func collapseNode(_ node: FolderNode, at row: Int) {
        expandedFolderURLs.remove(node.folder.url.standardized)
        var removeCount = 0
        var idx = row + 1
        while idx < visibleItems.count && visibleItems[idx].depth > node.depth {
            expandedFolderURLs.remove(visibleItems[idx].folder.url.standardized)
            removeCount += 1
            idx += 1
        }
        guard removeCount > 0 else { return }
        visibleItems.removeSubrange((row + 1)..<(row + 1 + removeCount))
        tableView.deleteRows(at: (1...removeCount).map { IndexPath(row: row + $0, section: 1) }, with: .fade)
    }

    private func collectVisible(nodes: [FolderNode], into result: inout [FolderNode]) {
        for node in nodes {
            result.append(node)
            if expandedFolderURLs.contains(node.folder.url.standardized) {
                collectVisible(nodes: node.children, into: &result)
            }
        }
    }
}

extension FolderPickerViewController: UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : visibleItems.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: FolderPickerCell.reuseIdentifier, for: indexPath
        ) as? FolderPickerCell else { return UITableViewCell() }

        if indexPath.section == 0 {
            cell.configure(
                name: String(localized: "action.root", defaultValue: "Root"),
                icon: UIImage(systemName: "tray.fill"), depth: 0,
                expansion: .none, isChecked: hasSelection && selectedFolder == nil
            )
            cell.onToggleExpand = nil
        } else {
            let node = visibleItems[indexPath.row]
            let isExpanded = expandedFolderURLs.contains(node.folder.url.standardized)
            let expansion: CellExpansionState = node.children.isEmpty ? .none : (isExpanded ? .expanded : .collapsed)
            cell.configure(
                name: node.folder.name, icon: UIImage(systemName: "folder.fill"),
                depth: node.depth, expansion: expansion, isChecked: selectedFolder?.url == node.folder.url
            )
            cell.onToggleExpand = { [weak self, weak cell] in
                guard let self, let cell, let row = self.tableView.indexPath(for: cell) else { return }
                self.toggle(at: row.row)
            }
        }
        return cell
    }
}

extension FolderPickerViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        selectFolder(indexPath.section == 0 ? nil : visibleItems[indexPath.row].folder)
    }
}

private final class FolderPickerCell: UITableViewCell {

    static let reuseIdentifier = "FolderPickerCell"
    var onToggleExpand: (() -> Void)?

    private let chevronButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        button.setImage(UIImage(systemName: "chevron.right", withConfiguration: config), for: .normal)
        button.tintColor = .secondaryLabel
        return button
    }()

    private let iconImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = .systemBlue
        return imageView
    }()

    private let nameLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .body)
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private var containerLeadingConstraint: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        contentView.addSubview(chevronButton)
        contentView.addSubview(iconImageView)
        contentView.addSubview(nameLabel)
        containerLeadingConstraint = chevronButton.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor, constant: DesignTokens.Spacing.md
        )
        NSLayoutConstraint.activate([
            containerLeadingConstraint,
            chevronButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            chevronButton.widthAnchor.constraint(equalToConstant: 24),
            chevronButton.heightAnchor.constraint(equalToConstant: 44),
            iconImageView.leadingAnchor.constraint(equalTo: chevronButton.trailingAnchor, constant: 4),
            iconImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 28),
            iconImageView.heightAnchor.constraint(equalToConstant: 28),
            nameLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            nameLabel.leadingAnchor.constraint(
                equalTo: iconImageView.trailingAnchor, constant: DesignTokens.Spacing.sm
            ),
            nameLabel.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -DesignTokens.Spacing.md
            )
        ])
        chevronButton.addTarget(self, action: #selector(chevronTapped), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("\(#function) has not been implemented") }

    @objc private func chevronTapped() { onToggleExpand?() }

    func configure(name: String, icon: UIImage?, depth: Int, expansion: CellExpansionState, isChecked: Bool) {
        nameLabel.text = name
        iconImageView.image = icon?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 26, weight: .regular))
        let indent = DesignTokens.Spacing.md + CGFloat(depth) * 20
        containerLeadingConstraint.constant = indent
        chevronButton.isHidden = expansion == .none
        chevronButton.transform = CGAffineTransform(rotationAngle: expansion == .expanded ? CGFloat.pi / 2 : 0)
        separatorInset = UIEdgeInsets(top: 0, left: indent + 24 + 4 + 28 + DesignTokens.Spacing.sm, bottom: 0, right: 0)
        accessoryType = isChecked ? .checkmark : .none
    }
}
