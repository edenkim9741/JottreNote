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
import SwiftUI
import UIKit

extension DefaultsKey where T == Bool {
    fileprivate static let drawAndHoldShapeConversionEnabled: DefaultsKey =
        "editor.drawAndHoldShapeConversionEnabled"
}

#if !targetEnvironment(macCatalyst)
/// A stable responder for PencilKit's picker that is not recycled with PDF pages.
private final class PersistentToolPickerAnchorView: UIView {
    var preservesFirstResponder = false

    override var canBecomeFirstResponder: Bool { true }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }

    override func resignFirstResponder() -> Bool {
        guard preservesFirstResponder else { return super.resignFirstResponder() }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.preservesFirstResponder, !self.isFirstResponder else { return }
            _ = self.becomeFirstResponder()
        }
        return false
    }
}
#endif

@MainActor
final class EditJotViewController: UIViewController, @preconcurrency PDFPageOverlayViewProvider, PDFViewDelegate {

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
    private lazy var pencilInteraction = UIPencilInteraction(delegate: self)
    private let persistentCanvasAnchor = PersistentToolPickerAnchorView(frame: .zero)
    private var lastSelectedNonEraserTool: (any PKTool)?
    private var previousSelectedTool: (any PKTool)?
    private var isToolPickerObserverAttached = false
    private var isRestoringToolPicker = false
    private var originalPDFLongPressStates: [ObjectIdentifier: Bool] = [:]
    #endif

    private let pdfView: PDFView = {
        let view = PDFView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = .adaptiveBlackWhite
        view.usePageViewController(false, withViewOptions: nil)
        view.autoScales = true
        return view
    }()
    private var pageCanvases: [Int: JotCanvasView] = [:]
    private var pageIndexByCanvas: [ObjectIdentifier: Int] = [:]
    /// PDFKit asks for overlays as pages enter and leave the viewport. Keep a
    /// small pool so fast scrolling does not repeatedly allocate PencilKit's
    /// relatively expensive canvas/recognizer stack.
    private var reusablePageCanvases: [JotCanvasView] = []
    private var isApplyingOverlayDrawing = false
    private var activePDFDocument: PDFDocument?

    /// Non-visible PencilKit storage plane retained by the undo/layer coordinator.
    /// User input and rendering live only in the per-page PDFView overlays.
    private lazy var canvasView: JotCanvasView = {
        let canvasView = JotCanvasView()
        canvasView.delegate = self
        canvasView.drawingPolicy = .default
        canvasView.bounces = false
        canvasView.bouncesZoom = true
        canvasView.contentInsetAdjustmentBehavior = .never
        canvasView.automaticallyAdjustsScrollIndicatorInsets = false
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.layer.shouldRasterize = false
        return canvasView
    }()

    /// Non-visible marker ordering plane used only by the canonical drawing
    /// coordinator. Visible strokes are rendered by the page-local overlays.
    private lazy var highlighterCanvasView: JotCanvasView = {
        let canvasView = JotCanvasView()
        canvasView.delegate = self
        canvasView.isUserInteractionEnabled = false
        canvasView.isScrollEnabled = false
        canvasView.drawingPolicy = .default
        canvasView.bounces = false
        canvasView.contentInsetAdjustmentBehavior = .never
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.layer.shouldRasterize = false
        return canvasView
    }()

    private lazy var inkCanvasCoordinator = JotInkCanvasCoordinator(
        highlighterCanvas: highlighterCanvasView,
        foregroundCanvas: canvasView
    )

    /// The foreground canvas is the document's scroll and zoom owner. Keeping
    /// the old name as an alias lets the geometry code below stay expressed in
    /// document terms.
    private var documentScrollView: JotCanvasView { canvasView }

    private let backgroundView: JotBackgroundView = {
        let view = JotBackgroundView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }()

