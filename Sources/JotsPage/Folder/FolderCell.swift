import UIKit

final class FolderCell: UICollectionViewCell, PageCell {

    static let reuseIdentifier = "FolderCell"

    private let iconImageView: UIImageView = {
        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        let imageView = UIImageView(image: UIImage(systemName: "folder.fill", withConfiguration: config))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.tintColor = .systemBlue
        imageView.contentMode = .scaleAspectFit
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

    private let chevronImageView: UIImageView = {
        let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let imageView = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: config))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.tintColor = .tertiaryLabel
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    private let separatorLine: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .separator
        return view
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUpViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        assertionFailure("\(#function) has not been implemented")
        return nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        viewModel = nil
        nameLabel.text = nil
    }

    private var viewModel: FolderCellViewModel?

    func configure(viewModel: FolderCellViewModel) {
        self.viewModel = viewModel
        nameLabel.text = viewModel.name
    }

    private func setUpViews() {
        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.layer.cornerRadius = DesignTokens.CornerRadius.cell
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true

        contentView.addSubview(iconImageView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(chevronImageView)
        contentView.addSubview(separatorLine)

        NSLayoutConstraint.activate([
            iconImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconImageView.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: DesignTokens.Spacing.md
            ),
            iconImageView.widthAnchor.constraint(equalToConstant: 32),
            iconImageView.heightAnchor.constraint(equalToConstant: 32),

            chevronImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            chevronImageView.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -DesignTokens.Spacing.md
            ),
            chevronImageView.widthAnchor.constraint(equalToConstant: 12),

            nameLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            nameLabel.leadingAnchor.constraint(
                equalTo: iconImageView.trailingAnchor,
                constant: DesignTokens.Spacing.sm
            ),
            nameLabel.trailingAnchor.constraint(
                equalTo: chevronImageView.leadingAnchor,
                constant: -DesignTokens.Spacing.sm
            ),

            separatorLine.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            separatorLine.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separatorLine.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorLine.heightAnchor.constraint(equalToConstant: DesignTokens.Length.separator)
        ])
    }
}
