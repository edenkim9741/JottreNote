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

import PDFKit
@preconcurrency import PencilKit
import UIKit

extension DefaultsKey where T == Bool {
    fileprivate static let drawAndHoldShapeConversionEnabled: DefaultsKey =
        "editor.drawAndHoldShapeConversionEnabled"
}

final class EditJotViewController: UIViewController {

    private enum Constants {

        enum CanvasView {
            static let maximumZoomScale = CGFloat(8)
            static let bottomFreespace = CGFloat(500)
            /// Viewport-only breathing room above the first page. This is a
            /// scroll inset, so it never changes document or export coordinates.
            static let topWritingFreespace = CGFloat(64)
            static let shapeHoldDuration = TimeInterval(0.42)
            static let shapeHoldMovementTolerance = CGFloat(5)
        }

        enum Page {
            static let width = CGFloat(1200)
            static let height = CGFloat(1600)
        }
    }

    private struct ShapeHoldState {
        let initialStrokeCount: Int
        let beforeDrawing: EditJotViewModel.Drawing
        var detector: EndpointHoldDetector
        var didProvideHoldFeedback = false
    }

    #if !targetEnvironment(macCatalyst)
    private lazy var toolPicker = PKToolPicker()
    #endif

    private lazy var canvasView: JotCanvasView = {
        let canvasView = JotCanvasView()
        canvasView.delegate = self
        canvasView.isScrollEnabled = false
        canvasView.drawingPolicy = .default
        canvasView.minimumZoomScale = 1
        canvasView.maximumZoomScale = 1
        canvasView.bounces = false
        canvasView.contentInsetAdjustmentBehavior = .never
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.layer.shouldRasterize = false
        canvasView.layer.anchorPoint = .zero
        canvasView.layer.position = .zero
        return canvasView
    }()

    private lazy var highlighterCanvasView: JotCanvasView = {
        let canvasView = JotCanvasView()
        canvasView.delegate = self
        canvasView.isUserInteractionEnabled = false
        canvasView.isScrollEnabled = false
        canvasView.drawingPolicy = .default
        canvasView.minimumZoomScale = 1
        canvasView.maximumZoomScale = 1
        canvasView.bounces = false
        canvasView.contentInsetAdjustmentBehavior = .never
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.layer.shouldRasterize = false
        canvasView.layer.anchorPoint = .zero
        canvasView.layer.position = .zero
        return canvasView
    }()

    private lazy var inkCanvasCoordinator = JotInkCanvasCoordinator(
        highlighterCanvas: highlighterCanvasView,
        foregroundCanvas: canvasView
    )

    private lazy var documentScrollView: JotDocumentScrollView = {
        let scrollView = JotDocumentScrollView()
        scrollView.delegate = documentScrollDelegate
        scrollView.shouldRouteDirectTouch = { [weak self] in
            self?.updateCanvasTouchRouting() ?? false
        }
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = Constants.CanvasView.maximumZoomScale
        scrollView.bounces = false
        scrollView.bouncesZoom = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        scrollView.backgroundColor = .clear
        #if !targetEnvironment(macCatalyst)
        let fingerTouch = NSNumber(value: UITouch.TouchType.direct.rawValue)
        scrollView.panGestureRecognizer.allowedTouchTypes = [fingerTouch]
        scrollView.pinchGestureRecognizer?.allowedTouchTypes = [fingerTouch]
        #endif
        return scrollView
    }()

    private lazy var documentScrollDelegate = DocumentScrollViewDelegate(viewController: self)

    private let documentContainerView: UIView = {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.layer.anchorPoint = .zero
        view.layer.position = .zero
        return view
    }()

    private let backgroundView: JotBackgroundView = {
        let view = JotBackgroundView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }()

    /// Crops the foreground canvas to a buffered document-space viewport.
    /// Neither this container nor the canvas applies an independent zoom.
    private let inkContainerView: UIView = {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.layer.anchorPoint = .zero
        view.layer.position = .zero
        return view
    }()

    private let highlighterInkContainerView: UIView = {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.layer.anchorPoint = .zero
        view.layer.position = .zero
        return view
    }()

    private var drawingWidth = CGFloat.zero
    private var backgroundContentHeight = CGFloat.zero
    private var currentPageSize = CGSize(width: Constants.Page.width, height: Constants.Page.height)
    private var previousCanvasBoundsSize = CGSize.zero
    private var fittedPageSize = CGSize.zero
    private var hasInitializedZoomScale = false
    private var isUpdatingCanvasGeometry = false
    private var isUsingDrawingTool = false
    private var hasPendingDrawingChange = false
    private var documentContentSize = CGSize.zero
    private var allocatedInkDocumentRect = CGRect.null
    private var isZoomInteractionActive = false
    /// Backing-store density currently applied to both ink canvases. Raising it
    /// forces PencilKit to re-tessellate its vector strokes, which is too costly
    /// to do on every frame of a pinch, so it only follows a settled zoom.
    private var appliedInkContentScale = CGFloat.zero
    private var zoomSettleTask: Task<Void, Never>?
    private var blankEditMenuDismissTask: Task<Void, Never>?
    private var applicationBackgroundFlushTask: Task<Void, Never>?
    private var applicationBackgroundTaskIdentifier = UIBackgroundTaskIdentifier.invalid
    private var applicationBackgroundTaskGeneration: UUID?
    private var isEditingEnabled = false
    private var drawingBeforeToolUse: EditJotViewModel.Drawing?
    private var ownsToolUndoGrouping = false
    private var toolUndoManager: UndoManager?
    private var shapeHoldState: ShapeHoldState?
    private var shapeHoldTask: Task<Void, Never>?
    private var shapeCommitWatchdogTask: Task<Void, Never>?
    private var toolUndoCleanupTask: Task<Void, Never>?

    private let pdfLoadService = PDFLoadService()
    private var cachedPDFData: Data?
    private var cachedPDFLoadResult: PDFLoadService.Result?

    #if !targetEnvironment(macCatalyst)
    private var didSelectInitialPenTool = false
    private var selectedToolUpdateTask: Task<Void, Never>?
    #endif

    private lazy var swipeBackGesture: UIScreenEdgePanGestureRecognizer = {
        let gesture = UIScreenEdgePanGestureRecognizer(
            target: self,
            action: #selector(handleSwipeBack)
        )
        gesture.edges = .left
        gesture.isEnabled = false
        return gesture
    }()

    /// Prevents PencilKit's internal blank-canvas tap recognizer from creating
    /// Select All / Insert Space outside lasso mode. Continuous drawing and
    /// document-navigation gestures always retain priority.
    private lazy var blankCanvasEditMenuTapGesture: CanvasEditMenuBlockingTapGestureRecognizer = {
        let gesture = CanvasEditMenuBlockingTapGestureRecognizer(
            target: self,
            action: #selector(handleBlankCanvasEditMenuTap(_:))
        )
        gesture.name = "Jottre.BlankCanvasEditMenuTapBlocker"
        gesture.numberOfTapsRequired = 1
        gesture.numberOfTouchesRequired = 1
        gesture.cancelsTouchesInView = true
        gesture.delaysTouchesBegan = false
        gesture.delaysTouchesEnded = false
        gesture.requiresExclusiveTouchType = true
        gesture.delegate = self
        gesture.canvasRootViews = [canvasView]
        gesture.pencilKitDrawingGestureRecognizers = [
            canvasView.drawingGestureRecognizer,
            highlighterCanvasView.drawingGestureRecognizer,
        ]
        #if !targetEnvironment(macCatalyst)
        gesture.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        #endif
        return gesture
    }()