    /// Mirrors the canvas's zoom and content offset so the PDF stays locked to
    /// the ink. PencilKit only transforms its own internal content view, so a
    /// background nested inside the canvas would not follow the zoom at all.
    private let backgroundContainerView: UIView = {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
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
    /// Last unscaled size written to the canvas's `contentSize`.
    private var appliedCanvasContentSize = CGSize.zero
    private var isZoomInteractionActive = false
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
                if pendingScrollPage == nil { pendingScrollPage = defaultsService.getValue(lastPageKey) }
            }
        }
        scribbleEraseTask = Task { @MainActor [weak self] in
            for await event in viewModel.scribbleEraseEvent {
                guard let self else { return }
                let beforeDrawing = event.beforeDrawing
                let afterDrawing = event.result.value
                drawingWidth = event.result.width
                if pendingScrollPage == nil { pendingScrollPage = defaultsService.getValue(lastPageKey) }
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
            if isViewLoaded, isToolPickerObserverAttached {
                toolPicker.removeObserver(self)
            }
        }
        #endif
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (self: EditJotViewController, _: UITraitCollection) in
            self.backgroundView.sync(
                scrollOffset: self.documentScrollView.contentOffset,
                zoomScale: self.documentScrollView.zoomScale,
                viewportSize: self.documentScrollView.bounds.size
            )
        }
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pdfPageChanged),
            name: Notification.Name.PDFViewPageChanged,
            object: pdfView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pdfScaleDidChange),
            name: Notification.Name.PDFViewScaleChanged,
            object: pdfView
        )
        viewModel.didLoad()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if !targetEnvironment(macCatalyst)
        if !isToolPickerObserverAttached {
            toolPicker.addObserver(self)
            isToolPickerObserverAttached = true
        }
        persistentCanvasAnchor.preservesFirstResponder = isEditingEnabled
        guard persistentCanvasAnchor.becomeFirstResponder() else { return }
        toolPicker.setVisible(true, forFirstResponder: persistentCanvasAnchor)
        #endif
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
        Task { @MainActor [viewModel] in await viewModel.didDisappear() }
        #if !targetEnvironment(macCatalyst)
        persistentCanvasAnchor.preservesFirstResponder = false
        if isToolPickerObserverAttached {
            toolPicker.removeObserver(self)
            isToolPickerObserverAttached = false
        }
        toolPicker.setVisible(false, forFirstResponder: persistentCanvasAnchor)
        _ = persistentCanvasAnchor.resignFirstResponder()
        #endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if pdfView.document == nil { layoutCanvasContent() }
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
        pdfView.pageOverlayViewProvider = self
        pdfView.delegate = self
        view.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        #if !targetEnvironment(macCatalyst)
        view.addInteraction(pencilInteraction)
        persistentCanvasAnchor.translatesAutoresizingMaskIntoConstraints = false
        persistentCanvasAnchor.alpha = 0.01
        persistentCanvasAnchor.backgroundColor = .clear
        persistentCanvasAnchor.isAccessibilityElement = false
        persistentCanvasAnchor.accessibilityElementsHidden = true
        view.addSubview(persistentCanvasAnchor)
        NSLayoutConstraint.activate([
            persistentCanvasAnchor.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            persistentCanvasAnchor.topAnchor.constraint(equalTo: view.topAnchor),
            persistentCanvasAnchor.widthAnchor.constraint(equalToConstant: 1),
            persistentCanvasAnchor.heightAnchor.constraint(equalToConstant: 1),
        ])
        #endif
        view.addSubview(loadingProgressView)
        NSLayoutConstraint.activate([
            loadingProgressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            loadingProgressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingProgressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    func pdfView(_ pdfView: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let document = pdfView.document else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return nil }
        if let canvas = pageCanvases[pageIndex],
           pageIndexByCanvas[ObjectIdentifier(canvas)] == pageIndex {
            return canvas
        }

        let canvas = reusablePageCanvases.popLast() ?? JotCanvasView(frame: .zero)
        canvas.delegate = self
        canvas.backgroundColor = pencilDiagnosticBackgroundColor
        canvas.isOpaque = false
        canvas.clipsToBounds = true
        canvas.overrideUserInterfaceStyle = canvasView.overrideUserInterfaceStyle
        canvas.isScrollEnabled = false
        canvas.bounces = false
        canvas.contentInset = .zero
        canvas.tool = canvasView.tool
        if #available(iOS 18.0, *) {
            canvas.isDrawingEnabled = isEditingEnabled
        } else {
            canvas.drawingGestureRecognizer.isEnabled = isEditingEnabled
        }
        #if !targetEnvironment(macCatalyst)
        canvas.isRulerActive = toolPicker.isRulerActive
        #endif
        pageCanvases[pageIndex] = canvas
        pageIndexByCanvas[ObjectIdentifier(canvas)] = pageIndex
        configurePencilInput(on: canvas)
        #if !targetEnvironment(macCatalyst)
        canvas.tool = selectedToolFromPicker()
        #endif
        updateCanvasContentScaleFactor(for: canvas)
        logCanvasDiagnostic(canvas, stage: "created", pageIndex: pageIndex)
        return canvas
    }

    func pdfView(
        _ pdfView: PDFView,
        willDisplayOverlayView overlayView: UIView,
        for page: PDFPage
    ) {
        guard let canvas = overlayView as? JotCanvasView,
              let document = pdfView.document else { return }
        let pageIndex = document.index(for: page)
        canvas.backgroundColor = pencilDiagnosticBackgroundColor
        pageIndexByCanvas[ObjectIdentifier(canvas)] = pageIndex
        isApplyingOverlayDrawing = true
        canvas.drawing = localDrawing(
            from: inkCanvasCoordinator.committedDrawing,
            pageIndices: inkCanvasCoordinator.committedStrokePageIndices,
            pageIndex: pageIndex,
            overlaySize: canvas.bounds.size
        )
        isApplyingOverlayDrawing = false
        canvas.tool = selectedToolFromPickerIfAvailable()
        #if !targetEnvironment(macCatalyst)
        canvas.isRulerActive = toolPicker.isRulerActive
        #endif
        updateCanvasContentScaleFactor(for: canvas)
        logCanvasDiagnostic(canvas, stage: "displayed", pageIndex: pageIndex)
    }

    func pdfView(
        _ pdfView: PDFView,
        willEndDisplayingOverlayView overlayView: UIView,
        for page: PDFPage
    ) {
        // PDFKit recycles overlay views as pages leave the viewport. Remove
        // the old page mapping so a reused canvas cannot remain registered
        // under both its former and its current page index.
        guard let canvas = overlayView as? JotCanvasView else { return }
        let identifier = ObjectIdentifier(canvas)
        if let oldPageIndex = pageIndexByCanvas.removeValue(forKey: identifier),
           pageCanvases[oldPageIndex] === canvas {
            pageCanvases.removeValue(forKey: oldPageIndex)
        }
        canvas.delegate = nil
        isApplyingOverlayDrawing = true
        canvas.drawing = PKDrawing()
        isApplyingOverlayDrawing = false
        if reusablePageCanvases.count < 4 {
            reusablePageCanvases.append(canvas)
        }
    }

    private func selectedToolFromPickerIfAvailable() -> any PKTool {
        #if !targetEnvironment(macCatalyst)
        return selectedToolFromPicker()
        #else
        return canvasView.tool
        #endif
    }

    private func canonicalDrawing(
        from localDrawing: PKDrawing,
        pageIndex: Int,
        overlaySize: CGSize
    ) -> PKDrawing {
        JotPageCanvasCoordinateAdapter.documentDrawing(
            from: localDrawing,
            pageIndex: pageIndex,
            overlaySize: overlaySize,
            normalizedPageSize: currentPageSize,
            pageSpacing: JotBackgroundView.pageSpacing
        )
    }

    private func localDrawing(
        from drawing: PKDrawing,
        pageIndices: [Int],
        pageIndex: Int,
        overlaySize: CGSize
    ) -> PKDrawing {
        JotPageCanvasCoordinateAdapter.localDrawing(
            from: drawing,
            pageIndices: pageIndices,
            pageIndex: pageIndex,
            overlaySize: overlaySize,
            normalizedPageSize: currentPageSize,
            pageSpacing: JotBackgroundView.pageSpacing
        )
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
            lastSelectedNonEraserTool = pen
            previousSelectedTool = pen
            selectToolInPicker(pen)
            didSelectInitialPenTool = true
        }
        #endif
    }

    @discardableResult
    private func updateCanvasTouchRouting() -> Bool {
        #if !targetEnvironment(macCatalyst)
        let configuration = CanvasTouchRouting.configuration(
            isEditingEnabled: isEditingEnabled,
            drawingPolicy: pageCanvases[currentPDFPageIndex ?? -1]?.drawingPolicy ?? .default,
            isToolPickerVisible: toolPicker.isVisible,
            prefersPencilOnlyDrawing: UIPencilInteraction.prefersPencilOnlyDrawing
        )
        // PencilKit rebuilds parts of its scroll and selection interaction
        // state while lasso content is moved. Reapply these idempotent
        // invariants for every new direct-touch sequence, even when the policy
        // itself did not change.
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
            pdfView.document == nil,
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
        // The zoom ceiling is expressed relative to page-fit so the reachable
        // magnification is the same regardless of viewport size or page format.
        documentScrollView.maximumZoomScale =
            pageFitScale * Constants.CanvasView.maximumZoomScale

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
        updateCanvasContentScaleFactors()
        // Pages are laid out at `currentPageSize.width`, which a PDF can define
        // differently from the stored drawing width. Sizing the document to the
        // page keeps the note centred and stops the canvas from accepting ink in
        // the empty margin beside it.
        let documentWidth = currentPageSize.width
        let scaledWidth = documentWidth * scale
        let nextDocumentContentSize = CGSize(width: documentWidth, height: drawingMaxY)
        let documentGeometryChanged = documentContentSize != nextDocumentContentSize
        documentContentSize = nextDocumentContentSize

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let documentBounds = CGRect(origin: .zero, size: documentContentSize)
        if backgroundContainerView.bounds != documentBounds {
            backgroundContainerView.bounds = documentBounds
        }
        if backgroundView.frame != documentBounds {
            backgroundView.frame = documentBounds
        }
        CATransaction.commit()

        // `contentSize` describes the content at the current zoom, so writing
        // unscaled document units while zoomed out would make the scroll view
        // infer a much wider document. That is what pushed the page off centre
        // and left a writable margin beside it. Scale the assignment, and track
        // the unscaled value separately because the getter reports zoomed size.
        let zoomedContentSize = CGSize(
            width: documentContentSize.width * scale,
            height: documentContentSize.height * scale
        )
        if documentGeometryChanged
            || appliedCanvasContentSize == .zero
            || abs(documentScrollView.contentSize.width - zoomedContentSize.width) > 0.5
            || abs(documentScrollView.contentSize.height - zoomedContentSize.height) > 0.5
        {
            appliedCanvasContentSize = documentContentSize
            documentScrollView.contentSize = zoomedContentSize
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
        syncDocumentPlanes()
    }

    @objc private func pdfScaleDidChange() {
        // PDFView can publish scale changes during a pinch. Let the system
        // transform the existing layers while the gesture is active; only
        // rerasterize PencilKit overlays once zoom settling has completed.
        updateCanvasContentScaleFactors()
    }

    private func updateCanvasContentScaleFactors() {
        guard !isZoomInteractionActive else { return }
        let targetScale = currentOverlayTargetScale
        guard targetScale.isFinite, targetScale > 0 else { return }
        for canvas in pageCanvases.values where abs(canvas.contentScaleFactor - targetScale) > 0.01 {
            canvas.contentScaleFactor = targetScale
            canvas.layer.contentsScale = targetScale
        }
    }

    private func updateCanvasContentScaleFactor(for canvas: PKCanvasView) {
        let targetScale = currentOverlayTargetScale
        guard targetScale.isFinite, targetScale > 0,
              abs(canvas.contentScaleFactor - targetScale) > 0.01 else { return }
        canvas.contentScaleFactor = targetScale
        canvas.layer.contentsScale = targetScale
    }

    private var currentOverlayTargetScale: CGFloat {
        let screenScale = view.window?.screen.nativeScale ?? UIScreen.main.scale
        return screenScale * pdfView.scaleFactor
    }

    private func applyViewModelDrawing(_ drawing: EditJotViewModel.Drawing) {
        inkCanvasCoordinator.load(
            drawing: drawing.value,
            strokePageIndices: drawing.strokePageIndices
        )
        isApplyingOverlayDrawing = true
        for (pageIndex, canvas) in pageCanvases {
            canvas.drawing = localDrawing(
                from: drawing.value,
                pageIndices: drawing.strokePageIndices,
                pageIndex: pageIndex,
                overlaySize: canvas.bounds.size
            )
        }
        isApplyingOverlayDrawing = false
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
        // Scribble-erase is a pen behaviour, so suppress it while the marker is
        // selected. The canvas mode no longer distinguishes the two.
        let isMarkerSelected = (canvasView.tool as? PKInkingTool)?.inkType == .marker
        viewModel.didChangeDrawing(
            combined,
            strokePageIndices: inkCanvasCoordinator.committedStrokePageIndices,
            detectsScribbleErase: detectsScribbleErase && !isMarkerSelected,
            changedPageIndices: [currentPDFPageIndex ?? 0]
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
            // All tools share one canvas now, so the selected tool, rather than
            // a canvas mode, decides whether a hold may snap to a shape.
            guard isDrawAndHoldShapeConversionEnabled,
                isEditingEnabled,
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
        toolUndoManager
            ?? currentPDFPageIndex.flatMap { pageCanvases[$0]?.undoManager }
            ?? inkCanvasCoordinator.activeCanvas.undoManager
            ?? canvasView.undoManager
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

    /// Projects the canvas's zoom onto the background plane.
    ///
    /// PencilKit applies the zoom as a transform on its own internal content
    /// view, so a view the app adds has to be scaled explicitly. Doing it with a
    /// layer transform keeps the PDF page re-render and the ink perfectly
    /// registered without re-laying out the page views on every frame.
    private func syncDocumentPlanes() {
        guard documentContentSize.width > 0, documentContentSize.height > 0 else { return }

        let scale = canvasView.zoomScale
        let offset = canvasView.contentOffset

        // No CATransaction override here. During an animated zoom PencilKit
        // animates its own content, so the background has to inherit the very
        // same animation to stay visually locked to the ink. Suppressing actions
        // would make the background snap while the ink glides.
        //
        // The plane is a subview of the canvas, so it already scrolls with it
        // and only the zoom has to be reproduced. Anchoring at the layer origin
        // scales the document about its top-left corner, matching how the canvas
        // scales its own content.
        backgroundContainerView.layer.anchorPoint = .zero
        backgroundContainerView.layer.position = .zero
        backgroundContainerView.layer.transform = CATransform3DMakeScale(scale, scale, 1)

        backgroundView.sync(
            scrollOffset: offset,
            zoomScale: scale,
            viewportSize: canvasView.bounds.size
        )
    }

    private func finishZoomInteraction() {
        zoomSettleTask?.cancel()
        isZoomInteractionActive = false
        syncDocumentPlanes()
        backgroundView.setZoomInteractionActive(false)
        updateCanvasContentScaleFactors()
    }

    private func scheduleZoomSettling() {
        zoomSettleTask?.cancel()
        zoomSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            finishZoomInteraction()
        }
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
        guard let page = currentPDFPageIndex else { return }
        defaultsService.set(lastPageKey, value: page)
    }

    private var currentPDFPageIndex: Int? {
        guard let page = pdfView.currentPage,
              let document = pdfView.document else { return nil }
        let index = document.index(for: page)
        return index == NSNotFound ? nil : index
    }

    @objc private func pdfPageChanged() {
        guard let pageIndex = currentPDFPageIndex else { return }
        pendingScrollPage = pageIndex
        defaultsService.set(lastPageKey, value: pageIndex)
    }

    private func restoreScrollPositionIfNeeded() {
        guard let page = pendingScrollPage, page > 0, drawingWidth > 0 else { return }
        let zoomScale = documentScrollView.zoomScale
        let maxOffsetY = max(
            0,
            documentContentSize.height * zoomScale - documentScrollView.bounds.height
        )
        guard maxOffsetY > 0 else { return }
        pendingScrollPage = nil
        let pageFullHeight =
            (currentPageSize.height + JotBackgroundView.pageSpacing) * zoomScale
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

    func toolPickerIsRulerActiveDidChange(_ toolPicker: PKToolPicker) {
        let isActive = toolPicker.isRulerActive
        pageCanvases.values.forEach { $0.isRulerActive = isActive }
    }

    @available(iOS, introduced: 13.0, deprecated: 18.0)
    func toolPickerSelectedToolDidChange(_ toolPicker: PKToolPicker) {
        scheduleSelectedCanvasToolUpdate()
    }

    @available(iOS 18.0, *)
    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        scheduleSelectedCanvasToolUpdate()
    }

    func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) {
        updateCanvasTouchRouting()
        if isEditingEnabled && !toolPicker.isVisible {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.restorePersistentToolPickerIfNeeded()
            }
        }
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
        let previousCanvasTool = canvasView.tool
        let selectedTool = selectedToolFromPicker()
        previousSelectedTool = previousCanvasTool
        if !(selectedTool is PKEraserTool) {
            lastSelectedNonEraserTool = selectedTool
        }
        canvasView.tool = selectedTool
        highlighterCanvasView.tool = selectedTool
        pageCanvases.values.forEach { $0.tool = selectedTool }

        blankEditMenuDismissTask?.cancel()
        if !isEditingEnabled || !wasLassoTool || !(selectedTool is PKLassoTool) {
            dismissPencilKitEditMenus()
        }

        // Every tool draws on the canvas that owns scrolling. PencilKit's own
        // gesture view covers the whole viewport, and a gesture recognizer only
        // sees touches whose hit-test view is itself or a descendant, so a
        // nested sibling canvas can never receive input. Marker ordering is
        // preserved by JotDrawingLayerPartition, which always stores marker
        // strokes first, so a single canvas still composites ink correctly.
        let nextMode = JotInkCanvasCoordinator.Mode.combined

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

    private func selectedToolFromPicker() -> any PKTool {
        if #available(iOS 18.0, *) {
            let item = toolPicker.selectedToolItem
            if let item = item as? PKToolPickerInkingItem { return item.inkingTool }
            if let item = item as? PKToolPickerEraserItem { return item.eraserTool }
            if let item = item as? PKToolPickerLassoItem { return item.lassoTool }
        }
        if #unavailable(iOS 18.0) {
            return toolPicker.selectedTool
        }
        return PKInkingTool(.pen)
    }

    private func selectToolInPicker(_ tool: any PKTool) {
        if #available(iOS 18.0, *) {
            if let inkingTool = tool as? PKInkingTool {
                toolPicker.selectedToolItemIdentifier = PKToolPickerInkingItem(
                    type: inkingTool.ink.inkType
                ).identifier
            } else if let eraserTool = tool as? PKEraserTool {
                toolPicker.selectedToolItemIdentifier = PKToolPickerEraserItem(
                    type: eraserTool.eraserType
                ).identifier
            } else if tool is PKLassoTool {
                toolPicker.selectedToolItemIdentifier = PKToolPickerLassoItem().identifier
            }
        } else {
            toolPicker.selectedTool = tool
        }
    }
}

