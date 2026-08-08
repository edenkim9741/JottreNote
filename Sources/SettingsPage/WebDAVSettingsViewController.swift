import UIKit

@MainActor
final class WebDAVSettingsViewController: UIViewController {

    struct Configuration {
        var url: String
        var username: String
        var password: String
    }

    var onSave: (Configuration) -> Void = { _ in }
    var onTest: (Configuration) async -> Bool = { _ in false }
    var onBackupAll: () -> AsyncStream<Double> = { AsyncStream { $0.finish() } }

    private let urlField: UITextField = {
        let field = UITextField()
        field.placeholder = "https://example.com/dav/"
        field.keyboardType = .URL
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.clearButtonMode = .whileEditing
        return field
    }()

    private let usernameField: UITextField = {
        let field = UITextField()
        field.placeholder = "username"
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.clearButtonMode = .whileEditing
        return field
    }()

    private let passwordField: UITextField = {
        let field = UITextField()
        field.placeholder = "password"
        field.isSecureTextEntry = true
        field.clearButtonMode = .whileEditing
        return field
    }()

    private let testButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Test Connection"
        config.cornerStyle = .medium
        return UIButton(configuration: config)
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 14)
        label.numberOfLines = 0
        label.isHidden = true
        return label
    }()

    private let backupAllButton: UIButton = {
        var config = UIButton.Configuration.tinted()
        config.title = "Backup All Notes"
        config.image = UIImage(systemName: "arrow.up.to.line")
        config.imagePadding = 8
        config.cornerStyle = .medium
        return UIButton(configuration: config)
    }()

    private let backupProgressView: UIProgressView = {
        let view = UIProgressView(progressViewStyle: .default)
        view.isHidden = true
        view.progress = 0
        return view
    }()

    private let backupStatusLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 14)
        label.numberOfLines = 0
        label.isHidden = true
        return label
    }()

    private var backupTask: Task<Void, Never>?

    init(initial: Configuration) {
        super.init(nibName: nil, bundle: nil)
        urlField.text = initial.url
        usernameField.text = initial.username
        passwordField.text = initial.password
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "WebDAV Backup"
        view.backgroundColor = .systemGroupedBackground
        setupNavigationBar()
        setupLayout()
    }

    deinit {
        backupTask?.cancel()
    }

    private func setupNavigationBar() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.Action.done, style: .done, target: self, action: #selector(didTapSave)
        )
    }

    private func setupLayout() {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let sections = UIStackView(arrangedSubviews: [
            makeFieldCard(label: "Server URL", field: urlField),
            makeCredentialsCard(),
            testButton,
            statusLabel,
            makeSectionSeparator(),
            backupAllButton,
            backupProgressView,
            backupStatusLabel
        ])
        sections.axis = .vertical
        sections.spacing = 16
        sections.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(sections)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sections.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 20),
            sections.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            sections.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            sections.bottomAnchor.constraint(lessThanOrEqualTo: scrollView.bottomAnchor, constant: -20)
        ])

        testButton.addTarget(self, action: #selector(didTapTest), for: .touchUpInside)
        backupAllButton.addTarget(self, action: #selector(didTapBackupAll), for: .touchUpInside)
    }

    private func makeSectionSeparator() -> UIView {
        let container = UIView()
        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = .separator
        container.addSubview(separator)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            separator.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5)
        ])
        return container
    }

    private func makeFieldCard(label: String, field: UITextField) -> UIView {
        let title = makeLabel(text: label)
        let stack = UIStackView(arrangedSubviews: [title, field])
        stack.axis = .vertical
        stack.spacing = 6
        return wrapInCard(stack)
    }

    private func makeCredentialsCard() -> UIView {
        let usernameTitle = makeLabel(text: "Username")
        let passwordTitle = makeLabel(text: "Password")
        let separator = makeSeparator()
        let stack = UIStackView(arrangedSubviews: [
            usernameTitle, usernameField, separator, passwordTitle, passwordField
        ])
        stack.axis = .vertical
        stack.spacing = 6
        stack.setCustomSpacing(12, after: usernameField)
        stack.setCustomSpacing(12, after: separator)
        return wrapInCard(stack)
    }

    private func makeLabel(text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabel
        return label
    }

    private func makeSeparator() -> UIView {
        let view = UIView()
        view.backgroundColor = .separator
        view.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return view
    }

    private func wrapInCard(_ content: UIStackView) -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 10
        card.clipsToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12)
        ])
        return card
    }

    @objc private func didTapSave() {
        onSave(currentConfiguration())
        navigationController?.popViewController(animated: true)
    }

    @objc private func didTapTest() {
        let configuration = currentConfiguration()
        statusLabel.isHidden = false
        statusLabel.text = "Testing..."
        statusLabel.textColor = .secondaryLabel
        testButton.isEnabled = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            let success = await onTest(configuration)
            statusLabel.text = success ? "✓ Connected successfully" : "✗ Connection failed"
            statusLabel.textColor = success ? .systemGreen : .systemRed
            testButton.isEnabled = true
        }
    }

    @objc private func didTapBackupAll() {
        backupTask?.cancel()
        backupAllButton.isEnabled = false
        backupProgressView.isHidden = true
        backupProgressView.progress = 0
        backupStatusLabel.isHidden = false
        backupStatusLabel.text = String(localized: "webdav.backup.testing", defaultValue: "Testing connection...")
        backupStatusLabel.textColor = .secondaryLabel

        backupTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let connected = await onTest(currentConfiguration())
            guard !Task.isCancelled else { return }

            guard connected else {
                backupAllButton.isEnabled = true
                backupStatusLabel.text = String(
                    localized: "webdav.backup.connectionFailed",
                    defaultValue: "✗ Connection failed — check your settings"
                )
                backupStatusLabel.textColor = .systemRed
                return
            }

            backupProgressView.isHidden = false
            backupStatusLabel.text = String(localized: "webdav.backup.inProgress", defaultValue: "Backing up...")
            backupStatusLabel.textColor = .secondaryLabel

            let stream = onBackupAll()
            for await progress in stream {
                guard !Task.isCancelled else { break }
                backupProgressView.progress = Float(progress)
            }
            guard !Task.isCancelled else { return }
            backupAllButton.isEnabled = true
            backupProgressView.isHidden = true
            backupStatusLabel.text = String(localized: "webdav.backup.complete", defaultValue: "✓ Backup complete")
            backupStatusLabel.textColor = .systemGreen
        }
    }

    private func currentConfiguration() -> Configuration {
        Configuration(
            url: urlField.text ?? "",
            username: usernameField.text ?? "",
            password: passwordField.text ?? ""
        )
    }
}