    private lazy var loadingProgressView: UIProgressView = {
        let bar = UIProgressView(progressViewStyle: .bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.progress = 0
        return bar
    }()

    private var pendingScrollPage: Int?
    private var isEditingTask: Task<Void, Never>?
    private var drawingTask: Task<Void, Never>?
    private var scribbleEraseTask: Task<Void, Never>?
    private var backButtonTask: Task<Void, Never>?
    private var backgroundTask: Task<Void, Never>?
    private var loadingProgressTask: Task<Void, Never>?

    private let viewModel: EditJotViewModel
    private let symbolBarButtonItemFactory: SymbolBarButtonItemFactory
    private let defaultsService: DefaultsServiceProtocol

    init(
        viewModel: EditJotViewModel,
        symbolBarButtonItemFactory: SymbolBarButtonItemFactory,
        defaultsService: DefaultsServiceProtocol
    ) {
        self.viewModel = viewModel
        self.symbolBarButtonItemFactory = symbolBarButtonItemFactory
        self.defaultsService = defaultsService
        super.init(nibName: nil, bundle: nil)

        isEditingTask = Task { @MainActor [weak self] in
            for await isEditing in viewModel.isEditing {
                self?.handleEditing(isEditing: isEditing)
            }
        }
        drawingTask = Task { @MainActor [weak self] in
            for await drawing in viewModel.drawing {
                guard let self else { return }
                drawingWidth = drawing.width
                applyViewModelDrawing(drawing)
                if canvasView.superview == nil {
                    setUpCanvasView()
                    pendingScrollPage = defaultsService.getValue(lastPageKey)
                }
            }
        }
        scribbleEraseTask = Task { @MainActor [weak self] in
            for await event in viewModel.scribbleEraseEvent {
                guard let self else { return }
                let beforeDrawing = event.beforeDrawing
                let afterDrawing = event.result.value
                drawingWidth = event.result.width
                if canvasView.superview == nil { setUpCanvasView() }
                registerDrawingUndo(before: beforeDrawing, after: afterDrawing)
                applyViewModelDrawing(event.result)
            }
        }
        backButtonTask = Task { @MainActor [weak self] in
            for await showsBackButton in viewModel.showsBackButton {
                self?.handleBackButton(showsBackButton: showsBackButton)
            }
        }
        backgroundTask = Task { @MainActor [weak self] in
            for await background in viewModel.background {
                await self?.applyBackground(background)
            }
        }
        loadingProgressTask = Task { @MainActor [weak self] in
            for await progress in viewModel.loadingProgress {
                self?.handleLoadingProgress(progress)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        assertionFailure("\(#function) has not been implemented")
        return nil
    }

    deinit {
        applicationBackgroundFlushTask?.cancel()
        if applicationBackgroundTaskIdentifier != .invalid {
            let identifier = applicationBackgroundTaskIdentifier
            Task { @MainActor in
                UIApplication.shared.endBackgroundTask(identifier)
            }
        }
        zoomSettleTask?.cancel()
        blankEditMenuDismissTask?.cancel()
        shapeHoldTask?.cancel()
        shapeCommitWatchdogTask?.cancel()
        toolUndoCleanupTask?.cancel()
        isEditingTask?.cancel()
        drawingTask?.cancel()
        scribbleEraseTask?.cancel()
        backButtonTask?.cancel()
        backgroundTask?.cancel()
        loadingProgressTask?.cancel()
        #if !targetEnvironment(macCatalyst)
        selectedToolUpdateTask?.cancel()
        MainActor.assumeIsolated {
            if isViewLoaded {
                toolPicker.removeObserver(canvasView)
                toolPicker.removeObserver(highlighterCanvasView)
                toolPicker.removeObserver(self)
            }
        }
        #endif
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setUpNavigationBar()
        setUpViews()
        restorePenTool()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        viewModel.didLoad()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        (navigationController?.navigationBar as? JottreNavigationBar)?
            .passesThroughBackgroundTouches = true
        updateCanvasTouchRouting()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        (navigationController?.navigationBar as? JottreNavigationBar)?
            .passesThroughBackgroundTouches = false
        flushPendingDrawingChange()
        saveScrollPosition()
        viewModel.didDisappear()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutCanvasContent()
        restoreScrollPositionIfNeeded()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        backgroundView.sync(
            scrollOffset: documentScrollView.contentOffset,
            zoomScale: documentScrollView.zoomScale,
            viewportSize: documentScrollView.bounds.size
        )
    }

    private func setUpNavigationBar() {
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.title = nil
        navigationItem.backButtonDisplayMode = .minimal

        let transparentAppearance = UINavigationBarAppearance()
        transparentAppearance.configureWithTransparentBackground()
        transparentAppearance.backgroundColor = .clear
        transparentAppearance.backgroundEffect = nil
        transparentAppearance.shadowColor = .clear
        navigationItem.standardAppearance = transparentAppearance
        navigationItem.scrollEdgeAppearance = transparentAppearance
        navigationItem.compactAppearance = transparentAppearance
        navigationItem.compactScrollEdgeAppearance = transparentAppearance

        navigationController?.navigationBar.isTranslucent = true
        setContentScrollView(nil, for: .top)
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true
        view.accessibilityLabel = viewModel.title
    }

    private func handleBackButton(showsBackButton: Bool) {
        guard showsBackButton else { return }
        navigationItem.leftBarButtonItem = symbolBarButtonItemFactory.make(
            symbolName: "chevron.left",
            primaryAction: .action(
                UIAction { [weak self] _ in
                    self?.viewModel.didTapBackButton()
                }
            )
        )
    }

    private func setUpViews() {
        view.backgroundColor = .adaptiveBlackWhite
        view.addGestureRecognizer(swipeBackGesture)
        #if !targetEnvironment(macCatalyst)
        toolPicker.addObserver(canvasView)
        toolPicker.addObserver(highlighterCanvasView)
        toolPicker.addObserver(self)
        toolPicker.setVisible(true, forFirstResponder: canvasView)
        toolPicker.setVisible(true, forFirstResponder: highlighterCanvasView)
        #endif
        view.addSubview(loadingProgressView)
        NSLayoutConstraint.activate([
            loadingProgressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            loadingProgressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingProgressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func restorePenTool() {
        #if !targetEnvironment(macCatalyst)
        let widthKey = DefaultsKey<Double>("editor.penWidth")
        let colorKey = DefaultsKey<String>("editor.penColorHex")
        if let width = defaultsService.getValue(widthKey) {
            let color = defaultsService.getValue(colorKey).flatMap { UIColor(hex: $0) } ?? .label
            let pen = PKInkingTool(.pen, color: color, width: CGFloat(width))
            canvasView.tool = pen
            highlighterCanvasView.tool = pen
            toolPicker.selectedTool = pen
            didSelectInitialPenTool = true
        }
        #endif
    }

    @discardableResult
    private func updateCanvasTouchRouting() -> Bool {
        #if !targetEnvironment(macCatalyst)
        let configuration = CanvasTouchRouting.configuration(
            isEditingEnabled: isEditingEnabled,
            drawingPolicy: inkCanvasCoordinator.activeCanvas.drawingPolicy,
            isToolPickerVisible: toolPicker.isVisible,
            prefersPencilOnlyDrawing: UIPencilInteraction.prefersPencilOnlyDrawing
        )
        // PencilKit rebuilds parts of its scroll and selection interaction
        // state while lasso content is moved. Reapply these idempotent
        // invariants for every new direct-touch sequence, even when the policy
        // itself did not change.
        CanvasTouchRouting.apply(
            configuration,
            to: [canvasView, highlighterCanvasView],
            documentScrollView: documentScrollView
        )
        return configuration.routesDirectTouchesToDocumentScroll
        #else
        return false
        #endif
    }

    @objc
    private func handleSwipeBack(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        viewModel.didTapBackButton()
    }

    @objc
    private func handleBlankCanvasEditMenuTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }

        blankEditMenuDismissTask?.cancel()
        dismissPencilKitEditMenus()
        blankEditMenuDismissTask = Task { @MainActor [weak self] in
            // Prevention is the primary path. These passes also close a menu
            // that an older PencilKit implementation may schedule after the
            // gesture arbitration callback has returned.
            // Incremental delays put the third pass just after PencilKit's
            // deferred single-tap callback on systems that schedule it.
            for delay in [0, 80, 300, 120, 200] {
                if delay == 0 {
                    await Task.yield()
                } else {
                    try? await Task.sleep(for: .milliseconds(delay))
                }
                guard !Task.isCancelled, let self else { return }
                dismissPencilKitEditMenus()
            }
        }
    }

    private func dismissPencilKitEditMenus() {
        inkCanvasCoordinator.activeCanvas.forEachViewInHierarchy { view in
            for case let interaction as UIEditMenuInteraction in view.interactions {
                interaction.dismissMenu()
            }
        }
    }

    @objc
    private func applicationDidEnterBackground() {
        guard viewIfLoaded?.window != nil else { return }
        flushPendingDrawingChange()
        saveScrollPosition()

        applicationBackgroundFlushTask?.cancel()
        finishApplicationBackgroundTask()
        let generation = UUID()
        applicationBackgroundTaskGeneration = generation
        applicationBackgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(
            withName: "Persist open jot"
        ) { [weak self, generation] in
            Task { @MainActor [weak self] in
                guard self?.applicationBackgroundTaskGeneration == generation else { return }
                self?.applicationBackgroundFlushTask?.cancel()
                _ = self?.finishApplicationBackgroundTask(generation: generation)
            }
        }
        applicationBackgroundFlushTask = Task { @MainActor [weak self, generation] in
            guard let self else { return }
            await viewModel.didEnterBackground()
            if finishApplicationBackgroundTask(generation: generation) {
                applicationBackgroundFlushTask = nil
            }
        }
    }

    @objc
    private func applicationDidBecomeActive() {
        // The system Pencil-only preference can change while Jottre is
        // suspended. Refresh document navigation before the next gesture.
        updateCanvasTouchRouting()
    }

    @discardableResult
    private func finishApplicationBackgroundTask(generation: UUID? = nil) -> Bool {
        if let generation, generation != applicationBackgroundTaskGeneration { return false }
        guard applicationBackgroundTaskIdentifier != .invalid else { return false }
        UIApplication.shared.endBackgroundTask(applicationBackgroundTaskIdentifier)
        applicationBackgroundTaskIdentifier = .invalid
        applicationBackgroundTaskGeneration = nil
        return true
    }

    private func layoutCanvasContent() {
        guard
            !isUsingDrawingTool,
            drawingWidth > 0,
            currentPageSize.width > 0,
            currentPageSize.height > 0,
            documentScrollView.bounds.width > 0,
            documentScrollView.bounds.height > 0
        else { return }

        let boundsSize = documentScrollView.bounds.size
        let widthScale = boundsSize.width / currentPageSize.width
        let heightScale = boundsSize.height / currentPageSize.height
        let pageFitScale = min(widthScale, heightScale)
        guard pageFitScale.isFinite, pageFitScale > 0 else { return }

        let wasAtMinimum = abs(documentScrollView.zoomScale - documentScrollView.minimumZoomScale) < 0.001
        let pageSizeChanged = currentPageSize != fittedPageSize
        let viewportSizeChanged = boundsSize != previousCanvasBoundsSize
        documentScrollView.minimumZoomScale = pageFitScale
        documentScrollView.maximumZoomScale = max(Constants.CanvasView.maximumZoomScale, pageFitScale)

        if !hasInitializedZoomScale || pageSizeChanged || (viewportSizeChanged && wasAtMinimum) {
            hasInitializedZoomScale = true
            documentScrollView.zoomScale = pageFitScale
        } else if documentScrollView.zoomScale < pageFitScale {
            documentScrollView.zoomScale = pageFitScale
        }
        previousCanvasBoundsSize = boundsSize
        fittedPageSize = currentPageSize

        updateCanvasGeometry()
    }

    private func updateCanvasGeometry() {
        guard !isUpdatingCanvasGeometry, drawingWidth > 0 else { return }
        isUpdatingCanvasGeometry = true
        defer { isUpdatingCanvasGeometry = false }

        let drawingMaxY: CGFloat
        if inkCanvasCoordinator.committedDrawing.bounds.isNull {
            drawingMaxY = backgroundContentHeight + Constants.CanvasView.bottomFreespace
        } else {
            let contentMaxY = max(
                inkCanvasCoordinator.committedDrawing.bounds.maxY,
                backgroundContentHeight
            )
            drawingMaxY = contentMaxY + Constants.CanvasView.bottomFreespace
        }

        let scale = documentScrollView.zoomScale
        let scaledWidth = drawingWidth * scale
        let nextDocumentContentSize = CGSize(width: drawingWidth, height: drawingMaxY)
        let documentGeometryChanged = documentContentSize != nextDocumentContentSize
        documentContentSize = nextDocumentContentSize

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let documentBounds = CGRect(origin: .zero, size: documentContentSize)
        if documentContainerView.bounds != documentBounds {
            documentContainerView.bounds = documentBounds
            documentContainerView.layer.position = .zero
        }
        if backgroundView.frame != documentBounds {
            backgroundView.frame = documentBounds
        }
        CATransaction.commit()

        // UIScrollView owns zoomed content sizing. Only seed or update it when
        // the underlying document geometry changes; never feed a transformed
        // UIView.frame back into UIScrollView during a zoom callback.
        if documentGeometryChanged || documentScrollView.contentSize == .zero {
            let scrollContentSize = CGSize(
                width: documentContentSize.width * scale,
                height: documentContentSize.height * scale
            )
            if documentScrollView.contentSize != scrollContentSize {
                documentScrollView.contentSize = scrollContentSize
            }
        }

        let horizontalInset = max(0, (documentScrollView.bounds.width - scaledWidth) / 2)
        // The canvas extends below the transparent navigation controls, but its
        // resting top position must leave the first part of the document visible.
        // A manual inset is required because automatic adjustment is disabled so
        // the document and ink can continue beneath the controls while scrolling.
        // The safe-area top includes the entire navigation bar and would create
        // too much unusable space. Reserve the status bar plus a small viewport
        // margin, while keeping document and ink coordinates rooted at zero.
        let statusBarHeight = max(
            0,
            view.window?.windowScene?.statusBarManager?.statusBarFrame.height ?? 0
        )
        let topInset = statusBarHeight + Constants.CanvasView.topWritingFreespace
        let previousInsets = documentScrollView.contentInset
        let wasAtTop =
            documentScrollView.contentOffset.y
            <= -previousInsets.top + 0.5
        let wasAtLeadingEdge =
            documentScrollView.contentOffset.x
            <= -previousInsets.left + 0.5
        let insets = UIEdgeInsets(
            top: topInset,
            left: horizontalInset,
            bottom: 0,
            right: horizontalInset
        )
        if documentScrollView.contentInset != insets {
            documentScrollView.contentInset = insets
        }
        // The page needs a viewport inset for writing space, but the scroll
        // indicator should still use the full track and sit at its true top.
        documentScrollView.verticalScrollIndicatorInsets.top = 0
        if wasAtTop, abs(documentScrollView.contentOffset.y + topInset) > 0.5 {
            documentScrollView.contentOffset.y = -topInset
        }
        if wasAtLeadingEdge,
            abs(documentScrollView.contentOffset.x + horizontalInset) > 0.5
        {
            documentScrollView.contentOffset.x = -horizontalInset
        }
        backgroundView.sync(
            scrollOffset: documentScrollView.contentOffset,
            zoomScale: scale,
            viewportSize: documentScrollView.bounds.size
        )
        updateVisibleInkRegion(force: documentGeometryChanged)
    }

    private func setUpCanvasView() {
        if #available(iOS 26.0, *) {
            // iOS 26 adds a white scroll-edge fade automatically for content
            // underneath navigation controls. It obscures both the PDF and ink.
            documentScrollView.topEdgeEffect.isHidden = true
            canvasView.topEdgeEffect.isHidden = true
            highlighterCanvasView.topEdgeEffect.isHidden = true
        }
        view.addSubview(documentScrollView)
        NSLayoutConstraint.activate([
            documentScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            documentScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            documentScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            documentScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        documentScrollView.addSubview(documentContainerView)
        documentContainerView.addSubview(backgroundView)
        documentContainerView.addSubview(highlighterInkContainerView)
        highlighterInkContainerView.addSubview(highlighterCanvasView)
        documentContainerView.addSubview(inkContainerView)
        inkContainerView.addSubview(canvasView)
        canvasView.drawingGestureRecognizer.addTarget(
            self,
            action: #selector(handleDrawingGesture(_:))
        )
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        #if !targetEnvironment(macCatalyst)
        doubleTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        #endif
        documentScrollView.addGestureRecognizer(doubleTap)
        documentScrollView.addGestureRecognizer(blankCanvasEditMenuTapGesture)
        updateCanvasInteraction()
        view.bringSubviewToFront(loadingProgressView)
    }

    private func applyViewModelDrawing(_ drawing: EditJotViewModel.Drawing) {
        inkCanvasCoordinator.load(
            drawing: drawing.value,
            strokePageIndices: drawing.strokePageIndices
        )
    }

    private func combinedCanvasDrawing() -> PKDrawing {
        inkCanvasCoordinator.liveCombinedDrawing()
    }

    private func commitCanvasDrawing(detectsScribbleErase: Bool = true) {
        hasPendingDrawingChange = false
        let previousExtent = contentExtent(for: inkCanvasCoordinator.committedDrawing)
        let liveDrawing = combinedCanvasDrawing()
        let indices = reconciledPageIndices(for: liveDrawing)
        let combined = inkCanvasCoordinator.commitLiveDrawing(
            liveDrawing,
            strokePageIndices: indices
        )
        viewModel.didChangeDrawing(
            combined,
            strokePageIndices: inkCanvasCoordinator.committedStrokePageIndices,
            detectsScribbleErase: detectsScribbleErase
                && inkCanvasCoordinator.mode != .highlighter
        )
        finishToolUndoGrouping()
        if contentExtent(for: combined) != previousExtent {
            updateCanvasGeometry()
        }
    }

    private func reconciledPageIndices(for drawing: PKDrawing) -> [Int] {
        var oldIndicesBySeed: [UInt32: [Int]] = [:]
        for (index, stroke) in inkCanvasCoordinator.committedDrawing.strokes.enumerated() {
            let pageIndex =
                inkCanvasCoordinator.committedStrokePageIndices.indices.contains(index)
                ? inkCanvasCoordinator.committedStrokePageIndices[index]
                : pageIndex(for: stroke)
            oldIndicesBySeed[stroke.randomSeed, default: []].append(pageIndex)
        }

        return drawing.strokes.map { stroke in
            if var matching = oldIndicesBySeed[stroke.randomSeed], !matching.isEmpty {
                let pageIndex = matching.removeFirst()
                oldIndicesBySeed[stroke.randomSeed] = matching
                return pageIndex
            }
            return pageIndex(for: stroke)
        }
    }

    private func contentExtent(for drawing: PKDrawing) -> CGFloat {
        guard !drawing.bounds.isNull else { return backgroundContentHeight }
        return max(backgroundContentHeight, drawing.bounds.maxY)
    }

    private func pageIndex(for stroke: PKStroke) -> Int {
        let stride = currentPageSize.height + JotBackgroundView.pageSpacing
        guard stride.isFinite, stride > 0 else { return 0 }
        return max(0, Int(floor(max(0, stroke.renderBounds.midY) / stride)))
    }

    @objc
    private func handleDrawingGesture(_ gestureRecognizer: UIGestureRecognizer) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let location = gestureRecognizer.location(in: view)

        switch gestureRecognizer.state {
        case .began:
            guard isDrawAndHoldShapeConversionEnabled,
                isEditingEnabled,
                inkCanvasCoordinator.mode == .foreground,
                let inkingTool = canvasView.tool as? PKInkingTool,
                inkingTool.inkType != .marker
            else {
                cancelShapeHold()
                return
            }
            var detector = EndpointHoldDetector(
                configuration: .init(
                    holdDuration: Constants.CanvasView.shapeHoldDuration,
                    movementTolerance: Constants.CanvasView.shapeHoldMovementTolerance
                )
            )
            detector.begin(at: location, timestamp: timestamp)
            let before =
                drawingBeforeToolUse
                ?? EditJotViewModel.Drawing(
                    value: inkCanvasCoordinator.committedDrawing,
                    width: drawingWidth,
                    strokePageIndices: inkCanvasCoordinator.committedStrokePageIndices
                )
            shapeHoldState = ShapeHoldState(
                initialStrokeCount: canvasView.drawing.strokes.count,
                beforeDrawing: before,
                detector: detector
            )
            scheduleShapeHoldDeadline()

        case .changed:
            guard var state = shapeHoldState else { return }
            let resetDeadline = state.detector.move(to: location, timestamp: timestamp)
            shapeHoldState = state
            if resetDeadline {
                scheduleShapeHoldDeadline()
            }

        case .ended:
            shapeHoldTask?.cancel()
            guard var state = shapeHoldState else { return }
            let shouldSnap = state.detector.end(at: timestamp)
            shapeHoldState = state
            guard shouldSnap else {
                cancelShapeHold()
                if !isUsingDrawingTool { flushPendingDrawingChange() }
                return
            }
            if !attemptShapeSnapIfReady() {
                scheduleShapeCommitWatchdog()
            }

        case .cancelled, .failed:
            cancelShapeHold()
            if !isUsingDrawingTool { flushPendingDrawingChange() }

        default:
            break
        }
    }

    private func scheduleShapeHoldDeadline() {
        shapeHoldTask?.cancel()
        guard let state = shapeHoldState,
            let deadline = state.detector.deadline
        else { return }
        let generation = state.detector.generation
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        shapeHoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, var state = shapeHoldState else { return }
            guard
                state.detector.update(
                    at: ProcessInfo.processInfo.systemUptime,
                    generation: generation
                )
            else { return }
            if !state.didProvideHoldFeedback {
                state.didProvideHoldFeedback = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
            }
            shapeHoldState = state
        }
    }

    /// PencilKit may publish its final pressure samples after both the touch and
    /// `canvasViewDidEndUsingTool`. Keep the qualified hold alive until exactly
    /// one committed stroke is available, then replace only that stroke.
    @discardableResult
    private func attemptShapeSnapIfReady() -> Bool {
        guard !isUsingDrawingTool,
            let state = shapeHoldState,
            state.detector.shouldSnapAfterStrokeCommit
        else { return false }

        let strokes = canvasView.drawing.strokes
        guard strokes.count == state.initialStrokeCount + 1 else {
            if strokes.count > state.initialStrokeCount + 1 {
                cancelShapeHold()
                hasPendingDrawingChange = true
                flushPendingDrawingChange()
                finishToolUndoGrouping()
                return true
            }
            return false
        }

        guard let sourceStroke = strokes.last,
            let snapped = PencilStrokeShapeSnapper.snap(sourceStroke)
        else {
            cancelShapeHold()
            hasPendingDrawingChange = true
            flushPendingDrawingChange()
            return true
        }

        var snappedStrokes = strokes
        snappedStrokes[snappedStrokes.count - 1] = snapped.stroke
        let snappedCanvasDrawing = PKDrawing(strokes: snappedStrokes)

        // Replacing the completed stroke directly avoids cross-fading every
        // existing ink tile. The localized haptic below provides snap feedback.
        inkCanvasCoordinator.replaceDrawing(snappedCanvasDrawing, on: canvasView)

        let partition = JotDrawingLayerPartition(drawing: combinedCanvasDrawing())
        let snappedCombined = partition.combined
        let snappedIndices = reconciledPageIndices(for: snappedCombined)
        let after = EditJotViewModel.Drawing(
            value: snappedCombined,
            width: drawingWidth,
            strokePageIndices: snappedIndices
        )
        registerDrawingUndo(snapshot: state.beforeDrawing, inverse: after)
        toolUndoManager?.setActionName("Snap to Shape")
        shapeHoldState = nil
        shapeHoldTask?.cancel()
        shapeCommitWatchdogTask?.cancel()
        hasPendingDrawingChange = false
        commitCanvasDrawing(detectsScribbleErase: false)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.85)
        return true
    }

    private func scheduleShapeCommitWatchdog() {
        shapeCommitWatchdogTask?.cancel()
        shapeCommitWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            if !attemptShapeSnapIfReady() {
                cancelShapeHold()
                if inkCanvasCoordinator.hasUncommittedChanges {
                    commitCanvasDrawing()
                } else {
                    finishToolUndoGrouping()
                }
            }
        }
    }

    private func cancelShapeHold() {
        shapeHoldTask?.cancel()
        shapeHoldTask = nil
        shapeHoldState = nil
    }

    private func registerDrawingUndo(before: PKDrawing, after: PKDrawing) {
        let beforeIndices =
            before.strokes.count == inkCanvasCoordinator.committedStrokePageIndices.count
            ? inkCanvasCoordinator.committedStrokePageIndices
            : reconciledPageIndices(for: before)
        let afterIndices =
            viewModel.currentStrokePageIndices.count == after.strokes.count
            ? viewModel.currentStrokePageIndices
            : reconciledPageIndices(for: after)
        let beforeSnapshot = EditJotViewModel.Drawing(
            value: before,
            width: drawingWidth,
            strokePageIndices: beforeIndices
        )
        let afterSnapshot = EditJotViewModel.Drawing(
            value: after,
            width: drawingWidth,
            strokePageIndices: afterIndices
        )
        registerDrawingUndo(snapshot: beforeSnapshot, inverse: afterSnapshot)
    }

    private func registerDrawingUndo(
        snapshot: EditJotViewModel.Drawing,
        inverse: EditJotViewModel.Drawing
    ) {
        inkUndoManager?.registerUndo(withTarget: self) { target in
            target.applyDrawingUndo(snapshot, inverse: inverse)
        }
    }

    private func applyDrawingUndo(
        _ snapshot: EditJotViewModel.Drawing,
        inverse: EditJotViewModel.Drawing
    ) {
        viewModel.prepareForUndoRedo(expectedDrawing: snapshot.value)
        applyViewModelDrawing(snapshot)
        viewModel.didChangeDrawing(
            snapshot.value,
            strokePageIndices: snapshot.strokePageIndices,
            detectsScribbleErase: false
        )
        registerDrawingUndo(snapshot: inverse, inverse: snapshot)
    }

    private func finishToolUndoGrouping() {
        if ownsToolUndoGrouping {
            toolUndoManager?.endUndoGrouping()
            ownsToolUndoGrouping = false
        }
        toolUndoManager = nil
        drawingBeforeToolUse = nil
    }

    private var inkUndoManager: UndoManager? {
        toolUndoManager ?? inkCanvasCoordinator.activeCanvas.undoManager ?? canvasView.undoManager
    }

    @objc
    private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let scales = pageZoomScales() else { return }

        // `fillShortEdge` fills either the viewport width or height, whichever
        // requires more magnification. `fitLongEdge` keeps the entire page visible.
        let isAtOrBeyondShortEdgeFill =
            documentScrollView.zoomScale
            >= scales.fillShortEdge * (1 - 0.02)
        let targetScale =
            isAtOrBeyondShortEdgeFill
            ? scales.fitLongEdge
            : scales.fillShortEdge

        isZoomInteractionActive = true
        backgroundView.setZoomInteractionActive(true)
        documentScrollView.setZoomScale(targetScale, animated: true)
        scheduleZoomSettling()
    }