// MARK: - Apple Pencil double-tap

@available(iOS 17.5, *)
extension EditJotViewController: UIPencilInteractionDelegate {
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        guard isEditingEnabled else { return }

        switch UIPencilInteraction.preferredTapAction {
        case .switchEraser:
            let selectedTool = selectedToolFromPicker()
            if selectedTool is PKEraserTool {
                selectToolInPicker(lastSelectedNonEraserTool ?? PKInkingTool(.pen))
            } else {
                lastSelectedNonEraserTool = selectedTool
                selectToolInPicker(PKEraserTool(.bitmap))
            }
        case .switchPrevious:
            if let previousSelectedTool {
                selectToolInPicker(previousSelectedTool)
            }
        case .showColorPalette, .showInkAttributes, .showContextualPalette:
            break
        case .ignore, .runSystemShortcut:
            break
        @unknown default:
            break
        }
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
                    selectToolInPicker(pen)
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
        // PDFView owns page scrolling and zoom. PencilKit input is enabled only
        // on the page overlays, whose frames are clipped to individual pages.
        highlighterCanvasView.isUserInteractionEnabled = false
        if #available(iOS 18.0, *) {
            highlighterCanvasView.isDrawingEnabled = false
        }
        highlighterCanvasView.resignFirstResponder()

        canvasView.isUserInteractionEnabled = false
        if #available(iOS 18.0, *) {
            canvasView.isDrawingEnabled = false
        } else {
            canvasView.drawingGestureRecognizer.isEnabled = false
        }
        for canvas in pageCanvases.values {
            configurePencilInput(on: canvas)
            if #available(iOS 18.0, *) {
                canvas.isDrawingEnabled = isEditingEnabled
            } else {
                canvas.drawingGestureRecognizer.isEnabled = isEditingEnabled
            }
        }
        updatePDFLongPressGesturePolicy()
        #if !targetEnvironment(macCatalyst)
        persistentCanvasAnchor.preservesFirstResponder = isEditingEnabled
        if isEditingEnabled { restorePersistentToolPickerIfNeeded() }
        #endif
    }

    private func updatePDFLongPressGesturePolicy() {
        #if !targetEnvironment(macCatalyst)
        var recognizers: [UILongPressGestureRecognizer] = []
        collectPDFLongPressRecognizers(in: pdfView, into: &recognizers)
        if isEditingEnabled {
            for recognizer in recognizers {
                let identifier = ObjectIdentifier(recognizer)
                if originalPDFLongPressStates[identifier] == nil {
                    originalPDFLongPressStates[identifier] = recognizer.isEnabled
                }
                recognizer.isEnabled = false
            }
        } else {
            for recognizer in recognizers {
                guard let wasEnabled = originalPDFLongPressStates[ObjectIdentifier(recognizer)] else { continue }
                recognizer.isEnabled = wasEnabled
            }
            originalPDFLongPressStates.removeAll()
        }
        #endif
    }

    private func configurePencilInput(on canvas: JotCanvasView) {
        #if !targetEnvironment(macCatalyst)
        // Pencil is the editor's ink input; finger drags remain available to
        // PDFKit navigation even when the system's default Pencil policy varies.
        canvas.drawingPolicy = .pencilOnly
        #endif
        canvas.isUserInteractionEnabled = isEditingEnabled
        prioritizePencilGesture(on: canvas)
    }

    private func logCanvasDiagnostic(_ canvas: JotCanvasView, stage: String, pageIndex: Int) {
        #if DEBUG
        let recognizerStates = (canvas.gestureRecognizers ?? []).map { recognizer in
            "\(type(of: recognizer))(enabled:\(recognizer.isEnabled), state:\(recognizer.state.rawValue))"
        }.joined(separator: ", ")
        let pdfScrollViews = pdfNavigationScrollViews()
        let pdfScrollStates = pdfScrollViews.map { scrollView in
            "\(type(of: scrollView))(frame:\(scrollView.frame), scrolling:\(scrollView.isScrollEnabled), "
                + "panEnabled:\(scrollView.panGestureRecognizer.isEnabled), "
                + "panState:\(scrollView.panGestureRecognizer.state.rawValue))"
        }.joined(separator: ", ")
        let message =
            "[PencilDiag][Overlay] stage:\(stage) page:\(pageIndex) "
                + "frame:\(canvas.frame) interaction:\(canvas.isUserInteractionEnabled) "
                + "drawingPolicy:\(canvas.drawingPolicy.rawValue) "
                + "gestures[\(canvas.gestureRecognizers?.count ?? 0)]:\(recognizerStates) "
                + "pdfViewInteraction:\(pdfView.isUserInteractionEnabled) "
                + "pdfScrollViews[\(pdfScrollViews.count)]:\(pdfScrollStates) "
                + "pencilPanLinks:\(canvas.prioritizedPDFPanRecognizers.count)"
        print(message)
        NSLog("%@", message)
        #endif
    }

    private var pencilDiagnosticBackgroundColor: UIColor {
        #if DEBUG
        return UIColor.red.withAlphaComponent(0.2)
        #else
        return .clear
        #endif
    }

    private func prioritizePencilGesture(on canvas: JotCanvasView) {
        #if !targetEnvironment(macCatalyst)
        let drawingGesture = canvas.drawingGestureRecognizer
        for scrollView in pdfNavigationScrollViews() {
            let panIdentifier = ObjectIdentifier(scrollView.panGestureRecognizer)
            guard canvas.prioritizedPDFPanRecognizers.insert(panIdentifier).inserted else { continue }
            scrollView.panGestureRecognizer.require(toFail: drawingGesture)
        }
        #endif
    }

    private func pdfNavigationScrollViews() -> [UIScrollView] {
        var candidates: [UIScrollView] = []
        if let documentView = pdfView.documentView {
            var ancestor = documentView.superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView { candidates.append(scrollView) }
                ancestor = view.superview
            }
        }
        collectPDFScrollViews(in: pdfView, into: &candidates)
        var seen = Set<ObjectIdentifier>()
        return candidates.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    private func collectPDFScrollViews(in view: UIView, into result: inout [UIScrollView]) {
        // Page overlay canvases have their own PencilKit pan recognizers, which
        // are disabled for navigation and must not be treated as PDF scrollers.
        guard !(view is PKCanvasView) else { return }
        for child in view.subviews {
            if let scrollView = child as? UIScrollView, scrollView.isScrollEnabled {
                result.append(scrollView)
            }
            collectPDFScrollViews(in: child, into: &result)
        }
    }

    #if !targetEnvironment(macCatalyst)
    private func collectPDFLongPressRecognizers(
        in view: UIView,
        into recognizers: inout [UILongPressGestureRecognizer]
    ) {
        // Leave PencilKit's own long-press/shape gestures intact; only PDFKit's
        // text selection recognizers interfere with the persistent picker.
        guard !(view is PKCanvasView) else { return }
        recognizers.append(contentsOf: (view.gestureRecognizers ?? []).compactMap { $0 as? UILongPressGestureRecognizer })
        for subview in view.subviews {
            collectPDFLongPressRecognizers(in: subview, into: &recognizers)
        }
    }

    private func restorePersistentToolPickerIfNeeded() {
        guard isEditingEnabled,
              isToolPickerObserverAttached,
              persistentCanvasAnchor.window != nil,
              !isRestoringToolPicker else { return }
        isRestoringToolPicker = true
        defer { isRestoringToolPicker = false }
        if !persistentCanvasAnchor.isFirstResponder {
            _ = persistentCanvasAnchor.becomeFirstResponder()
        }
        if !toolPicker.isVisible {
            toolPicker.setVisible(true, forFirstResponder: persistentCanvasAnchor)
        }
    }
    #endif

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
            self?.currentPDFPageIndex
        }
        viewModel.onPresentPageTrash = { [weak self] in self?.presentPageTrash() }
        let menuConfigurations = viewModel.menuConfigurations.make(popoverAnchorProvider: {
            guard let barButtonItem = moreBarButtonItemRef else { return nil }
            return { $0.barButtonItem = barButtonItem }
        })
        let baseMenu = UIMenu.make(jotMenuConfigurations: menuConfigurations)
        var menuChildren = baseMenu.children
        let shapeConversionIndex = min(3, menuChildren.endIndex)
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
        barButtonItems.append(
            symbolBarButtonItemFactory.make(
                symbolName: "doc.badge.plus",
                primaryAction: .action(
                    UIAction(title: L10n.EditJot.PDF.Action.addPage) { [weak self] _ in
                        guard let self else { return }
                        viewModel.addPage(afterPageIndex: viewModel.visiblePageProvider?())
                    }
                )
            )
        )

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

    private func presentPageTrash() {
        let controller = UIHostingController(
            rootView: PageTrashSheet(pages: viewModel.trashedPages) { [weak self] id in
                self?.viewModel.restoreTrashedPage(id: id) ?? false
            }
        )
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(controller, animated: true)
    }
}

