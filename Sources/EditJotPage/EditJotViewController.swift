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
final class EditJotViewController: UIViewController, @preconcurrency PDFPageOverlayViewProvider {

    #if !targetEnvironment(macCatalyst)
    private struct ToolSelection {
        let tool: any PKTool
        let itemIdentifier: String
    }

    private lazy var toolPicker = PKToolPicker()
    private lazy var pencilInteraction = UIPencilInteraction(delegate: self)
    private let persistentCanvasAnchor = PersistentToolPickerAnchorView(frame: .zero)
    private var selectedToolItemIdentifier: String?
    private var lastSelectedNonEraserTool: ToolSelection?
    private var previousSelectedTool: ToolSelection?
    private var isToolPickerObserverAttached = false
    private var isRestoringToolPicker = false
    private weak var activeLassoCanvas: JotCanvasView?
    #endif

    private let pdfView: JotPDFView = {
        let view = JotPDFView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = .adaptiveBlackWhite
        view.usePageViewController(false, withViewOptions: nil)
        view.autoScales = true
        return view
    }()
    private lazy var zoomCoordinator = JotCanvasZoomCoordinator { [weak self] in self?.updatePageOverlayRendererZoom() }
    private lazy var gestureCoordinator: JotEditorGestureCoordinator = {
        let coordinator = JotEditorGestureCoordinator(pdfView: pdfView)
        return coordinator
    }()