    private func pageZoomScales() -> (fitLongEdge: CGFloat, fillShortEdge: CGFloat)? {
        guard
            currentPageSize.width.isFinite,
            currentPageSize.height.isFinite,
            currentPageSize.width > 0,
            currentPageSize.height > 0,
            documentScrollView.bounds.width > 0,
            documentScrollView.bounds.height > 0
        else { return nil }

        let widthScale = documentScrollView.bounds.width / currentPageSize.width
        let heightScale = documentScrollView.bounds.height / currentPageSize.height
        let fitLongEdge = max(
            documentScrollView.minimumZoomScale,
            min(widthScale, heightScale)
        )
        let fillShortEdge = min(
            documentScrollView.maximumZoomScale,
            max(widthScale, heightScale)
        )
        return (fitLongEdge, max(fitLongEdge, fillShortEdge))
    }

    /// Keeps a buffered PencilKit viewport in the same document coordinates as
    /// the PDF. `documentScrollView` is the sole zoom owner; the nested canvases
    /// always stay at `zoomScale` 1 and are only cropped to this allocation for
    /// performance.
    ///
    /// The canvases do, however, follow the zoom through `contentScaleFactor`.
    /// PencilKit stores ink as vector strokes and re-tessellates them for the
    /// backing store it is given, so raising that density is what keeps strokes
    /// smooth instead of letting Core Animation magnify a 1x rasterization.
    private func updateVisibleInkRegion(force: Bool = false) {
        guard
            canvasView.superview != nil,
            documentScrollView.bounds.width > 0,
            documentScrollView.bounds.height > 0,
            documentContentSize.width > 0,
            documentContentSize.height > 0
        else { return }

        // View conversion is the authoritative mapping. It includes the zoom
        // transform, content offset, centering insets, and zoom bounce without
        // duplicating UIScrollView's private coordinate calculations.
        let requestedVisibleRect = documentScrollView.convert(
            documentScrollView.bounds,
            to: documentContainerView
        )
        // Re-tessellating strokes mid-pinch would stall the gesture. Hold the
        // previous density until the zoom settles; Core Animation covers the
        // intermediate frames by scaling the existing backing store.
        let inkContentScale: CGFloat
        if isZoomInteractionActive, appliedInkContentScale > 0 {
            inkContentScale = appliedInkContentScale
        } else {
            inkContentScale = PageRasterizationPolicy.inkContentScale(
                zoomScale: documentScrollView.zoomScale,
                displayScale: max(1, traitCollection.displayScale)
            )
        }
        guard
            let proposedLayout = InkViewportLayout.make(
                visibleDocumentRect: requestedVisibleRect,
                documentSize: documentContentSize,
                overscan: PageRasterizationPolicy.inkViewportOverscan(
                    zoomScale: documentScrollView.zoomScale
                )
            )
        else { return }

        let layout: InkViewportLayout
        if !force,
            !allocatedInkDocumentRect.isNull,
            let reused = proposedLayout.reusingAllocatedDocumentRect(
                allocatedInkDocumentRect
            )
        {
            layout = reused
        } else {
            layout = proposedLayout
        }

        let inkPlanes = [
            (canvas: canvasView, container: inkContainerView),
            (canvas: highlighterCanvasView, container: highlighterInkContainerView),
        ]
        guard
            force
                || !inkPlanes.allSatisfy({ plane in
                    inkGeometryMatches(
                        canvas: plane.canvas,
                        container: plane.container,
                        layout: layout,
                        contentScale: inkContentScale
                    )
                })
        else {
            allocatedInkDocumentRect = layout.allocatedDocumentRect
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for plane in inkPlanes {
            plane.container.transform = .identity
            plane.container.bounds = layout.viewportBounds
            plane.container.layer.position = layout.allocatedDocumentRect.origin
            plane.canvas.transform = .identity

            // Expand the current range to include 1x before collapsing it. This
            // also safely normalizes a canvas created by an older editor state.
            plane.canvas.minimumZoomScale = min(1, plane.canvas.minimumZoomScale)
            plane.canvas.maximumZoomScale = max(1, plane.canvas.maximumZoomScale)
            plane.canvas.zoomScale = 1
            plane.canvas.minimumZoomScale = 1
            plane.canvas.maximumZoomScale = 1
            plane.canvas.contentInset = .zero
            plane.canvas.contentSize = layout.documentSize
            plane.canvas.bounds.size = layout.viewportBounds.size
            plane.canvas.layer.position = .zero
            if plane.canvas.contentOffset != layout.canvasContentOffset {
                plane.canvas.contentOffset = layout.canvasContentOffset
            }
            applyInkContentScale(inkContentScale, to: plane.canvas)
        }
        CATransaction.commit()
        appliedInkContentScale = inkContentScale
        allocatedInkDocumentRect = layout.allocatedDocumentRect
    }

    /// PencilKit renders ink into subviews of the canvas, so the density has to
    /// be pushed through the whole subtree rather than set on the canvas alone.
    private func applyInkContentScale(_ scale: CGFloat, to canvas: PKCanvasView) {
        canvas.forEachViewInHierarchy { view in
            if abs(view.contentScaleFactor - scale) > 0.0001 {
                view.contentScaleFactor = scale
            }
            if abs(view.layer.contentsScale - scale) > 0.0001 {
                view.layer.contentsScale = scale
            }
        }
    }

    private func inkGeometryMatches(
        canvas: PKCanvasView,
        container: UIView,
        layout: InkViewportLayout,
        contentScale: CGFloat
    ) -> Bool {
        container.transform == .identity
            && container.bounds == layout.viewportBounds
            && approximatelyEqual(
                container.layer.position,
                layout.allocatedDocumentRect.origin
            )
            && canvas.transform == .identity
            && abs(canvas.minimumZoomScale - 1) < 0.0001
            && abs(canvas.maximumZoomScale - 1) < 0.0001
            && abs(canvas.zoomScale - 1) < 0.0001
            && canvas.contentInset == .zero
            && canvas.contentSize == layout.documentSize
            && canvas.bounds.size == layout.viewportBounds.size
            && approximatelyEqual(canvas.layer.position, .zero)
            && approximatelyEqual(canvas.contentOffset, layout.canvasContentOffset)
            && abs(canvas.contentScaleFactor - contentScale) < 0.0001
    }

    private func approximatelyEqual(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) < 0.001 && abs(lhs.y - rhs.y) < 0.001
    }