private struct PageTrashSheet: View {
    @Environment(\.dismiss) private var dismiss
    let pages: [TrashedPage]
    let onRestore: (UUID) -> Bool

    var body: some View {
        NavigationStack {
            List {
                if pages.isEmpty {
                    ContentUnavailableView(
                        String(localized: "editJot.pages.trashEmpty"),
                        systemImage: "trash"
                    )
                } else {
                    ForEach(pages.sorted { $0.deletedAt > $1.deletedAt }) { page in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(String.localizedStringWithFormat(
                                    String(localized: "editJot.pages.trashedPage"),
                                    page.originalIndex + 1
                                ))
                                Text(page.deletedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(String(localized: "editJot.pages.restore")) {
                                if onRestore(page.id) { dismiss() }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "editJot.pages.trash"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "action.done")) { dismiss() }
                }
            }
        }
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
            do {
                let data = try JotHybridPDFBuilder.makeRuledPDF(
                    pageSize: pageSize,
                    pageCount: totalPageCount
                )
                installPDFDocument(data)
            } catch {
                viewModel.logger.error("Failed to create ruled PDF for PDFView: \(error)")
            }

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
                let materialized = try HybridPDFManager.materializePages(
                    pdfData: data,
                    insertedPageSlots: insertedPageSlots,
                    blankPageCount: 0,
                    pageSize: pdfPageSize
                )
                installPDFDocument(materialized)
            } catch {
                cachedPDFData = nil
                cachedPDFLoadResult = nil
                // A malformed/empty PDF must not take down the editor. Keep the
                // handwriting available over a plain page so it can still be saved.
                backgroundContentHeight = pageSize.height
                if let fallback = try? JotHybridPDFBuilder.makeRuledPDF(pageSize: pageSize, pageCount: 1) {
                    installPDFDocument(fallback)
                }
            }
        }
        layoutCanvasContent()
    }

    private func installPDFDocument(_ data: Data) {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { return }
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            page.annotations
                .filter { $0.contents == PDFAnnotationConverter.marker }
                .forEach(page.removeAnnotation)
        }
        pageCanvases.removeAll()
        pageIndexByCanvas.removeAll()
        reusablePageCanvases.removeAll()
        activePDFDocument = document
        pdfView.document = document
        pdfView.autoScales = true
        if let page = document.page(at: pendingScrollPage ?? 0) {
            pdfView.go(to: page)
        }
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.updatePDFLongPressGesturePolicy()
        }
    }

    /// PencilKit interprets its black/white palette relative to the canvas's
    /// appearance. PDF pages always use their authored (light) appearance, so
    /// the picker must create colors for a light canvas even when its own UI is
    /// dark. Plain notes keep PencilKit's normal adaptive appearance.
    fileprivate func applyDocumentAppearance(isPDFBacked: Bool) {
        let canvasStyle: UIUserInterfaceStyle = isPDFBacked ? .light : .unspecified
        canvasView.overrideUserInterfaceStyle = canvasStyle
        highlighterCanvasView.overrideUserInterfaceStyle = canvasStyle
        pageCanvases.values.forEach { $0.overrideUserInterfaceStyle = canvasStyle }
        pageCanvases.values.forEach { $0.overrideUserInterfaceStyle = canvasStyle }
        backgroundView.overrideUserInterfaceStyle = canvasStyle
        #if !targetEnvironment(macCatalyst)
        toolPicker.colorUserInterfaceStyle = canvasStyle
        #endif
    }
}