    private let overlayStore = JotPageOverlayStore()
    private var pageCanvases: [Int: JotCanvasView] { overlayStore.canvases }
    private var pageOverlays: [Int: JotPDFPageCanvasOverlay] { overlayStore.overlays }
    private var pageIndexByCanvas: [ObjectIdentifier: Int] { overlayStore.indices }
    private var isApplyingOverlayDrawing = false
    private var isInstallingPDFDocument = false
    private let shapeCoordinator = JotPageShapeCoordinator()
    private let inkCanvasCoordinator = JotEditorDrawingState()
    private var canvasAppearance: UIUserInterfaceStyle = .unspecified
    private var selectedCanvasTool: any PKTool = PKInkingTool(.pen)
    #if !targetEnvironment(macCatalyst)
    private var cachedRulerActive = false
    private var isApplyingPageInputState = false
    #endif
    private var drawingWidth = CGFloat.zero
    private var currentPageSize = JotPageLayout.defaultSize
    private var applicationBackgroundFlushTask: Task<Void, Never>?
    private var applicationBackgroundTaskIdentifier = UIBackgroundTaskIdentifier.invalid
    private var applicationBackgroundTaskGeneration: UUID?
    private var isEditingEnabled = false
    private var toolUndoManager: UndoManager?

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
        setUpNavigationBar()
        setUpViews()
        restorePenTool()
        shapeCoordinator.isEnabled = isDrawAndHoldShapeConversionEnabled
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
            selector: #selector(applicationWillTerminate),
            name: UIApplication.willTerminateNotification,
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
        JottreDiagnostics.shared.record("editor.opened")
        #if !targetEnvironment(macCatalyst)
        pencilInteraction.isEnabled = true
        synchronizeSelectedToolFromPicker()
        if !isToolPickerObserverAttached {
            toolPicker.addObserver(self)
            isToolPickerObserverAttached = true
        }
        cachedRulerActive = toolPicker.isRulerActive
        synchronizePageInputState()
        persistentCanvasAnchor.preservesFirstResponder = CanvasTouchRouting.usesPersistentResponder(
            isEditing: isEditingEnabled, tool: selectedToolFromPickerIfAvailable())
        guard isEditingEnabled, persistentCanvasAnchor.becomeFirstResponder() else { return }
        toolPicker.setVisible(true, forFirstResponder: persistentCanvasAnchor)
        #endif
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        (navigationController?.navigationBar as? JottreNavigationBar)?
            .passesThroughBackgroundTouches = true
        gestureCoordinator.installUndoDoubleTapGesture(
            target: self,
            action: #selector(handleTwoFingerDoubleTap(_:))
        )
        synchronizePageInputState()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        JottreDiagnostics.shared.record("editor.closed")
        zoomCoordinator.stopObservingDoubleTapZoom()
        gestureCoordinator.removeUndoDoubleTapGesture()
        (navigationController?.navigationBar as? JottreNavigationBar)?
            .passesThroughBackgroundTouches = false
        gestureCoordinator.update(
            isEditing: false,
            tool: selectedCanvasTool,
            pickerVisible: false,
            rulerActive: false,
            activePageIndex: nil,
            overlays: pageOverlays
        )
        flushPendingDrawingChange()
        saveScrollPosition()
        Task { @MainActor [viewModel] in await viewModel.didDisappear() }
        #if !targetEnvironment(macCatalyst)
        persistentCanvasAnchor.preservesFirstResponder = false
        if isToolPickerObserverAttached {
            toolPicker.removeObserver(self)
            isToolPickerObserverAttached = false
        }
        if let canvas = activeLassoCanvas {
            toolPicker.removeObserver(canvas)
            toolPicker.setVisible(false, forFirstResponder: canvas)
            _ = canvas.resignFirstResponder()
        }
        activeLassoCanvas = nil
        toolPicker.setVisible(false, forFirstResponder: persistentCanvasAnchor)
        _ = persistentCanvasAnchor.resignFirstResponder()
        #endif
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        zoomCoordinator.updateScaleRange(in: pdfView)
    }

    private func setUpViews() {
        view.backgroundColor = .adaptiveBlackWhite
        view.addGestureRecognizer(swipeBackGesture)
        pdfView.pageOverlayViewProvider = self
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
        synchronizePageInputState()
        guard let document = pdfView.document else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return nil }
        if let canvas = pageCanvases[pageIndex],
            pageIndexByCanvas[ObjectIdentifier(canvas)] == pageIndex,
            let overlay = pageOverlays[pageIndex]
        {
            gestureCoordinator.configure(canvas, overlay: overlay, pageIndex: pageIndex)
            return overlay
        }

        let pageSize = PDFAnnotationConverter.displaySize(
            for: page.bounds(for: .cropBox),
            rotation: page.rotation
        )
        let overlay =
            overlayStore.overlay(for: page)
            ?? JotPDFPageCanvasOverlay(
                canvas: JotCanvasView(frame: .zero),
                pageSize: pageSize,
                drawingWidth: currentPageSize.width
            )
        guard let canvas = overlay.canvas as? JotCanvasView else { return nil }
        gestureCoordinator.configure(canvas, overlay: overlay, pageIndex: pageIndex)
        overlay.bounds = CGRect(origin: .zero, size: pageSize)
        overlay.prepareForPage(size: pageSize, drawingWidth: currentPageSize.width)
        overlay.configure(in: pdfView, pdfScaleFactor: pdfView.scaleFactor)
        canvas.delegate = self
        shapeCoordinator.attach(canvas)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.clipsToBounds = true
        canvas.overrideUserInterfaceStyle = canvasAppearance
        canvas.isScrollEnabled = false
        canvas.bounces = false
        canvas.contentInset = .zero
        overlayStore.register(overlay, page: page, index: pageIndex)
        updatePageCanvasRenderer(for: canvas)
        synchronizePageInputState()

        return overlay
    }

    func pdfView(
        _ pdfView: PDFView,
        willDisplayOverlayView overlayView: UIView,
        for page: PDFPage
    ) {
        guard let overlay = overlayView as? JotPDFPageCanvasOverlay,
            let canvas = overlay.canvas as? JotCanvasView,
            let document = pdfView.document
        else { return }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return }
        synchronizePageInputState()
        gestureCoordinator.configure(canvas, overlay: overlay, pageIndex: pageIndex)
        canvas.backgroundColor = .clear
        canvas.delegate = self
        shapeCoordinator.attach(canvas)
        overlayStore.register(overlay, page: page, index: pageIndex)
        if overlay.bounds.width > 0, overlay.bounds.height > 0 {
            overlay.prepareForPage(size: overlay.bounds.size, drawingWidth: currentPageSize.width)
        }
        updatePageCanvasRenderer(for: canvas)
        isApplyingOverlayDrawing = true
        canvas.drawing = localDrawing(
            from: inkCanvasCoordinator.committedDrawing,
            pageIndices: inkCanvasCoordinator.committedStrokePageIndices,
            pageIndex: pageIndex,
            overlaySize: overlay.drawingSize
        )
        isApplyingOverlayDrawing = false
        #if DEBUG
        EditorInteractionFixture.publish(canvas: canvas, index: pageIndex, pdfView: pdfView, host: view)
        #endif
        updatePageCanvasRenderer(for: canvas)
        synchronizePageInputState()

        // PDFKit may finish applying the page transform immediately after
        // willDisplayOverlayView. Re-measure once the overlay has its settled
        // frame so the initial fit scale cannot remain cached on the canvas.
        Task { @MainActor [weak self, weak canvas] in
            await Task.yield()
            guard let self, let canvas,
                pageIndexByCanvas[ObjectIdentifier(canvas)] == pageIndex
            else { return }
            canvas.layoutIfNeeded()
            updatePageCanvasRenderer(for: canvas)
            #if DEBUG
            EditorInteractionFixture.publish(canvas: canvas, index: pageIndex, pdfView: pdfView, host: view)
            #endif

        }
    }

    func pdfView(
        _ pdfView: PDFView,
        willEndDisplayingOverlayView overlayView: UIView,
        for page: PDFPage
    ) {
        // PDFKit recycles overlay views as pages leave the viewport. Remove
        // the old page mapping so a reused canvas cannot remain registered
        // under both its former and its current page index.
        guard let overlay = overlayView as? JotPDFPageCanvasOverlay,
            let canvas = overlay.canvas as? JotCanvasView
        else { return }
        guard overlayStore.overlay(for: page) === overlay else { return }
        // Capture any final sample before detaching the page delegate.
        canvasViewDrawingDidChange(canvas)
        #if DEBUG
        if EditorInteractionFixture.tool != nil, let index = pageIndexByCanvas[ObjectIdentifier(canvas)] {
            view.subviews.first { $0.accessibilityIdentifier == "editor.page.\(index)" }?.removeFromSuperview()
        }
        #endif
        guard overlayStore.remove(overlay, page: page) else { return }
        if activeLassoCanvas === canvas {
            toolPicker.removeObserver(canvas)
            _ = canvas.resignFirstResponder()
            activeLassoCanvas = nil
            restorePersistentToolPickerIfNeeded()
        }
        gestureCoordinator.detach(canvas)
        shapeCoordinator.detach(canvas)
        synchronizePageInputState()
    }

    private func synchronizePageInputState() {
        zoomCoordinator.observe(gestureCoordinator.pdfNavigationScrollViews())
        // Keep PDF navigation available while the ruler is active. Ruler
        // manipulation remains PencilKit's responsibility on the active page.
        zoomCoordinator.observeDoubleTapZoom(in: pdfView)
        #if !targetEnvironment(macCatalyst)
        isApplyingPageInputState = true
        defer { isApplyingPageInputState = false }
        #endif
        gestureCoordinator.update(
            isEditing: isEditingEnabled,
            tool: selectedToolFromPickerIfAvailable(),
            pickerVisible: toolPicker.isVisible,
            rulerActive: cachedRulerActive,
            activePageIndex: currentPDFPageIndex,
            overlays: pageOverlays
        )
        #if !targetEnvironment(macCatalyst)
        // PKCanvasView.isRulerActive can notify the shared picker while the
        // coordinator deactivates the old page. Restore the picker-owned value
        // after all page-local canvas states have been applied.
        if toolPicker.isRulerActive != cachedRulerActive {
            toolPicker.isRulerActive = cachedRulerActive
        }
        #endif
        #if DEBUG
        EditorInteractionFixture.pickerRulerActive = cachedRulerActive
        if EditorInteractionFixture.tool != nil {
            for (index, canvas) in pageCanvases {
                EditorInteractionFixture.publish(canvas: canvas, index: index, pdfView: pdfView, host: view)
            }
        }
        #endif
    }

    private func selectedToolFromPickerIfAvailable() -> any PKTool {
        #if !targetEnvironment(macCatalyst)
        return selectedToolFromPicker()
        #else
        return selectedCanvasTool
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
            pageSpacing: JotPageLayout.pageSpacing
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
            pageSpacing: JotPageLayout.pageSpacing
        )
    }

    private func restorePenTool() {
        #if !targetEnvironment(macCatalyst)
        let widthKey = DefaultsKey<Double>("editor.penWidth")
        let colorKey = DefaultsKey<String>("editor.penColorHex")
        if let width = defaultsService.getValue(widthKey) {
            let color = defaultsService.getValue(colorKey).flatMap { UIColor(hex: $0) } ?? .label
            let pen = PKInkingTool(.pen, color: color, width: CGFloat(width))
            selectedCanvasTool = pen
            selectToolInPicker(pen)
            let selection = ToolSelection(
                tool: selectedToolFromPicker(),
                itemIdentifier: toolPicker.selectedToolItemIdentifier
            )
            selectedCanvasTool = selection.tool
            selectedToolItemIdentifier = selection.itemIdentifier
            lastSelectedNonEraserTool = selection
            previousSelectedTool = selection
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

    @objc
    private func applicationDidBecomeActive() {
        // The system Pencil-only preference can change while Jottre is
        // suspended. Refresh document navigation before the next gesture.
        synchronizePageInputState()
    }

    @objc
    private func applicationWillTerminate() {
        applicationBackgroundFlushTask?.cancel()
        Task { @MainActor [viewModel] in await viewModel.applicationWillTerminate() }
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

    @objc private func pdfScaleDidChange() {
        zoomCoordinator.scaleChanged()
    }

    @objc private func handleTwoFingerDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .recognized,
              pdfView.document != nil,
              isEditingEnabled,
              let undoManager = inkUndoManager,
              undoManager.canUndo else { return }
        undoManager.undo()
    }

    private func updatePageOverlayRendererZoom() {
        for canvas in pageCanvases.values {
            updatePageCanvasRenderer(for: canvas)

        }
    }

    private func updatePageCanvasRenderer(for canvas: PKCanvasView) {
        guard let pageIndex = pageIndexByCanvas[ObjectIdentifier(canvas)],
            let overlay = pageOverlays[pageIndex]
        else { return }
        overlay.configure(in: pdfView, pdfScaleFactor: pdfView.scaleFactor)
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
                overlaySize: pageOverlays[pageIndex]?.drawingSize ?? currentPageSize
            )
        }
        isApplyingOverlayDrawing = false
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

    private func pageIndex(for stroke: PKStroke) -> Int {
        let stride = currentPageSize.height + JotPageLayout.pageSpacing
        guard stride.isFinite, stride > 0 else { return 0 }
        return max(0, Int(floor(max(0, stroke.renderBounds.midY) / stride)))
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

    private var inkUndoManager: UndoManager? {
        toolUndoManager
            ?? currentPDFPageIndex.flatMap { pageCanvases[$0]?.undoManager }

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
            let document = pdfView.document
        else { return nil }
        let index = document.index(for: page)
        return index == NSNotFound ? nil : index
    }

    @objc private func pdfPageChanged() {
        guard !isInstallingPDFDocument else { return }
        guard let pageIndex = currentPDFPageIndex else { return }
        JottreDiagnostics.shared.recordPage(pageIndex, strokeCount: viewModel.currentDrawing.strokes.count)
        pendingScrollPage = pageIndex
        defaultsService.set(lastPageKey, value: pageIndex)
        #if !targetEnvironment(macCatalyst)
        synchronizePageInputState()
        #endif
    }

}

#if !targetEnvironment(macCatalyst)
// MARK: - PencilKit tool picker

extension EditJotViewController: PKToolPickerObserver {

    func toolPickerIsRulerActiveDidChange(_ toolPicker: PKToolPicker) {
        guard !isApplyingPageInputState else { return }
        cachedRulerActive = toolPicker.isRulerActive
        #if DEBUG
        EditorInteractionFixture.pickerRulerActive = cachedRulerActive
        #endif
        synchronizePageInputState()
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
        synchronizePageInputState()
        if isEditingEnabled && !toolPicker.isVisible {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.restorePersistentToolPickerIfNeeded()
            }
        }
    }

    private func scheduleSelectedCanvasToolUpdate() {
        selectedToolUpdateTask?.cancel()
        selectedToolUpdateTask = Task { @MainActor [weak self] in
            // PencilKit publishes the item selection after its observer callback.
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.selectedCanvasToolDidChange()
        }
    }

    private func selectedCanvasToolDidChange() {
        synchronizeSelectedToolFromPicker(recordHistory: true)
        updateCanvasInteraction()
    }

    private func synchronizeSelectedToolFromPicker(recordHistory: Bool = false) {
        let selectedTool = selectedToolFromPicker()
        let selectedIdentifier = toolPicker.selectedToolItemIdentifier
        if let previousIdentifier = selectedToolItemIdentifier,
            previousIdentifier != selectedIdentifier,
            recordHistory
        {
            previousSelectedTool = ToolSelection(
                tool: selectedCanvasTool,
                itemIdentifier: previousIdentifier
            )
        }
        selectedToolItemIdentifier = selectedIdentifier
        if !(selectedTool is PKEraserTool) {
            lastSelectedNonEraserTool = ToolSelection(
                tool: selectedTool,
                itemIdentifier: selectedIdentifier
            )
        }
        selectedCanvasTool = selectedTool
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

    private func selectToolInPicker(_ selection: ToolSelection) {
        if toolPicker.toolItems.contains(where: { $0.identifier == selection.itemIdentifier }) {
            toolPicker.selectedToolItemIdentifier = selection.itemIdentifier
            return
        }

        // Prefer an exact public-tool match, then fall back to the nearest
        // installed item when the picker no longer contains the old item.
        let exactItem = toolPicker.toolItems.first { Self.matches($0, selection.tool, includeSettings: true) }
        let compatibleItem = exactItem ?? toolPicker.toolItems.first {
            Self.matches($0, selection.tool, includeSettings: false)
        }
        if let compatibleItem { toolPicker.selectedToolItemIdentifier = compatibleItem.identifier }
    }

    private func selectToolInPicker(_ tool: any PKTool) {
        guard let item = toolPicker.toolItems.first(where: {
            Self.matches($0, tool, includeSettings: false)
        }) else { return }
        selectToolInPicker(ToolSelection(tool: tool, itemIdentifier: item.identifier))
    }

    private func selectEraserInPicker() {
        // The system picker uses fixed-width bitmap eraser items on current
        // iPadOS releases; requiring the legacy `.bitmap` type can miss them.
        let eraserItem = toolPicker.toolItems.first { item in
            (item as? PKToolPickerEraserItem)?.eraserTool.eraserType == .bitmap
        } ?? toolPicker.toolItems.first { $0 is PKToolPickerEraserItem }
        guard let eraserItem else { return }
        toolPicker.selectedToolItemIdentifier = eraserItem.identifier
    }

    private static func matches(
        _ item: PKToolPickerItem,
        _ tool: any PKTool,
        includeSettings: Bool
    ) -> Bool {
        if let desired = tool as? PKInkingTool, let candidate = item as? PKToolPickerInkingItem {
            let actual = candidate.inkingTool
            guard actual.inkType == desired.inkType else { return false }
            guard includeSettings else { return true }
            return actual.width == desired.width && actual.color.isEqual(desired.color)
        }
        if let desired = tool as? PKEraserTool, let candidate = item as? PKToolPickerEraserItem {
            let actual = candidate.eraserTool
            guard actual.eraserType == desired.eraserType else { return false }
            return !includeSettings || actual.width == desired.width
        }
        return tool is PKLassoTool && item is PKToolPickerLassoItem
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
                if let lastSelectedNonEraserTool {
                    selectToolInPicker(lastSelectedNonEraserTool)
                } else {
                    selectToolInPicker(PKInkingTool(.pen))
                }
            } else {
                let identifier = toolPicker.selectedToolItemIdentifier
                lastSelectedNonEraserTool = ToolSelection(tool: selectedTool, itemIdentifier: identifier)
                selectEraserInPicker()
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
                if !(selectedCanvasTool is PKInkingTool) {
                    let pen = PKInkingTool(.pen, color: .label, width: 5)
                    selectedCanvasTool = pen
                    selectToolInPicker(pen)
                }
            }
            #endif
        } else {
            swipeBackGesture.isEnabled = true
            #if !targetEnvironment(macCatalyst)
            if let inking = selectedCanvasTool as? PKInkingTool {
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
        synchronizePageInputState()
        #if !targetEnvironment(macCatalyst)
        persistentCanvasAnchor.preservesFirstResponder = CanvasTouchRouting.usesPersistentResponder(
            isEditing: isEditingEnabled, tool: selectedToolFromPickerIfAvailable())
        if isEditingEnabled { restorePersistentToolPickerIfNeeded() }
        #endif
    }



    #if !targetEnvironment(macCatalyst)

    private func activateLassoCanvas(_ canvas: JotCanvasView) {
        guard isEditingEnabled, selectedToolFromPickerIfAvailable() is PKLassoTool,
            canvas.window != nil, pageIndexByCanvas[ObjectIdentifier(canvas)] != nil else { return }
        // PencilKit can move focus into its native selection responder. Once
        // this page owns the lasso session, preserve that internal focus.
        if activeLassoCanvas === canvas { return }
        persistentCanvasAnchor.preservesFirstResponder = false
        _ = persistentCanvasAnchor.resignFirstResponder()
        if activeLassoCanvas !== canvas { _ = activeLassoCanvas?.resignFirstResponder() }
        if let previousCanvas = activeLassoCanvas, previousCanvas !== canvas {
            toolPicker.removeObserver(previousCanvas)
        }
        activeLassoCanvas = canvas
        // PKCanvasView handles picker attribute changes (including recoloring
        // its active lasso selection) only while it observes this picker.
        toolPicker.addObserver(canvas)
        if canvas.becomeFirstResponder() {
            toolPicker.setVisible(true, forFirstResponder: canvas)
        }
        #if DEBUG
        if let index = pageIndexByCanvas[ObjectIdentifier(canvas)] {
            EditorInteractionFixture.publish(canvas: canvas, index: index, pdfView: pdfView, host: view)
        }
        #endif
    }

    private func restorePersistentToolPickerIfNeeded() {
        guard isEditingEnabled, isToolPickerObserverAttached,
            persistentCanvasAnchor.window != nil, !isRestoringToolPicker else { return }
        isRestoringToolPicker = true
        defer { isRestoringToolPicker = false }
        if selectedToolFromPickerIfAvailable() is PKLassoTool, let canvas = activeLassoCanvas,
            canvas.window != nil {
            if let responder = canvas.firstResponderInHierarchy {
                if !toolPicker.isVisible { toolPicker.setVisible(true, forFirstResponder: responder) }
            } else if !toolPicker.isVisible {
                _ = canvas.becomeFirstResponder()
                toolPicker.setVisible(true, forFirstResponder: canvas)
            }
            return
        }
        if let canvas = activeLassoCanvas {
            toolPicker.removeObserver(canvas)
            _ = canvas.resignFirstResponder()
        }
        activeLassoCanvas = nil
        if !persistentCanvasAnchor.isFirstResponder { _ = persistentCanvasAnchor.becomeFirstResponder() }
        if !toolPicker.isVisible { toolPicker.setVisible(true, forFirstResponder: persistentCanvasAnchor) }
    }
    #endif

    private var isDrawAndHoldShapeConversionEnabled: Bool {
        defaultsService.getValue(.drawAndHoldShapeConversionEnabled) ?? true
    }

    @discardableResult
    private func toggleDrawAndHoldShapeConversion() -> Bool {
        let isEnabled = !isDrawAndHoldShapeConversionEnabled
        defaultsService.set(.drawAndHoldShapeConversionEnabled, value: isEnabled)
        shapeCoordinator.isEnabled = isEnabled

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
                        let visiblePage = viewModel.visiblePageProvider?()
                        pendingScrollPage = visiblePage
                        viewModel.addPage(afterPageIndex: visiblePage)
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
                                Text(
                                    String.localizedStringWithFormat(
                                        String(localized: "editJot.pages.trashedPage"),
                                        page.originalIndex + 1
                                    )
                                )
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
        let defaultSize = JotPageLayout.defaultSize
        do {
            let prepared: (Data, CGSize) = try await Task.detached(priority: .utility) {
                switch background {
                case let .ruled(extraPages):
                    return (
                        try JotHybridPDFBuilder.makeRuledPDF(pageSize: defaultSize, pageCount: 1 + extraPages),
                        defaultSize
                    )
                case let .pdf(data, _, slots):
                    guard let metadata = JotPDFMetadata(pdfData: data) else {
                        throw PDFLoadService.Failure.couldNotParse
                    }
                    let size = CGSize(
                        width: defaultSize.width,
                        height: defaultSize.width * metadata.pageAspectRatio
                    )
                    return (
                        try HybridPDFManager.materializePages(
                            pdfData: data,
                            insertedPageSlots: slots,
                            blankPageCount: 0,
                            pageSize: size
                        ), size
                    )
                }
            }.value
            guard !Task.isCancelled else { return }
            currentPageSize = prepared.1
            if case .pdf = background {
                applyDocumentAppearance(isPDFBacked: true)
            } else {
                applyDocumentAppearance(isPDFBacked: false)
            }
            installPDFDocument(prepared.0)
        } catch {
            viewModel.logger.error("Failed to prepare editor PDF: \(error)")
        }
    }

    private func installPDFDocument(_ data: Data) {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { return }
        // Setting a fresh PDF makes PDFView briefly report page zero. Preserve
        // the pre-install page before that notification can replace the saved
        // index, then restore it after the new document is attached.
        let preservedPageIndex =
            JotPDFPageRestorationPolicy.targetIndex(
                pendingIndex: pendingScrollPage,
                currentIndex: currentPDFPageIndex,
                pageCount: document.pageCount
            ) ?? 0
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            page.annotations
                .filter { $0.contents == PDFAnnotationConverter.marker }
                .forEach(page.removeAnnotation)
        }
        overlayStore.reset()
        isInstallingPDFDocument = true
        pdfView.document = document
        pdfView.autoScales = true
        if let page = document.page(at: preservedPageIndex) {
            pdfView.go(to: page)
        }
        pendingScrollPage = preservedPageIndex
        isInstallingPDFDocument = false
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.synchronizePageInputState()
        }
    }

    /// PencilKit interprets its black/white palette relative to the canvas's
    /// appearance. PDF pages always use their authored (light) appearance, so
    /// the picker must create colors for a light canvas even when its own UI is
    /// dark. Plain notes keep PencilKit's normal adaptive appearance.
    fileprivate func applyDocumentAppearance(isPDFBacked: Bool) {
        let canvasStyle: UIUserInterfaceStyle = isPDFBacked ? .light : .unspecified
        canvasAppearance = canvasStyle
        pageCanvases.values.forEach { $0.overrideUserInterfaceStyle = canvasStyle }
        #if !targetEnvironment(macCatalyst)
        toolPicker.colorUserInterfaceStyle = canvasStyle
        #endif
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
            shapeCoordinator.drawingDidChange(canvasView)
            #if DEBUG
            EditorInteractionFixture.publish(canvas: canvasView, index: pageIndex, pdfView: pdfView, host: view)
            #endif
            let converted = canonicalDrawing(
                from: canvasView.drawing,
                pageIndex: pageIndex,
                overlaySize: pageOverlays[pageIndex]?.drawingSize ?? currentPageSize
            )
            guard inkCanvasCoordinator.replacePage(converted, at: pageIndex) else { return }
            viewModel.didChangeDrawing(
                inkCanvasCoordinator.committedDrawing,
                strokePageIndices: inkCanvasCoordinator.committedStrokePageIndices,
                changedPageIndices: [pageIndex]
            )
            JottreDiagnostics.shared.updateInkState(strokeCount: inkCanvasCoordinator.committedDrawing.strokes.count)
            return
        }
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        if let canvas = canvasView as? JotCanvasView,
            pageIndexByCanvas[ObjectIdentifier(canvas)] != nil
        {
            if canvas.tool is PKLassoTool { activateLassoCanvas(canvas) }
            #if DEBUG
            if let index = pageIndexByCanvas[ObjectIdentifier(canvas)] {
                EditorInteractionFixture.publish(canvas: canvas, index: index, pdfView: pdfView, host: view)
            }
            #endif
            toolUndoManager = canvasView.undoManager
            return
        }
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        if let canvas = canvasView as? JotCanvasView,
            pageIndexByCanvas[ObjectIdentifier(canvas)] != nil
        {
            toolUndoManager = nil
            return
        }
    }

    private func flushPendingDrawingChange() {
        // Page callbacks commit synchronously to the model. Capture a final
        // snapshot only if PencilKit has delivered an unreported last sample.
        for (index, canvas) in pageCanvases {
            let expected = localDrawing(
                from: inkCanvasCoordinator.committedDrawing,
                pageIndices: inkCanvasCoordinator.committedStrokePageIndices,
                pageIndex: index,
                overlaySize: pageOverlays[index]?.drawingSize ?? currentPageSize
            )
            if !JotEditorDrawingState.drawingsMatch(canvas.drawing, expected) { canvasViewDrawingDidChange(canvas) }
        }
    }

}