    private func scheduleZoomSettling() {
        zoomSettleTask?.cancel()
        zoomSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            isZoomInteractionActive = false
            updateVisibleInkRegion(force: true)
            backgroundView.setZoomInteractionActive(false)
        }
    }

    fileprivate func documentScrollViewDidScroll(_ scrollView: UIScrollView) {
        backgroundView.sync(
            scrollOffset: scrollView.contentOffset,
            zoomScale: scrollView.zoomScale,
            viewportSize: scrollView.bounds.size
        )
        updateVisibleInkRegion()
    }

    fileprivate func documentViewForZooming() -> UIView {
        documentContainerView
    }

    fileprivate func documentScrollViewDidZoom(_ scrollView: UIScrollView) {
        updateCanvasGeometry()
    }

    fileprivate func documentScrollViewWillBeginZooming() {
        zoomSettleTask?.cancel()
        isZoomInteractionActive = true
        backgroundView.setZoomInteractionActive(true)
    }

    fileprivate func documentScrollViewDidEndZooming() {
        zoomSettleTask?.cancel()
        isZoomInteractionActive = false
        updateVisibleInkRegion(force: true)
        backgroundView.setZoomInteractionActive(false)
    }

    fileprivate func documentScrollViewWillEndDragging(targetContentOffset: CGPoint) {
        backgroundView.prefetch(toward: targetContentOffset)
    }

    fileprivate func documentScrollViewDidFinishDecelerating() {
        backgroundView.finishScrollPrefetch()
    }

    private func handleLoadingProgress(_ progress: Double?) {
        guard let progress else {
            UIView.animate(withDuration: 0.4) { self.loadingProgressView.alpha = 0 }
            return
        }
        loadingProgressView.setProgress(Float(progress), animated: progress > 0)
    }

    private var lastPageKey: DefaultsKey<Int> {
        DefaultsKey<Int>("jot.lastPage.\(viewModel.jotFileInfo.url.path)")
    }

    private func saveScrollPosition() {
        guard drawingWidth > 0, documentScrollView.zoomScale > 0 else { return }
        let pageFullHeight =
            (currentPageSize.height + JotBackgroundView.pageSpacing)
            * documentScrollView.zoomScale
        guard pageFullHeight > 0 else { return }
        let visibleTop = documentScrollView.contentOffset.y + documentScrollView.contentInset.top
        let page = Int(floor(max(0, visibleTop) / pageFullHeight))
        defaultsService.set(lastPageKey, value: page)
    }

    private func restoreScrollPositionIfNeeded() {
        guard let page = pendingScrollPage, page > 0, drawingWidth > 0 else { return }
        let maxOffsetY = max(
            0,
            documentContentSize.height * documentScrollView.zoomScale
                - documentScrollView.bounds.height
        )
        guard maxOffsetY > 0 else { return }
        pendingScrollPage = nil
        let pageFullHeight =
            (currentPageSize.height + JotBackgroundView.pageSpacing)
            * documentScrollView.zoomScale
        let targetOffsetY = CGFloat(page) * pageFullHeight - documentScrollView.contentInset.top
        documentScrollView.contentOffset = CGPoint(
            x: -documentScrollView.contentInset.left,
            y: min(targetOffsetY, maxOffsetY)
        )
    }

}