extension UIView {

    /// PencilKit installs edit-menu interactions on internal subviews, so the
    /// editor has to walk the subtree to dismiss them.
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
        if let pageIndex = pageIndexByCanvas[ObjectIdentifier(canvasView)] {
            guard !isApplyingOverlayDrawing else { return }
            let prior = inkCanvasCoordinator.committedDrawing
            let priorIndices = inkCanvasCoordinator.committedStrokePageIndices
            var strokes: [PKStroke] = []
            var indices: [Int] = []
            for (index, stroke) in prior.strokes.enumerated() {
                let owner = priorIndices.indices.contains(index) ? priorIndices[index] : 0
                if owner != pageIndex {
                    strokes.append(stroke)
                    indices.append(owner)
                }
            }
            let converted = canonicalDrawing(
                from: canvasView.drawing,
                pageIndex: pageIndex,
                overlaySize: canvasView.bounds.size
            )
            strokes.append(contentsOf: converted.strokes)
            indices.append(contentsOf: repeatElement(pageIndex, count: converted.strokes.count))
            let combined = PKDrawing(strokes: strokes)
            inkCanvasCoordinator.load(drawing: combined, strokePageIndices: indices)
            viewModel.didChangeDrawing(
                combined,
                strokePageIndices: indices,
                changedPageIndices: [pageIndex]
            )
            return
        }
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
        if pageIndexByCanvas[ObjectIdentifier(canvasView)] != nil {
            drawingBeforeToolUse = EditJotViewModel.Drawing(
                value: inkCanvasCoordinator.committedDrawing,
                width: drawingWidth,
                strokePageIndices: inkCanvasCoordinator.committedStrokePageIndices
            )
            toolUndoManager = canvasView.undoManager
            return
        }
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
        if pageIndexByCanvas[ObjectIdentifier(canvasView)] != nil {
            drawingBeforeToolUse = nil
            toolUndoManager = nil
            return
        }
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

