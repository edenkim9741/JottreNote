# Editor rendering and persistence

## Page coordinates and rendering

`JotPDFPageCanvasOverlay` is the only live ink surface. Each PDF page gets one
native PencilKit canvas, clipped to its page. Drawing coordinates use a normalized
width of 1200 points and the page's displayed aspect ratio.

`JotCanvasRenderGeometry` defines the mapping:

- PDFKit supplies the outer page display scale, measured using converted basis vectors.
- The canvas viewport is the page size multiplied by that display scale.
- PencilKit's native zoom is viewport width divided by normalized drawing width.
- The viewport host applies the inverse page scale.
- Canvas pixel density uses screen density once.

This keeps the PDF and ink registered and lets PencilKit regenerate its own ink
tiles. Canvas pinch recognizers stay disabled so PDFKit owns document zoom.
`JotCanvasZoomCoordinator` refreshes after pinch completion or coalesced PDFKit
scale notifications, including double tap and programmatic zoom. Unchanged
geometry skips layout work. Live drawings remain native PencilKit data.

## Ownership and input

`JotPageOverlayStore` retains displayed overlays and keeps a weak lookup for
PDFKit reuse. Ending display removes the editor's strong references. Resetting a
document invalidates old callbacks. PDFKit may retain its own offscreen views.

`JotEditorGestureCoordinator` applies one input state to the displayed pages:
editing mode, selected tool, picker visibility, active page and ruler state.
Every native PencilKit tool, including lasso, uses `.pencilOnly`; direct touches
remain with PDFKit for scrolling and double-tap zoom. Ruler activation applies
to the current page. Reading restores the original PDF pan touch types.

The stable tool-picker responder follows editor appearance/disappearance.
Drawing tools keep the persistent anchor. Native PencilKit retains ownership of
lasso creation and moving selected strokes. PDF navigation never configures
recognizers inside a page overlay, and one-finger PDF navigation remains enabled.

`JotPDFView.isInMarkupMode` follows editing mode so PDFKit hit-tests page overlays.
The PDF and canvas responder classes suppress standard edit actions during
editing. No custom long-press blocker, recursive hit-test override, or private
PencilKit selection recognizer handling is used. PDFKit and PencilKit retain
ownership of their native gesture recognizers.

`JotPageShapeCoordinator` observes native page drawing gestures and only replaces
a completed stroke after an explicit endpoint hold. Its timers and canvas
references are scoped to the active stroke.

`JotEditorDrawingState` stores canonical ink without owning renderer views.
Page replacement preserves other pages and ignores duplicate callbacks.

## Persistence and synchronization

`EditJotPersistenceWriter` remains the per-document save owner. It coalesces
revisions, debounces for two seconds and drains on a utility task. Editor exit
flushes pending changes. `JotHybridPDFBuilder` is shared by saving and PDF export.
PencilKit binary normalization at the builder boundary is required for identical
export/backup payloads after decoding and reopening a drawing.

`FileAccessCoordinator` shares scoped recursive locks across repository instances.
Cache read/modify/write operations lock the cache directory. Local file operations
lock the target; moving locks both paths in stable order. Idle entries are removed.

`AsyncResourceAccessCoordinator` holds resource ownership across suspension points.
A remote attachment's ZIP, prop and API updates form one transaction. Cached
attachment uploads obtain ownership before reading dirty state, so completed
uploads can make queued requests unnecessary. Errors and cancellation release
ownership. Separate attachments can proceed concurrently.

ZIP extraction and hybrid restoration execute on utility tasks.
`TemporaryFileWorkspace` removes operation directories after success or failure
and prunes abandoned, owned UUID directories older than 24 hours. Active operations
and user conflict copies are preserved.

## Regression coverage

`ArchitectureRefactoringTests` covers page-coordinate geometry, zoom coalescing,
intermediate zoom alignment, overlay release/rebinding, lasso/ruler/reading state,
scoped file/cache updates, async resource serialization
and cancellation, and temporary workspace cleanup.

`PageCanvasRenderingTests` compares actual small-page ink screenshots, validates
native zoom, PDF alignment, disabled inner pinch gestures and coordinate round trips.
Existing hybrid PDF tests validate vector annotations, multi-page coordinates,
page manipulation and Zotero ZIP restoration. Real-device frame pacing, Pencil
feel, GPU memory and thermal behavior require device profiling.

`EditorTransitionAndSortingTests` covers first-frame canvas configuration,
Pencil-only lasso input, PDF gesture availability, sorting persistence and cold
launch policy. `JottreInteractionUITests` is a separate simulator UI test scheme:
It checks page-transition menus and sorting after terminating/relaunching the
app. Native PencilKit lasso selection is left to Apple Pencil interaction. Fixture
documents and accessibility probes are available only in DEBUG with an explicit
test launch environment.

## Library launch state

`ZoteroLibrarySorting` stores criterion and reversal together in UserDefaults and
loads them before publishing the first library snapshot. Selecting the current
criterion reverses it; selecting another uses its default direction. A normal
cold launch starts at the library, while explicit document-open/Handoff requests
remain supported. Editor scene restoration is intentionally disabled.