// MARK: - Blank Canvas Menu Suppression

extension EditJotViewController: UIGestureRecognizerDelegate {

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard gestureRecognizer === blankCanvasEditMenuTapGesture else { return true }
        let activeCanvas = inkCanvasCoordinator.activeCanvas
        guard let touchedView = touch.view,
            touchedView === activeCanvas || touchedView.isDescendant(of: activeCanvas)
        else { return false }

        blankCanvasEditMenuTapGesture.canvasRootViews = [activeCanvas]
        return CanvasEditMenuSuppressionPolicy.blocksDirectTouch(
            isEditingEnabled: isEditingEnabled,
            isLassoTool: activeCanvas.tool is PKLassoTool,
            routesDirectTouchesToDocumentScroll: updateCanvasTouchRouting()
        )
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard
            gestureRecognizer === blankCanvasEditMenuTapGesture
                || otherGestureRecognizer === blankCanvasEditMenuTapGesture
        else { return false }

        let companion =
            gestureRecognizer === blankCanvasEditMenuTapGesture
            ? otherGestureRecognizer : gestureRecognizer
        guard let tapGesture = companion as? UITapGestureRecognizer else { return false }
        return tapGesture.numberOfTapsRequired > 1
    }
}

#if !targetEnvironment(macCatalyst)
// MARK: - PKToolPickerObserver

