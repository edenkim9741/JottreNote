/*
 Jottre: Minimalistic jotting for iPhone, iPad and Mac.
 Copyright (C) 2021-2026 Anton Lorani

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

import UIKit

final class PageViewController: UIViewController {

    private lazy var collectionViewLayout: UICollectionViewCompositionalLayout = {
        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        return UICollectionViewCompositionalLayout(
            sectionProvider: { [weak self] _, environment in
                guard let self else { return self?.makeDefaultLayoutSection() }
                return makeLayoutSection(
                    items: self.dataSource.snapshot().itemIdentifiers,
                    contentWidth: environment.container.effectiveContentSize.width
                )
            },
            configuration: configuration
        )
    }()

    private lazy var dataSource: UICollectionViewDiffableDataSource<Int, PageCellItem> = {
        UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
            self?.registerIfNeeded(item.cellType)
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: item.cellType.reuseIdentifier,
                for: indexPath
            )
            item.configure(cell)
            return cell
        }
    }()

    private lazy var collectionView: UICollectionView = {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: collectionViewLayout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .systemGroupedBackground
        collectionView.preservesSuperviewLayoutMargins = true
        collectionView.contentInset.bottom = DesignTokens.Spacing.md
        collectionView.delegate = self
        return collectionView
    }()

    private lazy var callToActionView: PageCallToActionView = {
        let view = PageCallToActionView(actions: viewModel.actions)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var withCallToActionViewConstraints = [
        collectionView.bottomAnchor.constraint(equalTo: callToActionView.topAnchor),
        callToActionView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
        callToActionView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        callToActionView.bottomAnchor.constraint(equalTo: view.layoutMarginsGuide.bottomAnchor),
    ]

    private lazy var withoutCallToActionViewConstraints = [
        collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    ]

    private var registeredReuseIdentifiers = Set<String>()
    private var hasAppliedInitialLeftItems = false
    private var titleTask: Task<Void, Never>?
    private var leftNavigationItemsTask: Task<Void, Never>?
    private var rightNavigationItemsTask: Task<Void, Never>?
    private var itemsTask: Task<Void, Never>?
    private var selectionStateTask: Task<Void, Never>?
    private var springLoadTimer: Timer?
    private var springLoadTargetHash: Int?

    private var currentSelectionState = PageSelectionState(isSelecting: false, selectedItemIDs: [])

    private let viewModel: PageViewModel
    private let selectableViewModel: PageSelectableViewModel?
    private weak var dragDropViewModel: (any PageDragDropViewModel)?
    private let textBarButtonItemFactory: TextBarButtonItemFactory
    private let symbolBarButtonItemFactory: SymbolBarButtonItemFactory

    init(
        viewModel: PageViewModel,
        textBarButtonItemFactory: TextBarButtonItemFactory,
        symbolBarButtonItemFactory: SymbolBarButtonItemFactory
    ) {
        self.viewModel = viewModel
        self.selectableViewModel = viewModel as? PageSelectableViewModel
        self.dragDropViewModel = viewModel as? (any PageDragDropViewModel)
        self.textBarButtonItemFactory = textBarButtonItemFactory
        self.symbolBarButtonItemFactory = symbolBarButtonItemFactory
        super.init(nibName: nil, bundle: nil)

        titleTask = Task { [weak self] in
            for await newTitle in viewModel.titleUpdates {
                self?.navigationItem.title = newTitle
            }
        }

        itemsTask = Task { [weak self] in
            for await items in viewModel.items {
                self?.handleItems(items)
            }
        }

        leftNavigationItemsTask = Task { [weak self] in
            for await navigationItems in viewModel.leftNavigationItems {
                self?.handleLeftNavigationItems(navigationItems: navigationItems)
            }
        }

        rightNavigationItemsTask = Task { [weak self] in
            for await navigationItems in viewModel.rightNavigationItems {
                self?.handleRightNavigationItems(navigationItems: navigationItems)
            }
        }

        if let selectableViewModel {
            selectionStateTask = Task { [weak self] in
                for await selectionState in selectableViewModel.selectionState {
                    self?.handleSelectionState(selectionState)
                }
            }
        }

        setUpViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("\(#function) has not been implemented")
    }

    deinit {
        titleTask?.cancel()
        itemsTask?.cancel()
        leftNavigationItemsTask?.cancel()
        rightNavigationItemsTask?.cancel()
        selectionStateTask?.cancel()
    }

    private func setUpViews() {
        if dragDropViewModel != nil {
            collectionView.dragDelegate = self
            collectionView.dropDelegate = self
            collectionView.dragInteractionEnabled = true
        }
        navigationItem.title = viewModel.title
        view.backgroundColor = .systemGroupedBackground
        view.directionalLayoutMargins.bottom = DesignTokens.Spacing.md
        navigationItem.largeTitleDisplayMode = .never

        view.addSubview(collectionView)

        var constraints = [
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ]

        if viewModel.actions.isEmpty {
            constraints.append(contentsOf: withoutCallToActionViewConstraints)
        } else {
            view.addSubview(callToActionView)
            constraints.append(contentsOf: withCallToActionViewConstraints)
        }

        NSLayoutConstraint.activate(constraints)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        viewModel.didLoad()
    }

    private func registerIfNeeded(_ cellType: any PageCell.Type) {
        let identifier = cellType.reuseIdentifier
        guard !registeredReuseIdentifiers.contains(identifier) else { return }
        collectionView.register(cellType, forCellWithReuseIdentifier: identifier)
        registeredReuseIdentifiers.insert(identifier)
    }

    private func handleItems(_ items: [PageCellItem]) {
        let hasExistingItems = !dataSource.snapshot().itemIdentifiers.isEmpty
        var snapshot = NSDiffableDataSourceSnapshot<Int, PageCellItem>()
        snapshot.appendSections([0])
        snapshot.appendItems(items)
        dataSource.apply(snapshot, animatingDifferences: hasExistingItems)
        collectionViewLayout.invalidateLayout()
        syncSelectionToVisibleItems()
    }

    private func handleRightNavigationItems(navigationItems: [PageNavigationItem]) {
        if let firstNavigationItem = navigationItems.first, navigationItems.count == 1 {
            navigationItem.setRightBarButton(makeNavigationItem(navigationItem: firstNavigationItem), animated: true)
        } else {
            navigationItem.setRightBarButtonItems(navigationItems.map(makeNavigationItem), animated: true)
        }
    }

    private func handleLeftNavigationItems(navigationItems: [PageNavigationItem]) {
        let animated = hasAppliedInitialLeftItems
        hasAppliedInitialLeftItems = true
        if navigationItems.isEmpty {
            navigationItem.leftItemsSupplementBackButton = false
            navigationItem.setLeftBarButtonItems(nil, animated: animated)
            return
        }
        navigationItem.leftItemsSupplementBackButton = true
        if let firstNavigationItem = navigationItems.first, navigationItems.count == 1 {
            navigationItem.setLeftBarButton(makeNavigationItem(navigationItem: firstNavigationItem), animated: animated)
        } else {
            navigationItem.setLeftBarButtonItems(navigationItems.map(makeNavigationItem), animated: animated)
        }
    }

    private func makeNavigationItem(navigationItem: PageNavigationItem) -> UIBarButtonItem {
        switch navigationItem {
        case let .text(title, onAction):
            return textBarButtonItemFactory.make(
                title: title,
                primaryAction: UIAction { _ in onAction() }
            )
        case let .symbol(symbolName, onAction):
            return symbolBarButtonItemFactory.make(
                symbolName: symbolName,
                primaryAction: .action(UIAction { _ in onAction() })
            )
        }
    }

    private func handleSelectionState(_ selectionState: PageSelectionState) {
        currentSelectionState = selectionState
        collectionView.allowsMultipleSelection = selectionState.isSelecting
        syncSelectionToVisibleItems()
    }

    private func syncSelectionToVisibleItems() {
        guard currentSelectionState.isSelecting else {
            for indexPath in collectionView.indexPathsForSelectedItems ?? [] {
                collectionView.deselectItem(at: indexPath, animated: false)
            }
            return
        }

        let items = dataSource.snapshot().itemIdentifiers
        for (index, item) in items.enumerated() {
            let indexPath = IndexPath(item: index, section: 0)
            if currentSelectionState.selectedItemIDs.contains(AnyHashable(item.id)) {
                collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
            } else {
                collectionView.deselectItem(at: indexPath, animated: false)
            }
        }
    }

    private func makeDefaultLayoutSection() -> NSCollectionLayoutSection {
        let (group, _) = makeFullWidthRowLayoutGroup(estimatedHeight: 120)
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsetsReference = .layoutMargins
        return section
    }

    private func makeLayoutSection(items: [PageCellItem], contentWidth: CGFloat) -> NSCollectionLayoutSection {
        let rowGroups = makeRowLayoutGroups(items: items, contentWidth: contentWidth)
        guard !rowGroups.isEmpty else { return makeDefaultLayoutSection() }

        let group = NSCollectionLayoutGroup.vertical(
            layoutSize: .init(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(1000)),
            subitems: rowGroups
        )
        group.interItemSpacing = .fixed(items.first?.sizing.rowSpacing ?? DesignTokens.Spacing.md)

        let section = NSCollectionLayoutSection(group: group)
        section.contentInsetsReference = .layoutMargins
        return section
    }

    private func makeRowLayoutGroups(items: [PageCellItem], contentWidth: CGFloat) -> [NSCollectionLayoutGroup] {
        var groups: [NSCollectionLayoutGroup] = []
        var index = 0
        while index < items.count {
            let (group, consumed) = makeRowLayoutGroup(sizing: items[index].sizing, contentWidth: contentWidth)
            groups.append(group)
            index += min(consumed, items.count - index)
        }
        return groups
    }

    private func makeRowLayoutGroup(
        sizing: PageCellSizingStrategy,
        contentWidth: CGFloat
    ) -> (NSCollectionLayoutGroup, Int) {
        switch sizing {
        case let .fullWidth(estimatedHeight, _):
            makeFullWidthRowLayoutGroup(estimatedHeight: estimatedHeight)
        case let .equalSplit(perRow, height, columnSpacing, _):
            makeEqualSplitRowLayoutGroup(perRow: perRow, height: height, columnSpacing: columnSpacing)
        case let .adaptiveGrid(minColumns, maxColumns, minItemWidth, maxItemWidth, columnSpacing, _, aspectRatio):
            makeAdaptiveGridRowLayoutGroup(
                minColumns: minColumns,
                maxColumns: maxColumns,
                minItemWidth: minItemWidth,
                maxItemWidth: maxItemWidth,
                columnSpacing: columnSpacing,
                aspectRatio: aspectRatio,
                contentWidth: contentWidth
            )
        }
    }

    private func makeFullWidthRowLayoutGroup(estimatedHeight: CGFloat) -> (NSCollectionLayoutGroup, Int) {
        let item = NSCollectionLayoutItem(
            layoutSize: .init(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(estimatedHeight))
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(estimatedHeight)),
            subitems: [item]
        )
        return (group, 1)
    }

    private func makeEqualSplitRowLayoutGroup(
        perRow: Int,
        height: CGFloat,
        columnSpacing: CGFloat
    ) -> (NSCollectionLayoutGroup, Int) {
        let item = NSCollectionLayoutItem(
            layoutSize: .init(widthDimension: .fractionalWidth(1.0 / CGFloat(perRow)), heightDimension: .absolute(height))
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(height)),
            repeatingSubitem: item,
            count: perRow
        )
        group.interItemSpacing = .fixed(columnSpacing)
        return (group, perRow)
    }

    private func makeAdaptiveGridRowLayoutGroup(
        minColumns: Int,
        maxColumns: Int,
        minItemWidth: CGFloat,
        maxItemWidth: CGFloat,
        columnSpacing: CGFloat,
        aspectRatio: CGSize,
        contentWidth: CGFloat
    ) -> (NSCollectionLayoutGroup, Int) {
        let columnsNeeded = Int(ceil((contentWidth + columnSpacing) / (maxItemWidth + columnSpacing)))
        let columnsAllowed = Int((contentWidth + columnSpacing) / (minItemWidth + columnSpacing))
        let columns = max(minColumns, min(maxColumns, min(columnsAllowed, max(columnsNeeded, minColumns))))
        let itemWidth = (contentWidth - columnSpacing * CGFloat(columns - 1)) / CGFloat(columns)
        let itemHeight = itemWidth * aspectRatio.height / aspectRatio.width

        let item = NSCollectionLayoutItem(
            layoutSize: .init(widthDimension: .fractionalWidth(1.0 / CGFloat(columns)), heightDimension: .absolute(itemHeight))
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(itemHeight)),
            repeatingSubitem: item,
            count: columns
        )
        group.interItemSpacing = .fixed(columnSpacing)
        return (group, columns)
    }
}
extension PageViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        // 단순화: 선택 모드일 때 뷰모델이 이 아이템을 선택할 수 있다고 허용하는지만 검사합니다.
        guard
            currentSelectionState.isSelecting,
            let selectableViewModel,
            let item = dataSource.itemIdentifier(for: indexPath)
        else {
            return true
        }

        return selectableViewModel.canSelectItem(item)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        // 선택 모드일 때 아이템을 선택하면 뷰모델에 토글 알림
        if currentSelectionState.isSelecting, let selectableViewModel, selectableViewModel.canSelectItem(item) {
            guard let jotFileInfo = item.id as? JotFile.Info else { return }
            selectableViewModel.didToggleSelection(for: jotFileInfo)
            return
        }

        if currentSelectionState.isSelecting {
            return
        }

        // 일반 모드일 때는 노트 열기 액션 실행
        item.handleAction(.tap)
    }

    // 🔥 [버그 수정]: 선택된 셀을 다시 눌러 유저가 '선택 취소'를 했을 때 호출되는 공식 메서드 추가
    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        guard 
            currentSelectionState.isSelecting, 
            let selectableViewModel,
            let item = dataSource.itemIdentifier(for: indexPath) 
        else { 
            return 
        }

        // 데이터 동기화를 위해 뷰모델에 해제된 파일 정보를 넘겨 토글(제거)시킵니다.
        if let jotFileInfo = item.id as? JotFile.Info {
            selectableViewModel.didToggleSelection(for: jotFileInfo)
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let cell = collectionView.cellForItem(at: indexPath) else { return nil }
        let cellPoint = collectionView.convert(point, to: cell)
        return dataSource.itemIdentifier(for: indexPath)?.contextMenuConfiguration(cellPoint, cell)
    }
}

// MARK: - Drag & Drop

private final class CellItemBox: NSObject {
    let item: PageCellItem
    init(_ item: PageCellItem) { self.item = item }
}

extension PageViewController: UICollectionViewDragDelegate {

    func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: any UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard
            !currentSelectionState.isSelecting,
            let dragDropVM = dragDropViewModel,
            let cellItem = dataSource.itemIdentifier(for: indexPath),
            dragDropVM.canDrag(cellItem: cellItem)
        else { return [] }
        return [makeDragItem(for: cellItem)]
    }

    func collectionView(
        _ collectionView: UICollectionView,
        itemsForAddingTo session: any UIDragSession,
        at indexPath: IndexPath,
        point: CGPoint
    ) -> [UIDragItem] {
        guard
            !currentSelectionState.isSelecting,
            let dragDropVM = dragDropViewModel,
            let cellItem = dataSource.itemIdentifier(for: indexPath),
            dragDropVM.canDrag(cellItem: cellItem)
        else { return [] }
        let alreadyInSession = session.items.compactMap { $0.localObject as? CellItemBox }.map(\.item)
        guard !alreadyInSession.contains(where: { $0.hashValue == cellItem.hashValue }) else { return [] }
        guard dragDropVM.canAddToDragSession(cellItem: cellItem, existingItems: alreadyInSession) else { return [] }
        return [makeDragItem(for: cellItem)]
    }

    private func makeDragItem(for cellItem: PageCellItem) -> UIDragItem {
        let provider = NSItemProvider(object: NSString(string: "\(cellItem.id.hashValue)"))
        let dragItem = UIDragItem(itemProvider: provider)
        dragItem.localObject = CellItemBox(cellItem)
        return dragItem
    }
}

extension PageViewController: UICollectionViewDropDelegate {

    func collectionView(_ collectionView: UICollectionView, canHandle session: any UIDropSession) -> Bool {
        session.localDragSession != nil
    }

    func collectionView(
        _ collectionView: UICollectionView,
        dropSessionDidUpdate session: any UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        guard session.localDragSession != nil, let dragDropVM = dragDropViewModel else {
            cancelSpringLoad()
            return UICollectionViewDropProposal(operation: .forbidden)
        }

        let draggedItems = session.items.compactMap { $0.localObject as? CellItemBox }.map(\.item)

        if let destIndexPath = destinationIndexPath,
           let targetItem = dataSource.itemIdentifier(for: destIndexPath),
           dragDropVM.canDrop(draggedCellItems: draggedItems, onto: targetItem) {
            if dragDropVM.shouldSpringLoad(draggedCellItems: draggedItems, onto: targetItem) {
                startSpringLoad(for: targetItem, using: dragDropVM)
            } else {
                cancelSpringLoad()
            }
            return UICollectionViewDropProposal(operation: .move, intent: .insertIntoDestinationIndexPath)
        }

        cancelSpringLoad()

        if dragDropVM.canDropIntoCurrentDirectory(draggedCellItems: draggedItems) {
            return UICollectionViewDropProposal(operation: .move, intent: .unspecified)
        }

        return UICollectionViewDropProposal(operation: .forbidden)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        performDropWith coordinator: any UICollectionViewDropCoordinator
    ) {
        guard let dragDropVM = dragDropViewModel else { return }
        let draggedItems = coordinator.items.compactMap { $0.dragItem.localObject as? CellItemBox }.map(\.item)
        guard !draggedItems.isEmpty else { return }

        if let destIndexPath = coordinator.destinationIndexPath,
           let targetItem = dataSource.itemIdentifier(for: destIndexPath) {
            dragDropVM.performDrop(draggedCellItems: draggedItems, onto: targetItem)
        } else {
            dragDropVM.performDropIntoCurrentDirectory(draggedCellItems: draggedItems)
        }
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidExit session: any UIDropSession) {
        cancelSpringLoad()
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidEnd session: any UIDropSession) {
        cancelSpringLoad()
    }

    private func startSpringLoad(for targetItem: PageCellItem, using dragDropVM: any PageDragDropViewModel) {
        let targetHash = targetItem.hashValue
        guard springLoadTargetHash != targetHash else { return }
        cancelSpringLoad()
        springLoadTargetHash = targetHash
        springLoadTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dragDropViewModel?.springLoad(onto: targetItem)
                self?.cancelSpringLoad()
            }
        }
    }

    private func cancelSpringLoad() {
        springLoadTimer?.invalidate()
        springLoadTimer = nil
        springLoadTargetHash = nil
    }
}
