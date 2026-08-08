import UIKit

final class FolderCell: UICollectionViewCell, PageCell {

    static let reuseIdentifier = "FolderCell"

    private let iconImageView: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "folder.fill"))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.tintColor = .secondaryLabel
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    private let separatorLine: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor.separator
        return view
    }()

    private let nameLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        #if targetEnvironment(macCatalyst)
        label.font = .preferredFont(forTextStyle: .body, weight: .semibold)
        #else
        label.font = .preferredFont(forTextStyle: .caption1, weight: .semibold)
        #endif
        label.numberOfLines = 2
        return label
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
        contentView.clipsToBounds = true
        contentView.layoutMargins = UIEdgeInsets(
            top: DesignTokens.Spacing.md,
            left: DesignTokens.Spacing.sm,
            bottom: DesignTokens.Spacing.sm,
            right: DesignTokens.Spacing.sm
        )

        contentView.addSubview(iconImageView)
        contentView.addSubview(separatorLine)
        contentView.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            iconImageView.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            iconImageView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconImageView.heightAnchor.constraint(equalToConstant: 44),
            iconImageView.widthAnchor.constraint(equalToConstant: 44),

            separatorLine.topAnchor.constraint(equalTo: iconImageView.bottomAnchor, constant: DesignTokens.Spacing.md),
            separatorLine.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separatorLine.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separatorLine.heightAnchor.constraint(equalToConstant: DesignTokens.Length.separator),

            nameLabel.topAnchor.constraint(equalTo: separatorLine.bottomAnchor, constant: DesignTokens.Spacing.sm),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            nameLabel.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }
}