extension EditJotViewController: PKToolPickerObserver {

    func toolPickerSelectedToolDidChange(_ toolPicker: PKToolPicker) {
        scheduleSelectedCanvasToolUpdate()
    }

    @available(iOS 18.0, *)
    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        scheduleSelectedCanvasToolUpdate()
    }

    func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) {
        updateCanvasTouchRouting()
    }

    private func scheduleSelectedCanvasToolUpdate() {
        // PencilKit's observer callback can precede propagation of the selected
        // tool to PKCanvasView. Inspect it on the next main-actor turn.
        selectedToolUpdateTask?.cancel()
        selectedToolUpdateTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.selectedCanvasToolDidChange()
        }
    }

    private func selectedCanvasToolDidChange() {
        let wasLassoTool = inkCanvasCoordinator.activeCanvas.tool is PKLassoTool
        let selectedTool = toolPicker.selectedTool
        canvasView.tool = selectedTool
        highlighterCanvasView.tool = selectedTool

        blankEditMenuDismissTask?.cancel()
        if !isEditingEnabled || !wasLassoTool || !(selectedTool is PKLassoTool) {
            dismissPencilKitEditMenus()
        }

        let nextMode: JotInkCanvasCoordinator.Mode
        if let inkingTool = selectedTool as? PKInkingTool {
            nextMode = inkingTool.inkType == .marker ? .highlighter : .foreground
        } else if selectedTool is PKLassoTool || selectedTool is PKEraserTool {
            nextMode = .combined
        } else {
            nextMode = .foreground
        }

        if inkCanvasCoordinator.mode != nextMode,
            hasPendingDrawingChange || inkCanvasCoordinator.hasUncommittedChanges
        {
            commitCanvasDrawing()
        }
        inkCanvasCoordinator.transition(to: nextMode)
        blankCanvasEditMenuTapGesture.canvasRootViews = [inkCanvasCoordinator.activeCanvas]
        updateCanvasInteraction()
        updateCanvasTouchRouting()
    }
}
#endif

// MARK: - Navigation

extension EditJotViewController {

    fileprivate func handleEditing(isEditing: Bool?) {
        let rightNavigationBarButtonItems = makeRightNavigationBarButtonItems(isEditing: isEditing)
        isEditingEnabled = isEditing == true

        if let isEditing, isEditing {
            swipeBackGesture.isEnabled = false

            #if !targetEnvironment(macCatalyst)
            if !didSelectInitialPenTool {
                didSelectInitialPenTool = true
                if !(canvasView.tool is PKInkingTool) {
                    let pen = PKInkingTool(.pen, color: .label, width: 5)
                    canvasView.tool = pen
                    highlighterCanvasView.tool = pen
                    toolPicker.selectedTool = pen
                }
            }
            #endif
        } else {
            swipeBackGesture.isEnabled = true
            #if !targetEnvironment(macCatalyst)
            if let inking = inkCanvasCoordinator.activeCanvas.tool as? PKInkingTool {
                let widthKey = DefaultsKey<Double>("editor.penWidth")
                let colorKey = DefaultsKey<String>("editor.penColorHex")
                defaultsService.set(widthKey, value: Double(inking.width))
                defaultsService.set(colorKey, value: inking.color.hexString)
            }
            #endif
        }

        #if !targetEnvironment(macCatalyst)
        selectedCanvasToolDidChange()
        #else
        updateCanvasInteraction()
        updateCanvasTouchRouting()
        #endif

        if let firstItem = rightNavigationBarButtonItems.first,
            rightNavigationBarButtonItems.count == 1
        {
            navigationItem.setRightBarButton(firstItem, animated: false)
        } else {
            navigationItem.setRightBarButtonItems(rightNavigationBarButtonItems, animated: false)
        }
    }

