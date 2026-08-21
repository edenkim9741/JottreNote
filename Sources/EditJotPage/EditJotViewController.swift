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

@preconcurrency import PencilKit
import PDFKit
import UIKit

final class EditJotViewController: UIViewController {

    private enum Constants {

        enum CanvasView {
            static let maximumZoomScale = CGFloat(8)
            static let bottomFreespace = CGFloat(500)
            /// Viewport-only breathing room above the first page. This is a
            /// scroll inset, so it never changes document or export coordinates.
            static let topWritingFreespace = CGFloat(64)
            static let shapeHoldDuration = Duration.milliseconds(500)
            static let shapeHoldMovementTolerance = CGFloat(5)
        }

        enum Page {
            static let width = CGFloat(1200)
            static let height = CGFloat(1600)
        }
    }

    private enum DrawingLayer {
        case highlighter
        case foreground
    }

    private struct ShapeHoldState {
        let canvasView: PKCanvasView
        let initialStrokeCount: Int
        var lastLocation: CGPoint
        var generation = UUID()
        var didHold = false
    }

    #if !targetEnvironment(macCatalyst)
    private lazy var toolPicker = PKToolPicker()
    #endif

    private lazy var canvasView: PKCanvasView = {
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

    private lazy var highlighterCanvasView: PKCanvasView = {
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

    private lazy var documentScrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.delegate = documentScrollDelegate
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

    /// Renders only the PDF's authored content, without the app-provided white
    /// paper fill. It sits above marker ink so PDF text remains crisp and above
    /// highlighting, while normal ink remains the topmost document layer.
    private let pdfContentView: JotBackgroundView = {
        let view = JotBackgroundView(layerRole: .pdfContent)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }()

    /// Carries the inverse of PencilKit's native zoom. Keeping that transform
    /// off `PKCanvasView` itself is important: PencilKit swaps from its static
    /// tiled renderer to a live renderer on pen-down, and the live renderer can
    /// compute an empty visible region when the canvas itself is transformed.
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
    private var nativeInkZoomScale = CGFloat(1)
    private var nativeInkZoomTask: Task<Void, Never>?
    private var applicationBackgroundFlushTask: Task<Void, Never>?
    private var applicationBackgroundTaskIdentifier = UIBackgroundTaskIdentifier.invalid
    private var applicationBackgroundTaskGeneration: UUID?
    private var isApplyingViewModelDrawing = false
    private var isEditingEnabled = false
    private var activeDrawingLayer = DrawingLayer.foreground
    private var highlighterStrokePageIndices: [Int] = []
    private var foregroundStrokePageIndices: [Int] = []
    private var shapeHoldState: ShapeHoldState?
    private var shapeHoldTask: Task<Void, Never>?
    private var shapeHoldCleanupTask: Task<Void, Never>?

    private let pdfLoadService = PDFLoadService()
    private var cachedPDFData: Data?
    private var cachedPDFLoadResult: PDFLoadService.Result?

    #if !targetEnvironment(macCatalyst)
    private var didSelectInitialPenTool = false
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
        nativeInkZoomTask?.cancel()
        shapeHoldTask?.cancel()
        shapeHoldCleanupTask?.cancel()
        isEditingTask?.cancel()
        drawingTask?.cancel()
        scribbleEraseTask?.cancel()
        backButtonTask?.cancel()
        backgroundTask?.cancel()
        loadingProgressTask?.cancel()
        #if !targetEnvironment(macCatalyst)
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
        viewModel.didLoad()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        (navigationController?.navigationBar as? JottreNavigationBar)?
            .passesThroughBackgroundTouches = true
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
        toolPicker.setVisible(true, forFirstResponder: canvasView)
        #endif
        view.addSubview(loadingProgressView)
        NSLayoutConstraint.activate([
            loadingProgressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            loadingProgressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingProgressView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
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
            toolPicker.selectedTool = pen
            didSelectInitialPenTool = true
        }
        #endif
    }

    @objc
    private func handleSwipeBack(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        viewModel.didTapBackButton()
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
        if viewportSizeChanged || pageSizeChanged {
            updateNativeInkGeometry(scale: documentScrollView.zoomScale)
        }
    }

    private func updateCanvasGeometry() {
        guard !isUpdatingCanvasGeometry, drawingWidth > 0 else { return }
        isUpdatingCanvasGeometry = true
        defer { isUpdatingCanvasGeometry = false }

        let drawingMaxY: CGFloat
        if canvasView.drawing.bounds.isNull {
            drawingMaxY = backgroundContentHeight + Constants.CanvasView.bottomFreespace
        } else {
            let contentMaxY = max(canvasView.drawing.bounds.maxY, backgroundContentHeight)
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
        if documentGeometryChanged {
            updateNativeInkGeometry(scale: nativeInkZoomScale)
        }
        CATransaction.commit()
        let scrollContentSize = documentContainerView.frame.size
        if documentScrollView.contentSize != scrollContentSize {
            documentScrollView.contentSize = scrollContentSize
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
        let wasAtTop = documentScrollView.contentOffset.y
            <= -previousInsets.top + 0.5
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
        if horizontalInset > 0, abs(documentScrollView.contentOffset.x + horizontalInset) > 0.5 {
            documentScrollView.contentOffset.x = -horizontalInset
        }
        backgroundView.sync(
            scrollOffset: documentScrollView.contentOffset,
            zoomScale: scale,
            viewportSize: documentScrollView.bounds.size
        )
    }

    private func setUpCanvasView() {
        if #available(iOS 26.0, *) {
            // iOS 26 adds a white scroll-edge fade automatically for content
            // underneath navigation controls. It obscures both the PDF and ink.
            documentScrollView.topEdgeEffect.isHidden = true
            canvasView.topEdgeEffect.isHidden = true
        }
        view.addSubview(documentScrollView)
        NSLayoutConstraint.activate([
            documentScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            documentScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            documentScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            documentScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        documentScrollView.addSubview(documentContainerView)
        documentContainerView.addSubview(backgroundView)
        documentContainerView.addSubview(inkContainerView)
        inkContainerView.addSubview(canvasView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        canvasView.addGestureRecognizer(doubleTap)
        view.bringSubviewToFront(loadingProgressView)
    }

    private func applyViewModelDrawing(_ drawing: PKDrawing) {
        isApplyingViewModelDrawing = true
        canvasView.drawing = drawing
        isApplyingViewModelDrawing = false
    }

    @objc
    private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let scales = pageZoomScales() else { return }

        // `fillShortEdge` fills either the viewport width or height, whichever
        // requires more magnification. `fitLongEdge` keeps the entire page visible.
        let isAtOrBeyondShortEdgeFill = documentScrollView.zoomScale
            >= scales.fillShortEdge * (1 - 0.02)
        let targetScale = isAtOrBeyondShortEdgeFill
            ? scales.fitLongEdge
            : scales.fillShortEdge

        documentScrollView.setZoomScale(targetScale, animated: true)
        scheduleNativeInkZoomUpdate()
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

    /// Lets PencilKit render its own vector-backed drawing at the settled document
    /// scale. The inverse view transform cancels that internal zoom geometrically,
    /// so the outer scroll view remains the only visible zoom/bounce transform.
    private func updateNativeInkGeometry(scale: CGFloat) {
        guard
            scale.isFinite,
            scale > 0,
            documentContentSize.width > 0,
            documentContentSize.height > 0
        else { return }

        // PencilKit's live renderer is unreliable below its native 1x scale.
        // The outer document scroll view already performs visual reduction, so
        // keeping PencilKit at 1x or above costs no geometric accuracy and also
        // retains full vector sharpness.
        let nativeScale = max(1, scale)
        nativeInkZoomScale = nativeScale
        let scaledContentSize = CGSize(
            width: documentContentSize.width * nativeScale,
            height: documentContentSize.height * nativeScale
        )
        let geometryMatches = canvasView.contentSize == scaledContentSize
            && abs(canvasView.zoomScale - nativeScale) < 0.0001
            && canvasView.transform == .identity
            && abs(inkContainerView.transform.a - 1 / nativeScale) < 0.0001
        if !geometryMatches {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            inkContainerView.transform = .identity
            canvasView.transform = .identity
            canvasView.minimumZoomScale = nativeScale
            canvasView.maximumZoomScale = nativeScale
            canvasView.zoomScale = nativeScale
            canvasView.contentSize = scaledContentSize
            inkContainerView.transform = CGAffineTransform(
                scaleX: 1 / nativeScale,
                y: 1 / nativeScale
            )
            CATransaction.commit()
        }
        updateVisibleInkRegion()
    }

    /// Keeps the actual PKCanvasView viewport close to the screen size while its
    /// `contentSize` represents the full (possibly very long) document. PencilKit
    /// then creates live ink tiles only for the visible area on pen-down instead
    /// of trying to transition a 78-page view at once.
    private func updateVisibleInkRegion() {
        guard
            canvasView.superview != nil,
            nativeInkZoomScale.isFinite,
            nativeInkZoomScale > 0,
            documentScrollView.zoomScale.isFinite,
            documentScrollView.zoomScale > 0,
            documentScrollView.bounds.width > 0,
            documentScrollView.bounds.height > 0,
            documentContentSize.width > 0,
            documentContentSize.height > 0
        else { return }

        let documentZoom = documentScrollView.zoomScale
        // `contentOffset` already describes the viewport in the zoomed content's
        // coordinate space. `contentInset` only creates screen-space breathing
        // room before the first page; adding it here would move the ink viewport
        // down/right while the PDF remains rooted at the real content offset.
        let visibleOrigin = CGPoint(
            x: max(
                0,
                documentScrollView.contentOffset.x / documentZoom
            ),
            y: max(
                0,
                documentScrollView.contentOffset.y / documentZoom
            )
        )
        let requestedRect = CGRect(
            origin: visibleOrigin,
            size: CGSize(
                width: documentScrollView.bounds.width / documentZoom,
                height: documentScrollView.bounds.height / documentZoom
            )
        )
        let documentBounds = CGRect(origin: .zero, size: documentContentSize)
        let visibleRect = requestedRect.intersection(documentBounds)
        guard !visibleRect.isNull, visibleRect.width > 0, visibleRect.height > 0 else { return }

        let nativeScale = nativeInkZoomScale
        let nativeViewportSize = CGSize(
            width: visibleRect.width * nativeScale,
            height: visibleRect.height * nativeScale
        )
        let nativeContentOffset = CGPoint(
            x: visibleRect.minX * nativeScale,
            y: visibleRect.minY * nativeScale
        )
        let wrapperBounds = CGRect(origin: .zero, size: nativeViewportSize)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkContainerView.transform = .identity
        inkContainerView.bounds = wrapperBounds
        inkContainerView.layer.position = visibleRect.origin
        canvasView.transform = .identity
        canvasView.bounds.size = nativeViewportSize
        canvasView.layer.position = .zero
        if canvasView.contentOffset != nativeContentOffset {
            canvasView.contentOffset = nativeContentOffset
        }
        inkContainerView.transform = CGAffineTransform(
            scaleX: 1 / nativeScale,
            y: 1 / nativeScale
        )
        CATransaction.commit()
    }

    private func scheduleNativeInkZoomUpdate() {
        nativeInkZoomTask?.cancel()
        nativeInkZoomTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            updateNativeInkGeometry(scale: documentScrollView.zoomScale)
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
        updateVisibleInkRegion()
    }

    fileprivate func documentScrollViewWillBeginZooming() {
        nativeInkZoomTask?.cancel()
    }

    fileprivate func documentScrollViewDidEndZooming(at scale: CGFloat) {
        updateNativeInkGeometry(scale: scale)
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
        let pageFullHeight = (currentPageSize.height + JotBackgroundView.pageSpacing)
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
        let pageFullHeight = (currentPageSize.height + JotBackgroundView.pageSpacing)
            * documentScrollView.zoomScale
        let targetOffsetY = CGFloat(page) * pageFullHeight - documentScrollView.contentInset.top
        documentScrollView.contentOffset = CGPoint(
            x: -documentScrollView.contentInset.left,
            y: min(targetOffsetY, maxOffsetY)
        )
    }

}

// MARK: - Navigation

private extension EditJotViewController {

    func handleEditing(isEditing: Bool?) {
        let rightNavigationBarButtonItems = makeRightNavigationBarButtonItems(isEditing: isEditing)

        if let isEditing, isEditing {
            canvasView.becomeFirstResponder()
            swipeBackGesture.isEnabled = false

            #if !targetEnvironment(macCatalyst)
            if !didSelectInitialPenTool {
                didSelectInitialPenTool = true
                if !(canvasView.tool is PKInkingTool) {
                    let pen = PKInkingTool(.pen, color: .label, width: 5)
                    canvasView.tool = pen
                    toolPicker.selectedTool = pen
                }
            }
            #endif

            if #available(iOS 18.0, *) {
                canvasView.isDrawingEnabled = true
            } else {
                canvasView.isUserInteractionEnabled = true
            }
        } else {
            canvasView.resignFirstResponder()
            swipeBackGesture.isEnabled = true
            if #available(iOS 18.0, *) {
                canvasView.isDrawingEnabled = false
            } else {
                canvasView.isUserInteractionEnabled = false
            }
            #if !targetEnvironment(macCatalyst)
            if let inking = canvasView.tool as? PKInkingTool {
                let widthKey = DefaultsKey<Double>("editor.penWidth")
                let colorKey = DefaultsKey<String>("editor.penColorHex")
                defaultsService.set(widthKey, value: Double(inking.width))
                defaultsService.set(colorKey, value: inking.color.hexString)
            }
            #endif
        }

        if let firstItem = rightNavigationBarButtonItems.first, rightNavigationBarButtonItems.count == 1 {
            navigationItem.setRightBarButton(firstItem, animated: false)
        } else {
            navigationItem.setRightBarButtonItems(rightNavigationBarButtonItems, animated: false)
        }
    }

    func makeRightNavigationBarButtonItems(isEditing: Bool?) -> [UIBarButtonItem] {
        var barButtonItems = [UIBarButtonItem]()

        weak var moreBarButtonItemRef: UIBarButtonItem?
        let moreBarButtonItem = symbolBarButtonItemFactory.make(
            symbolName: "ellipsis",
            primaryAction: .menu(
                .make(
                    jotMenuConfigurations: {
                        self.viewModel.visiblePageProvider = { [weak self] in
                            guard let self else { return nil }
                            let offsetY = self.documentScrollView.contentOffset.y
                                + self.documentScrollView.contentInset.top
                            let pageFullHeight = (self.currentPageSize.height + JotBackgroundView.pageSpacing)
                                * self.documentScrollView.zoomScale
                            let index = Int(floor(max(0, offsetY) / pageFullHeight))
                            return index
                        }
                        return viewModel.menuConfigurations.make(popoverAnchorProvider: {
                            guard let barButtonItem = moreBarButtonItemRef else { return nil }
                            return { $0.barButtonItem = barButtonItem }
                        })
                    }()
                )
            )
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

private extension EditJotViewController {

    func applyBackground(_ background: EditJotViewModel.Background) async {
        let pageSize = CGSize(width: Constants.Page.width, height: Constants.Page.height)
        currentPageSize = pageSize
        let spacing = JotBackgroundView.pageSpacing

        switch background {
        case let .ruled(extraPages):
            cachedPDFData = nil
            cachedPDFLoadResult = nil
            applyDocumentAppearance(isPDFBacked: false)
            let totalPageCount = 1 + extraPages
            backgroundContentHeight = CGFloat(totalPageCount) * pageSize.height
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
                backgroundContentHeight = totalPages * pdfPageSize.height
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
    func applyDocumentAppearance(isPDFBacked: Bool) {
        let canvasStyle: UIUserInterfaceStyle = isPDFBacked ? .light : .unspecified
        canvasView.overrideUserInterfaceStyle = canvasStyle
        backgroundView.overrideUserInterfaceStyle = canvasStyle
        #if !targetEnvironment(macCatalyst)
        toolPicker.colorUserInterfaceStyle = canvasStyle
        #endif
    }
}

// MARK: - UIColor hex

private extension UIColor {

    convenience init?(hex: String) {
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
            let alpha = CGFloat((value & 0xFF000000) >> 24) / 255.0
            let red = CGFloat((value & 0x00FF0000) >> 16) / 255.0
            let green = CGFloat((value & 0x0000FF00) >> 8) / 255.0
            let blue = CGFloat(value & 0x000000FF) / 255.0
            self.init(red: red, green: green, blue: blue, alpha: alpha)
        }
    }

    var hexString: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let redByte = UInt8(round(red * 255))
        let greenByte = UInt8(round(green * 255))
        let blueByte = UInt8(round(blue * 255))
        if alpha >= 1.0 {
            return String(format: "%02X%02X%02X", redByte, greenByte, blueByte)
        } else {
            let alphaByte = UInt8(round(alpha * 255))
            return String(format: "%02X%02X%02X%02X", alphaByte, redByte, greenByte, blueByte)
        }
    }
}

// MARK: - PKCanvasViewDelegate

extension EditJotViewController: PKCanvasViewDelegate {

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isApplyingViewModelDrawing else { return }
        guard !isUsingDrawingTool else {
            hasPendingDrawingChange = true
            return
        }
        viewModel.didChangeDrawing(canvasView.drawing)
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        isUsingDrawingTool = true
        nativeInkZoomTask?.cancel()
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        isUsingDrawingTool = false
        flushPendingDrawingChange()
        view.setNeedsLayout()
    }

    private func flushPendingDrawingChange() {
        guard hasPendingDrawingChange else { return }
        hasPendingDrawingChange = false
        viewModel.didChangeDrawing(canvasView.drawing)
    }
}

// MARK: - JotCanvasView

private final class JotCanvasView: PKCanvasView {
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }
    override func buildMenu(with builder: UIMenuBuilder) { }

    override func addInteraction(_ interaction: UIInteraction) {
        guard !isSuppressedInteraction(interaction) else { return }
        super.addInteraction(interaction)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        subviews.forEach { sub in
            sub.interactions.filter { isSuppressedInteraction($0) }.forEach { sub.removeInteraction($0) }
        }
    }

    private func isSuppressedInteraction(_ interaction: UIInteraction) -> Bool {
        if interaction is UITextInteraction { return true }
        if interaction is UIContextMenuInteraction { return true }
        if #available(iOS 16.0, *), interaction is UIEditMenuInteraction { return true }
        return false
    }
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

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        viewController?.documentScrollViewDidEndZooming(at: scale)
    }
}