    // MARK: Document scrolling

    // `PKCanvasViewDelegate` refines `UIScrollViewDelegate`, so the canvas that
    // owns the document zoom reports its scrolling here directly.

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === canvasView else { return }
        syncDocumentPlanes()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard scrollView === canvasView else { return }
        updateCanvasGeometry()
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        guard scrollView === canvasView else { return }
        zoomSettleTask?.cancel()
        isZoomInteractionActive = true
        backgroundView.setZoomInteractionActive(true)
    }

    func scrollViewDidEndZooming(
        _ scrollView: UIScrollView,
        with view: UIView?,
        atScale scale: CGFloat
    ) {
        guard scrollView === canvasView else { return }
        finishZoomInteraction()
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard scrollView === canvasView else { return }
        backgroundView.prefetch(toward: targetContentOffset.pointee)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === canvasView, !decelerate else { return }
        backgroundView.finishScrollPrefetch()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === canvasView else { return }
        backgroundView.finishScrollPrefetch()
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
    fileprivate var prioritizedPDFPanRecognizers = Set<ObjectIdentifier>()

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        let containsPencilTouch = event?.allTouches?.contains { $0.type == .pencil } == true
        let target = isUserInteractionEnabled && containsPencilTouch && bounds.contains(point)
            ? self
            : result
        #if DEBUG
        let touchTypes = event?.allTouches?.map { $0.type.rawValue.description }.joined(separator: ",") ?? "none"
        let message =
            "🔍 [HitTest] Point: \(point), TouchTypes: \(touchTypes), "
                + "TargetView: \(target.map { String(describing: type(of: $0)) } ?? "nil"), "
                + "CanvasFrame: \(frame)"
        print(message)
        NSLog("%@", message)
        #endif
        return target
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        #if DEBUG
        if let touch = touches.first {
            let message =
                "✏️ [TouchBegan] Type: \(touch.type.rawValue) "
                    + "(0: direct/finger, 2: pencil), Force: \(touch.force)"
            print(message)
            NSLog("%@", message)
        }
        #endif
    }
}