    private func updateCanvasInteraction() {
        let activeCanvas = inkCanvasCoordinator.activeCanvas
        let inkPlanes = [
            (canvas: highlighterCanvasView, container: highlighterInkContainerView),
            (canvas: canvasView, container: inkContainerView),
        ]
        for plane in inkPlanes {
            let canvas = plane.canvas
            let isActive = isEditingEnabled && canvas === activeCanvas
            plane.container.isUserInteractionEnabled = isActive
            canvas.isUserInteractionEnabled = isActive
            if #available(iOS 18.0, *) {
                canvas.isDrawingEnabled = isActive
            }
            if !isActive {
                canvas.resignFirstResponder()
            }
        }

        guard isEditingEnabled else { return }
        #if !targetEnvironment(macCatalyst)
        toolPicker.setVisible(true, forFirstResponder: activeCanvas)
        #endif
        activeCanvas.becomeFirstResponder()
    }

    private var isDrawAndHoldShapeConversionEnabled: Bool {
        defaultsService.getValue(.drawAndHoldShapeConversionEnabled) ?? true
    }

    @discardableResult
    private func toggleDrawAndHoldShapeConversion() -> Bool {
        let isEnabled = !isDrawAndHoldShapeConversionEnabled
        defaultsService.set(.drawAndHoldShapeConversionEnabled, value: isEnabled)

        if !isEnabled {
            cancelShapeHold()
            shapeCommitWatchdogTask?.cancel()
            shapeCommitWatchdogTask = nil
            if !isUsingDrawingTool {
                flushPendingDrawingChange()
                finishToolUndoGrouping()
            }
        }

        return isEnabled
    }

    private func makeDrawAndHoldShapeConversionMenuElement() -> UIDeferredMenuElement {
        UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else {
                completion([])
                return
            }
            let action = UIAction(
                title: L10n.EditJot.ShapeSnap.title,
                image: UIImage(systemName: "square.on.circle"),
                state: isDrawAndHoldShapeConversionEnabled ? .on : .off
            ) { [weak self] action in
                guard let self else { return }
                let isEnabled = toggleDrawAndHoldShapeConversion()
                action.state = isEnabled ? .on : .off
            }
            completion([action])
        }
    }

    fileprivate func makeRightNavigationBarButtonItems(isEditing: Bool?) -> [UIBarButtonItem] {
        var barButtonItems = [UIBarButtonItem]()

        weak var moreBarButtonItemRef: UIBarButtonItem?
        viewModel.visiblePageProvider = { [weak self] in
            guard let self else { return nil }
            let offsetY =
                documentScrollView.contentOffset.y
                + documentScrollView.contentInset.top
            let pageFullHeight =
                (currentPageSize.height + JotBackgroundView.pageSpacing)
                * documentScrollView.zoomScale
            return Int(floor(max(0, offsetY) / pageFullHeight))
        }
        let menuConfigurations = viewModel.menuConfigurations.make(popoverAnchorProvider: {
            guard let barButtonItem = moreBarButtonItemRef else { return nil }
            return { $0.barButtonItem = barButtonItem }
        })
        let pagesIndex = menuConfigurations.firstIndex { configuration in
            guard case let .group(group) = configuration else { return false }
            return group.title == L10n.EditJot.Pages.title
        }
        let baseMenu = UIMenu.make(jotMenuConfigurations: menuConfigurations)
        var menuChildren = baseMenu.children
        let shapeConversionIndex = pagesIndex.map { $0 + 1 } ?? menuChildren.endIndex
        menuChildren.insert(
            makeDrawAndHoldShapeConversionMenuElement(),
            at: shapeConversionIndex
        )
        let menu = baseMenu.replacingChildren(menuChildren)
        let moreBarButtonItem = symbolBarButtonItemFactory.make(
            symbolName: "ellipsis",
            primaryAction: .menu(menu)
        )
        moreBarButtonItemRef = moreBarButtonItem
        barButtonItems.append(moreBarButtonItem)

        if let isEditing {
            barButtonItems.append(
                symbolBarButtonItemFactory.make(
                    symbolName: isEditing ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle",
                    primaryAction: .action(
                        UIAction { [weak self] _ in
                            self?.viewModel.didTapToggleEditingButton(isEditing: isEditing)
                        }
                    )
                )
            )
        }

        return barButtonItems
    }
}

// MARK: - Background

extension EditJotViewController {

    fileprivate func applyBackground(_ background: EditJotViewModel.Background) async {
        let pageSize = CGSize(width: Constants.Page.width, height: Constants.Page.height)
        currentPageSize = pageSize
        let spacing = JotBackgroundView.pageSpacing

        switch background {
        case let .ruled(extraPages):
            cachedPDFData = nil
            cachedPDFLoadResult = nil
            applyDocumentAppearance(isPDFBacked: false)
            let totalPageCount = 1 + extraPages
            backgroundContentHeight =
                CGFloat(totalPageCount) * pageSize.height
                + max(0, CGFloat(totalPageCount - 1)) * spacing
            backgroundView.configureRuled(
                pageCount: totalPageCount,
                pageSize: pageSize,
                scrollOffset: documentScrollView.contentOffset,
                zoomScale: documentScrollView.zoomScale
            )

        case let .pdf(data, _, insertedPageSlots):
            applyDocumentAppearance(isPDFBacked: true)
            do {
                let result: PDFLoadService.Result
                if cachedPDFData == data, let cachedPDFLoadResult {
                    result = cachedPDFLoadResult
                } else {
                    let loadService = pdfLoadService
                    result = try await Task.detached(priority: .userInitiated) {
                        try loadService.load(data: data, normalizedPageSize: pageSize)
                    }.value
                    guard !Task.isCancelled else { return }
                    cachedPDFData = data
                    cachedPDFLoadResult = result
                }
                let pdfPageSize = result.pageSize
                currentPageSize = pdfPageSize
                let totalPages = CGFloat(result.pageCount + insertedPageSlots.count)
                backgroundContentHeight =
                    totalPages * pdfPageSize.height
                    + max(0, totalPages - 1) * spacing
                backgroundView.configurePDF(
                    document: result.document,
                    pageSize: pdfPageSize,
                    insertedPageSlots: insertedPageSlots,
                    scrollOffset: documentScrollView.contentOffset,
                    zoomScale: documentScrollView.zoomScale
                )
            } catch {
                cachedPDFData = nil
                cachedPDFLoadResult = nil
                // A malformed/empty PDF must not take down the editor. Keep the
                // handwriting available over a plain page so it can still be saved.
                backgroundContentHeight = pageSize.height
                backgroundView.configureRuled(
                    pageCount: 1,
                    pageSize: pageSize,
                    scrollOffset: documentScrollView.contentOffset,
                    zoomScale: documentScrollView.zoomScale
                )
            }
        }
        layoutCanvasContent()
    }

    /// PencilKit interprets its black/white palette relative to the canvas's
    /// appearance. PDF pages always use their authored (light) appearance, so
    /// the picker must create colors for a light canvas even when its own UI is
    /// dark. Plain notes keep PencilKit's normal adaptive appearance.
    fileprivate func applyDocumentAppearance(isPDFBacked: Bool) {
        let canvasStyle: UIUserInterfaceStyle = isPDFBacked ? .light : .unspecified
        canvasView.overrideUserInterfaceStyle = canvasStyle
        highlighterCanvasView.overrideUserInterfaceStyle = canvasStyle
        backgroundView.overrideUserInterfaceStyle = canvasStyle
        #if !targetEnvironment(macCatalyst)
        toolPicker.colorUserInterfaceStyle = canvasStyle
        #endif
    }
}

