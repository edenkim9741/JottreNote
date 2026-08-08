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
            static let maximumZoomScale = CGFloat(3)
            static let bottomFreespace = CGFloat(500)
        }

        enum Page {
            static let width = CGFloat(1200)
            static let height = CGFloat(1600)
            static let spacing = CGFloat(24)
        }
    }

    #if !targetEnvironment(macCatalyst)
    private lazy var toolPicker = PKToolPicker()
    #endif

    private lazy var canvasView: PKCanvasView = {
        let canvasView = PKCanvasView()
        canvasView.delegate = self
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.drawingPolicy = .default
        canvasView.maximumZoomScale = Constants.CanvasView.maximumZoomScale
        canvasView.bounces = false
        canvasView.contentInsetAdjustmentBehavior = .always
        canvasView.backgroundColor = .clear
        return canvasView
    }()

    private let backgroundView: JotBackgroundView = {
        let view = JotBackgroundView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }()

    private var drawingWidth = CGFloat.zero
    private var backgroundContentHeight = CGFloat.zero

    private let pdfLoadService = PDFLoadService()

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

    private var isEditingTask: Task<Void, Never>?
    private var drawingTask: Task<Void, Never>?
    private var backButtonTask: Task<Void, Never>?
    private var backgroundTask: Task<Void, Never>?

    private let viewModel: EditJotViewModel
    private let symbolBarButtonItemFactory: SymbolBarButtonItemFactory

    init(
        viewModel: EditJotViewModel,
        symbolBarButtonItemFactory: SymbolBarButtonItemFactory
    ) {
        self.viewModel = viewModel
        self.symbolBarButtonItemFactory = symbolBarButtonItemFactory
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
                canvasView.drawing = drawing.value
                if canvasView.superview == nil {
                    setUpCanvasView()
                }
            }
        }
        backButtonTask = Task { @MainActor [weak self] in
            for await showsBackButton in viewModel.showsBackButton {
                self?.handleBackButton(showsBackButton: showsBackButton)
            }
        }
        backgroundTask = Task { @MainActor [weak self] in
            for await background in viewModel.background {
                self?.applyBackground(background)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        assertionFailure("\(#function) has not been implemented")
        return nil
    }

    deinit {
        isEditingTask?.cancel()
        drawingTask?.cancel()
        backButtonTask?.cancel()
        backgroundTask?.cancel()
    }

    override func viewDidLoad() {
        setUpNavigationBar()
        setUpViews()
        super.viewDidLoad()
        viewModel.didLoad()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutCanvasContent()
    }

    private func setUpNavigationBar() {
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.title = viewModel.title
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
    }

    @objc
    private func handleSwipeBack(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        viewModel.didTapBackButton()
    }

    private func layoutCanvasContent() {
        guard drawingWidth > 0 else { return }
        let scale = canvasView.bounds.width / drawingWidth
        canvasView.minimumZoomScale = scale
        canvasView.zoomScale = scale

        let drawingMaxY: CGFloat
        if canvasView.drawing.bounds.isNull {
            drawingMaxY = backgroundContentHeight + Constants.CanvasView.bottomFreespace
        } else {
            let contentMaxY = max(canvasView.drawing.bounds.maxY, backgroundContentHeight)
            drawingMaxY = contentMaxY + Constants.CanvasView.bottomFreespace
        }

        canvasView.contentSize = CGSize(
            width: canvasView.bounds.width,
            height: max(canvasView.bounds.height, drawingMaxY * scale)
        )
    }

    private func setUpCanvasView() {
        view.addSubview(backgroundView)
        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        view.addSubview(canvasView)
        NSLayoutConstraint.activate([
            canvasView.topAnchor.constraint(equalTo: view.topAnchor),
            canvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
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
                let pen = PKInkingTool(.pen, color: .label, width: 5)
                canvasView.tool = pen
                toolPicker.selectedTool = pen
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
        }

        // There's a bug in the stack layouting of ``UINavigationItem`` which, if placing a single item,
        // causes this single item to stretch across the entire navigation bar.
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
                    jotMenuConfigurations: viewModel.menuConfigurations.make(popoverAnchorProvider: {
                        guard let barButtonItem = moreBarButtonItemRef else { return nil }
                        return { $0.barButtonItem = barButtonItem }
                    })
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

// MARK: - PDF

private extension EditJotViewController {

    func applyBackground(_ background: EditJotViewModel.Background) {
        switch background {
        case let .ruled(extraPages):
            let pageSize = CGSize(width: Constants.Page.width, height: Constants.Page.height)
            let totalPages = CGFloat(1 + extraPages)
            backgroundContentHeight = totalPages * Constants.Page.height
                + max(0, totalPages - 1) * Constants.Page.spacing
            backgroundView.configure(
                content: .ruled(pageSize: pageSize, extraPages: extraPages),
                scrollOffset: canvasView.contentOffset,
                zoomScale: canvasView.zoomScale
            )
        case let .pdf(data, extraPages):
            let result: PDFLoadService.Result
            do {
                result = try pdfLoadService.load(
                    data: data,
                    normalizedPageSize: CGSize(width: Constants.Page.width, height: Constants.Page.height)
                )
            } catch {
                result = PDFLoadService.Result(pages: [], pageSize: CGSize(width: Constants.Page.width, height: Constants.Page.height))
            }
            let pages = result.pages
            let pageSize = result.pageSize
            let totalPages = CGFloat(pages.count + extraPages)
            backgroundContentHeight = totalPages * pageSize.height
                + max(0, totalPages - 1) * Constants.Page.spacing
            backgroundView.configure(
                content: .pdf(pages: pages, pageSize: pageSize, extraPages: extraPages),
                scrollOffset: canvasView.contentOffset,
                zoomScale: canvasView.zoomScale
            )
        }
        layoutCanvasContent()
    }

}

// MARK: - PKCanvasViewDelegate

extension EditJotViewController: PKCanvasViewDelegate {

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        viewModel.didChangeDrawing(canvasView.drawing)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        backgroundView.sync(scrollOffset: scrollView.contentOffset, zoomScale: scrollView.zoomScale)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        backgroundView.sync(scrollOffset: scrollView.contentOffset, zoomScale: scrollView.zoomScale)
    }
}