extension UIView {

    fileprivate func forEachViewInHierarchy(_ operation: (UIView) -> Void) {
        operation(self)
        for subview in subviews {
            subview.forEachViewInHierarchy(operation)
        }
    }
}

// MARK: - UIColor hex

extension UIColor {

    fileprivate convenience init?(hex: String) {
        var str = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasPrefix("#") { str.removeFirst() }
        guard str.count == 6 || str.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: str).scanHexInt64(&value) else { return nil }
        if str.count == 6 {
            let red = CGFloat((value & 0xFF0000) >> 16) / 255.0
            let green = CGFloat((value & 0x00FF00) >> 8) / 255.0
            let blue = CGFloat(value & 0x0000FF) / 255.0
            self.init(red: red, green: green, blue: blue, alpha: 1)
        } else {
            let alpha = CGFloat((value & 0xFF00_0000) >> 24) / 255.0
            let red = CGFloat((value & 0x00FF_0000) >> 16) / 255.0
            let green = CGFloat((value & 0x0000_FF00) >> 8) / 255.0
            let blue = CGFloat(value & 0x0000_00FF) / 255.0
            self.init(red: red, green: green, blue: blue, alpha: alpha)
        }
    }

    fileprivate var hexString: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let redByte = UInt8(round(red * 255))
        let greenByte = UInt8(round(green * 255))
        let blueByte = UInt8(round(blue * 255))
        guard alpha >= 1.0 else {
            let alphaByte = UInt8(round(alpha * 255))
            return String(format: "%02X%02X%02X%02X", alphaByte, redByte, greenByte, blueByte)
        }
        return String(format: "%02X%02X%02X", redByte, greenByte, blueByte)
    }
}

// MARK: - PKCanvasViewDelegate

extension EditJotViewController: PKCanvasViewDelegate {

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard inkCanvasCoordinator.noteDrawingDidChange(from: canvasView) else { return }
        guard !isUsingDrawingTool else {
            hasPendingDrawingChange = true
            return
        }
        updateCanvasTouchRouting()
        if canvasView === self.canvasView, attemptShapeSnapIfReady() { return }
        if canvasView === self.canvasView, shapeHoldState != nil {
            hasPendingDrawingChange = true
            scheduleShapeCommitWatchdog()
            return
        }
        commitCanvasDrawing()
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        guard inkCanvasCoordinator.role(of: canvasView) != nil,
            canvasView === inkCanvasCoordinator.activeCanvas
        else { return }
        isUsingDrawingTool = true
        zoomSettleTask?.cancel()
        isZoomInteractionActive = false
        backgroundView.setZoomInteractionActive(false)
        shapeCommitWatchdogTask?.cancel()
        toolUndoCleanupTask?.cancel()
        if ownsToolUndoGrouping {
            finishToolUndoGrouping()
        }
        drawingBeforeToolUse = EditJotViewModel.Drawing(
            value: inkCanvasCoordinator.committedDrawing,
            width: drawingWidth,
            strokePageIndices: inkCanvasCoordinator.committedStrokePageIndices
        )
        if canvasView.tool is PKInkingTool, let undoManager = canvasView.undoManager {
            undoManager.beginUndoGrouping()
            toolUndoManager = undoManager
            ownsToolUndoGrouping = true
        }
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard inkCanvasCoordinator.role(of: canvasView) != nil,
            canvasView === inkCanvasCoordinator.activeCanvas
        else { return }
        isUsingDrawingTool = false
        updateCanvasTouchRouting()
        if canvasView === self.canvasView, attemptShapeSnapIfReady() { return }
        if canvasView === self.canvasView, shapeHoldState != nil {
            hasPendingDrawingChange = true
            scheduleShapeCommitWatchdog()
            return
        }
        flushPendingDrawingChange()
        if ownsToolUndoGrouping {
            toolUndoCleanupTask?.cancel()
            toolUndoCleanupTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                if inkCanvasCoordinator.hasUncommittedChanges {
                    commitCanvasDrawing()
                } else {
                    finishToolUndoGrouping()
                }
            }
        }
    }

    private func flushPendingDrawingChange() {
        guard hasPendingDrawingChange || inkCanvasCoordinator.hasUncommittedChanges else { return }
        commitCanvasDrawing()
    }
}

// MARK: - JotCanvasView

/// Wins only against PencilKit's transient single-tap recognizers. Continuous
/// drawing, lasso, scroll, and zoom gestures retain priority and can make this
/// recognizer fail as soon as a touch starts moving.
@MainActor
private final class CanvasEditMenuBlockingTapGestureRecognizer: UITapGestureRecognizer {

    var canvasRootViews: [UIView] = []
    var pencilKitDrawingGestureRecognizers: [UIGestureRecognizer] = []

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        if isContinuousGesture(preventedGestureRecognizer) {
            return false
        }
        if isSingleTap(preventedGestureRecognizer)
            && belongsToCanvasHierarchy(preventedGestureRecognizer)
        {
            return true
        }
        return super.canPrevent(preventedGestureRecognizer)
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        if isContinuousGesture(preventingGestureRecognizer) {
            return true
        }
        if isSingleTap(preventingGestureRecognizer)
            && belongsToCanvasHierarchy(preventingGestureRecognizer)
        {
            return false
        }
        return super.canBePrevented(by: preventingGestureRecognizer)
    }

    override func shouldBeRequiredToFail(
        by otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        super.shouldBeRequiredToFail(by: otherGestureRecognizer)
            || (isSingleTap(otherGestureRecognizer)
                && belongsToCanvasHierarchy(otherGestureRecognizer))
    }

    private func isContinuousGesture(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        CanvasEditMenuGestureArbitration.isContinuous(
            gestureRecognizer,
            drawingGestureRecognizers: pencilKitDrawingGestureRecognizers
        )
    }

    private func isSingleTap(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let tapGesture = gestureRecognizer as? UITapGestureRecognizer else { return false }
        return tapGesture.numberOfTapsRequired == 1
            && tapGesture.numberOfTouchesRequired == 1
    }

    private func belongsToCanvasHierarchy(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        CanvasEditMenuGestureArbitration.belongsToCanvasHierarchy(
            gestureRecognizer,
            roots: canvasRootViews
        )
    }
}

@MainActor
private enum CanvasEditMenuGestureArbitration {

    static func isContinuous(
        _ gestureRecognizer: UIGestureRecognizer,
        drawingGestureRecognizers: [UIGestureRecognizer]
    ) -> Bool {
        drawingGestureRecognizers.contains { $0 === gestureRecognizer }
            || gestureRecognizer is UIPanGestureRecognizer
            || gestureRecognizer is UIPinchGestureRecognizer
    }

    static func belongsToCanvasHierarchy(
        _ gestureRecognizer: UIGestureRecognizer,
        roots: [UIView]
    ) -> Bool {
        guard let gestureView = gestureRecognizer.view else { return false }
        return roots.contains { rootView in
            gestureView === rootView || gestureView.isDescendant(of: rootView)
        }
    }
}

private final class JotCanvasView: PKCanvasView {
    // Keep PencilKit's selection interaction lifecycle intact. In particular,
    // do not remove the transient interactions installed by the lasso tool.
}

@MainActor
private final class DocumentScrollViewDelegate: NSObject, UIScrollViewDelegate {

    private weak var viewController: EditJotViewController?

    init(viewController: EditJotViewController) {
        self.viewController = viewController
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        viewController?.documentViewForZooming()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        viewController?.documentScrollViewDidScroll(scrollView)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        viewController?.documentScrollViewDidZoom(scrollView)
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        viewController?.documentScrollViewWillBeginZooming()
    }

    func scrollViewDidEndZooming(
        _ scrollView: UIScrollView,
        with view: UIView?,
        atScale scale: CGFloat
    ) {
        viewController?.documentScrollViewDidEndZooming()
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        viewController?.documentScrollViewWillEndDragging(
            targetContentOffset: targetContentOffset.pointee
        )
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            viewController?.documentScrollViewDidFinishDecelerating()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        viewController?.documentScrollViewDidFinishDecelerating()
    }
}
