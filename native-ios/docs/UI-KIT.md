# UI kit handbook

How to build a screen on the app shell, and what every shared view takes. For the engineers
replacing the placeholder screens, and for maintainers. Read `CONVENTIONS.md` and
`spec/DECISIONS.md` first; the screen specs (06, 07, 05 §4–§16) say what each screen does. This
file says how to put it together with what exists. Signatures are as in the code at the time of
writing. When they change, update this file in the same commit.

## Where things are

| Path | What |
|---|---|
| `Packages/InventoryKit/Sources/InventoryAppModels/Composition/` | `AppContainer` (the composition root), `AppPlatform`, `CurrentRepositories`, the preview container and its sample data. |
| `…/InventoryAppModels/Navigation/` | `Router`, `RouterState`, the route enums, `DeepLink`. |
| `…/InventoryAppModels/{Home,Entities,Capture,Scan,Household,Sync,Shell,Query}/` | The wave-3 screen models. They are UI-free and tested with `mac.sh test`. |
| `…/InventoryAppModels/Components/`, `…/Media/` | The pure logic behind the components and media views (copy, layout rules, the thumbnail loader). |
| `App/Shell/` | The root view, tabs, overlay window (toasts, removed-phone layer), `ScreenFrame`, `BottomBar`, focus modifiers, dialogs, haptics, the DEBUG demo. |
| `App/Navigation/` | The tab stacks, the modal presentation and the route → screen switch. |
| `App/Screens/<Area>/` | **The placeholder screens you replace**, and your area's DEBUG demo hooks (`<Area>Demo.swift`). |
| `App/Screens/Shared/` | Screen-level views several areas embed: `PlacePickerHost`; the foundation gallery. |
| `App/Design/` | Tokens, glyphs, type roles, `LayoutScale`, `WrappingHStack`, accessibility helpers. |
| `App/Components/` | Shared SwiftUI components and their DEBUG gallery. |
| `App/Media/` | Camera, QR scanner, camera permission, library picker, QR label views and their gallery. |

## 1. Building a screen

### 1.1 The placeholders to replace

Every route already resolves to a screen struct in `App/Screens/`. Keep the type name, the init
and the `screen-*` accessibility identifier (the UI tests find screens by it). Replace the body
and read the doc comment at the top of the file first: where a placeholder exercises navigation,
it shows the exact router calls the real screen needs.

| Route (`App/Navigation/RouteScreens.swift`) | File | Init |
|---|---|---|
| Root while onboarding is pending | `Account/OnboardingScreen.swift` | `OnboardingScreen()`: completing calls `app.onboarding.complete()`, the gate flips by itself |
| Tab root Home · Spaces · Scan · Drop zone | `Home/HomeScreen.swift`, `Home/SpacesScreen.swift`, `Labels/ScanScreen.swift`, `Home/DropZoneScreen.swift` | `HomeScreen()`, `SpacesScreen()`, `ScanScreen()`, `DropZoneScreen()` |
| `PushRoute.settings` / `.privacy` / `.household` / `.backup` | `Account/…Screen.swift` | `SettingsScreen()`, `PrivacyScreen()`, `HouseholdScreen()`, `BackupScreen()` |
| `.label(token:)` | `Labels/LabelLinkScreen.swift` | `LabelLinkScreen(token:)` |
| `.space(id:)` | `Places/SpaceDetailScreen.swift` | `SpaceDetailScreen(id:)` |
| `.container(id:)` (never the drop zone) | `Places/ContainerDetailScreen.swift` | `ContainerDetailScreen(id:)` |
| `.qrLabel(containerId:)` | `Labels/QrLabelScreen.swift` | `QrLabelScreen(containerId:)` |
| `.item(id:filing:)` | `Item/ItemDetailScreen.swift` | `ItemDetailScreen(id:filing:)` |
| `.quickSnapReview(QuickSnapReviewRoute)`: pushed inside the capture cover | `Capture/QuickSnapReviewScreen.swift` | `QuickSnapReviewScreen(route:)` |
| `SheetRoute.addItem(AddParams)`: draws its own Cancel | `Add/AddSheet.swift` | `AddSheet(params:)` |
| `.spaceNew(request:)` | `Places/SpaceNewSheet.swift` | `SpaceNewSheet(request: RouteRequest<NewSpaceResult>?)` |
| `.spaceEdit(id:)` | `Places/SpaceEditSheet.swift` | `SpaceEditSheet(id:)` |
| `.containerNew(spaceId:request:)` | `Places/ContainerNewSheet.swift` | `ContainerNewSheet(spaceId:request: RouteRequest<NewContainerResult>?)` |
| `.containerEdit(id:)` | `Places/ContainerEditSheet.swift` | `ContainerEditSheet(id:)` |
| `.itemEdit(id:)` | `Item/ItemEditSheet.swift` | `ItemEditSheet(id:)` |
| `.move(itemId:filing:request:)` | `Item/MoveSheet.swift` | `MoveSheet(itemId:filing:request: RouteRequest<MoveResult>?)` |
| `CoverRoute.capture(CaptureRoute, request:)` | `Capture/CaptureScreen.swift` | `CaptureScreen(route:request: RouteRequest<StoredImage>?)` |
| `.photo(itemId:)` | `Item/PhotoViewerScreen.swift` | `PhotoViewerScreen(itemId:)` |
| `.linkSticker(containerId:)` | `Labels/LinkStickerScreen.swift` | `LinkStickerScreen(containerId:)` |

Payloads carry only what the RN URL carried (ids, flags, the opener's request) plus the typed
capture routes. A screen reaches everything else through the environment. Sheets already sit in
their own `NavigationStack` with the shell's Cancel (`sheet-close`) in the
`.cancellationAction` slot. The Add sheet is the exception: it draws its own Cancel. Covers sit
in a `NavigationStack` too. Hide its bar with `.toolbar(.hidden, for: .navigationBar)`.
`ShellPlaceholderContent` and `ShellPlaceholderQuery` exist only for the placeholders. Delete
their uses with the placeholder, and the files once nothing uses them.

### 1.2 The shape of a screen

```swift
struct SpaceDetailScreen: View {
    let id: String
    @Environment(AppContainer.self) private var app
    @Environment(\.screenAddress) private var address
    @State private var query: InventoryQuery<Space?>?

    var body: some View {
        ScreenFrame(.detail) {
            if let query { content(query).inventoryQuery(query) }
        }
        .navigationTitle(query?.data??.name ?? "")
        .toolbar { ToolbarItem(placement: .primaryAction) { SearchButton() } }
        .accessibilityIdentifier("screen-space")
        .onAppear {
            guard query == nil else { return }
            let repositories = app.repositories, id = id
            query = InventoryQuery(key: "space:\(id)", revision: app.database.revision) {
                try await repositories.spaces.getById(id)
            }
        }
    }

    @ViewBuilder private func content(_ query: InventoryQuery<Space?>) -> some View {
        if let cause = query.cause, !query.refreshFailed {  // a failed refresh keeps the data (show a banner)
            ErrorStateView(cause: .failed(cause), subject: .space, onRetry: { query.reload() })
        } else if let read = query.data {
            if let space = read {
                List { … }
            } else {
                ErrorStateView(cause: .gone, subject: .space, onRetry: { query.reload() })
            }
        } else {
            SkeletonView(variant: .list)
        }
    }
}
```

### 1.3 The environment

`RootView` and every modal level set these through `.shellEnvironment(app)` and the stacks.

| Entry | Type | Use |
|---|---|---|
| `@Environment(AppContainer.self)` | `AppContainer` | Every model, service and store. Never make your own. |
| `@Environment(Router.self)` | `Router` | The same object as `app.router`. |
| `\.screenAddress` | `ScreenAddress?` | This screen's place: `.tabRoot(tab)`, `.push(id)` or `.modal(screenID)`. Pass it back to the router to close or replace this screen, to register removal hooks and to set close guards. Nil outside the shell (previews). |
| `\.isScreenFocused` | `Bool` | True when this screen is in front: top of its stack, its tab selected, nothing presented over it. A screen under a sheet is unfocused. It drives queries, tickers, the camera and the scanner. |
| `\.haptics` | `HapticPlayer` | `haptics(.choice)`. The same player as `app.platform.haptics`. |
| `\.photoPathResolver` | `PhotoPathResolver` | Resolves stored photo URIs (`Thumb` reads it). |
| `\.shellAnnounce` | `(String) -> Void` | An interrupting VoiceOver announcement, silent in previews. |
| `\.shellWindowSize` | `CGSize` | The window size, safe area included. `.zero` until measured. |
| `\.layoutWindowWidth` | `CGFloat` | The window width that `LayoutScale` reads. `RootView` sets it, and it is `.infinity` outside the app (previews), so there nothing stacks for width alone. |
| `\.shellTabBarChrome` | `ShellTabBarChrome?` | The shell's own: the tab bar height for the toast position. |

### 1.4 `ScreenFrame` and `BottomBar`

```swift
ScreenFrame(_ kind: Kind, banner: Bool? = nil, background: Background = .grouped) { content }
ScreenFrame(_ kind: Kind, banner: Bool? = nil, background: Background = .grouped) { content } bottomBar: { BottomBar … }
```

- `Kind`: `.tabRoot`, `.detail`, `.modal` (all in a navigation stack, which owns the title) and
  `.camera`. `.camera` is full bleed on black in a dark scheme with a white tint, and has no
  banner, but keeps the bottom bar.
- The frame draws the connection banner in a top inset, outside any scroll view, so it never
  scrolls away (`banner: false` turns it off). It keeps the content to a 640 pt column centred
  on iPad, and puts `systemGroupedBackground` (`.grouped`) or `systemBackground` (`.plain`)
  behind it.
- The bottom bar is an iOS 26 `safeAreaBar`: content scrolls under it and it rises with the
  keyboard. Forms put Save here, not in the toolbar.

```swift
BottomBar(primaryFit: Bool = false, stackOnLarge: Bool = true) { secondary } primary: { primary }
BottomBar { primary }
```

- The secondary comes first and the primary last, so the primary sits under the thumb. Side by
  side the split is 1 : 1.4. With `primaryFit` the primary takes the width of its label (at
  least 120 pt) and the secondary takes the rest.
- The buttons stack, primary on top, at `.xxxLarge` text and up or in a window narrower than
  360 pt (`LayoutScale`'s rule).
- While the screen is focused, the bar registers its height with `ToastCenter`, so toasts
  float above it.
- Put `LoadingButton(…, fullWidth: true)` in both slots: the bar sets
  `.buttonSizing(.flexible)` and `.controlSize(.large)`.

Forms in sheets: use `ScreenFrame(.modal) { FormLayout { notice } content: { … } } bottomBar:
{ BottomBar { … } }`. The two-closure `FormLayout(notice:content:)` has no bar of its own. The
three-closure form with `bottomBar:` places a bare bar itself. The galleries use it, and in the
app it would skip the toast and stacking behaviour.

### 1.5 Reading data

- **Queries.** Keep an `InventoryQuery(key:revision:read:)` in `@State`, made once in
  `onAppear` (or in a model). Attach `.inventoryQuery(query)` to the view that shows it. The
  modifier reports focus changes (`\.isScreenFocused`) and `app.database.revision` changes. It
  also resyncs on appear and when you swap in a new query instance, and it unfocuses the query
  when the view disappears. Use `setKey(_:read:)` when the inputs change, and `reload` for Try
  again.
- **Outputs.** `data` is the last settled value. `isLoading` is true until the newest trigger
  settles. `cause` is set only once a read has failed, and `refreshFailed` means data is still
  on screen. A read that answered nil is data ("gone"), not a cause.
- **Repositories.** Always go through `app.repositories` (`CurrentRepositories`). It forwards
  each call to whatever is in use now: this phone's SQLite, or the household's after a join.
  Models created once can keep it. Before the database is ready a call throws
  `CurrentRepositoriesNotReady`, which `describeError` reads as a local failure.
- **Writes.** Models take `invalidator: app.database`. Invalidating bumps `revision`, and every
  focused query re-reads.
- **States.** `SkeletonView(variant:)` while loading (it shows after 180 ms).
  `ErrorStateView(cause: .failed(cause), …)` for a failed read, and `.gone` from your own
  branch when the record is missing. Never derive `.gone` from a nil `cause`.
  `EmptyStateView` for an honest empty list.
- **Time.** `@State private var ticker = NowTicker()` plus `.nowTicker(ticker)` ticks only while
  focused. Pass `ticker.now` to `ItemRow(now:)` and `Format.ago`.

### 1.6 The router

Read state:
- `selectedTab`, `modals`, `path(tab)`, `modal(id)`.
- `isFocused(address)`, `isTabShellFocused`.
- `state` (`RouterState`: `frontAddress`, `canDismiss`, `modalLevel(containing:)`,
  `closesScreensOnTheWayHome`).
- `reselections[tab]` (a re-tap counter), `searchFocus`, `results`.

| Need | Call |
|---|---|
| Open a screen in front | `router.push(.item(id:filing:))`: on the top modal's stack while something is presented, else on the selected tab's stack. Returns the `PushEntry` (discardable). |
| Present | `router.present(.addItem(AddParams()))`, `router.present(.photo(itemId:))`, or `router.present(ModalRoute)`. Sheets stack over sheets, and covers over sheets. |
| Wait for a result | `let picked = await router.presentForResult(MoveResult.self) { .sheet(.move(itemId: id, filing: false, request: $0)) }`. It returns nil when the modal goes away without answering, and resumes exactly once. |
| Answer a request | `app.router.results.deliver(request, value)` returns false when nobody waits any more (then fall back, e.g. open the new space yourself). Removing a modal abandons its request automatically. |
| Close yourself | `router.close(address)`: pops a pushed screen with everything above it, or dismisses a modal root and everything over it. |
| Cancel through the guard | `await router.requestClose(address)` (the shell's Cancel uses it). |
| Replace yourself | `router.replace(address, with: PushRoute)` (pushed, only while you are on top); `router.replaceModal(containing: address, with: ModalRoute)` (Snap several, Keep shooting, Type it instead); `router.replaceTopModal(with:)`. |
| Go to a tab | `router.goToTab(.dropZone)` closes everything presented; other tabs keep their stacks. `router.openContainer(id)` / `router.openSpace(id)` send the drop zone to its tab. `router.openQuickSnap()`. |
| Search | `SearchButton()` in the toolbar calls `router.focusSearch()`. |
| Close everything | `router.dismissAll()`, `router.reset()`. |
| Removal hook | `router.onRemoval(of: address) { model.close() }` runs once when the route is popped, dismissed, replaced or reset, never when it is only covered. Never use `onDisappear` for this. A screen already gone is told at once. |
| Close guard | `.sheetCloseGuard { await dirty.attemptClose() }` together with `.interactiveDismissDisabled(dirty.interactiveDismissDisabled)`. |

The views bind stacks and modals to the router and report system actions back
(`setPath(_:for:)`, `setModalPath(_:modal:)`, `modalDismissedBySystem(_:)`,
`modalDismissalFinished()`). Screens never call these.

External requests (`open(_ url:)`, `performQuickAction(type:)`, `handle(_:)`) wait until the
main shell shows, then open in front of whatever shows and dismiss nothing: a label is pushed on
the front stack, and Quick Snap is presented on top unless it already shows.

Re-taps: SwiftUI pops a tab's stack itself on a re-tap. `reselections[tab]` goes up only when
the stack was already at its root. Home scrolls to the top or focuses search, Spaces and Drop
zone scroll to the top, and Scan goes back to the camera (`ScanModel.tabReselected()`).

### 1.7 Driving the wave-3 models

Build per-screen models once (in `@State`, made in `onAppear` or a factory), from `app`'s
stores and seams: `toasts: app.toasts`, `confirm: app.platform.confirm`,
`haptics: app.platform.haptics`, `invalidator: app.database`, `telemetry: app.telemetry`,
`clock: app.clock`, `now: app.now`, repositories from `app.repositories`.

| Screen | Model and wiring |
|---|---|
| Home | `app.home` (`HomeModel`, owned by the container; never make another) with `.inventoryQuery(app.home)`. Watch `app.router.searchFocus.focusRequests` and set `.searchable(isPresented:)` to true each time it goes up. Watch `router.reselections[.home]` and `home.scrollToTopRequests`. |
| Drop zone | `app.dropZone` (`DropZoneModel`, shared with the badge and the Home card). The shell already drives it with the tab shell's focus and the revision, so do **not** attach `.inventoryQuery` to it. |
| Lists with chips or steppers | `@State private var quantities: ItemRowQuantityModels?`, set once to `app.makeRowQuantityModels()` (§5.2: the current repositories, the database, the haptics and the "not saved" error toast). Call `keep(only:)` with the ids shown after each read. Dismiss the keyboard before a chip expands and scroll the expanded row into view (06 §5.8). |
| Scan tab | `ScanModel(permission: app.makeCameraPermission(purpose: .scan), qr: { app.repositories.qr }, haptics:, telemetry:, clock:, navigate:)`. Call `focusGained()`/`focusLost()` from `\.isScreenFocused`, and `tabReselected()` on `reselections[.scan]`. Draw `QrScannerView(model: scan.scanner, managesFocus: false) { CameraPanel(scan.panel) { … } }`. |
| Label link | `LabelLinkModel(token:qr:invalidator:toasts:confirm:haptics:rememberPlace:navigate:)`. Call `start()` on appear and register `close()` with `router.onRemoval(of: address)`. |
| Sticker link cover | Its own `QrScannerModel(title:permission:)` with the default `managesFocus: true`. Pass the changing title through `QrScannerView(title:)`, because `QrScannerModel.title` is a `let`. Overlay its own `CameraPanel`, also over the permission screen. |
| Capture | `CaptureModel(route:deliverPhoto:permission:photos:fastCapture:items:invalidator:toasts:haptics:…, navigate:)` with `deliverPhoto: { app.router.results.deliver(request, $0) }` when there is a request, `photos: app.imageStore` and `fastCapture: app.fastCapture`. `CaptureNavigation` maps to the router (see the file's comment). Wire `camera.reportEvents(to: model)` and register `disappeared()` with `onRemoval`. Attach `.captureLibraryPicker` once at the root, and pass `CameraPermissionView(isProcessing: model.processing)`. Stop the session when the screen loses focus, since the review is pushed over the live camera: `CameraPreview(camera:runs: isScreenFocused && …)`. |
| Quick Snap review | `QuickSnapReviewModel(route:items:photos:isPaired:invalidator:toasts:confirm:haptics:…, navigate:)`. Call `reload()` on appear, on focus gain and on revision change. `QuickSnapReviewNavigation` maps to the router (see the file). |
| Add sheet | Built: `AddSheet(params:)` makes `app.makeAddSheetModel(params:address:)` (every store wired, routing `AddSheetModel.Routing.router(_:address:)`: the camera for a result, Snap several and "Save and add another" with a photo replacing the sheet, `AddSheetRoutes`). Its own Cancel (`add-cancel`) calls `router.requestClose`, guarded by `.sheetCloseGuard { await model.confirmCancel() }`; the thumbnail shows `model.photoOptionsSheet()` with `app.platform.actionSheets`. `.interactiveDismissDisabled(model.interactiveDismissDisabled \|\| model.isPickingPlace)`. The place step swaps in `PlacePickerHost(mode: .choose, selectedContainerId:, showsDropZone: true) { model.pickPlace($0) }` (§5.1) with Back (`add-back`, `model.closePlaceStep()`). Demo states: `AddDemo` (`-demoArea add -demoState …`). |
| Move / file | `MoveModel(items:filing:request:routeResults: app.router.results, recentPlaces: app.recentPlaces, …, isFocused: { router.isFocused(address) }, close: { router.close(address) })`. Embed `PlacePickerHost(mode: move.pickerMode, currentContainerId:busyId: move.busyId) { notice } onPick: { place in Task { await move.pick(place) } }` (§5.1); it reads the lists and runs the inline create itself. |
| Edit forms | `DirtyGuard(confirm:title:dirty:saving:revoked:)`, plus `.sheetCloseGuard { await guard.attemptClose() }` and `.interactiveDismissDisabled(guard.interactiveDismissDisabled)`. |
| Item screen naming | `NameItModel(itemId:updatedAt:incomingName:items:invalidator:haptics:announce:onNamed:)`. `WhereCard(actionFocus:)` moves VoiceOver to "File it…". |
| Camera permission anywhere | `app.makeCameraPermission(purpose:)` (container telemetry, a fake platform in previews and tests). `CameraPermissionModel.device(purpose:)` is for galleries and tests. |
| Household, backup, onboarding | `app.household`, `app.connection`, `app.sync`, `app.onboarding`, `app.joinPreferences`, `app.unpairedNotice`, `app.makeHouseholdImporter(for:)`. |

### 1.8 Feedback

- **Toasts.** `app.toasts.show(ToastOptions(message:tone:action:duration:))`, with tone `.info`
  or `.error` and `ToastAction(label:accessibilityLabel:handler:)` for Undo. They show in the
  overlay window above every sheet. They are announced (queued), and live twice as long while
  VoiceOver runs. While a confirmation or action sheet from `app.platform` is up the toast steps
  aside (the overlay is above system alerts and would cover their buttons) and comes back after;
  its life keeps running. A stock `.confirmationDialog` or `.alert` needs
  `.tracksShellDialog(isPresented: flag)` (the flag it binds) for the same. Models take
  `toasts: app.toasts`.
- **Confirm.** `await app.platform.confirm.confirm(ConfirmOptions(title:body:confirmLabel:cancelLabel:destructive:))`
  returns true only for the confirm button. It shows as a system alert above every sheet.
- **Action sheet.** `app.platform.actionSheets.showActionSheet(ShellActionSheet(title:options: [.init(label:destructive:handler:)], cancelLabel:))`.
- **Haptics.** `HapticEvent`: `.step`, `.reachedZero`, `.choice`, `.undo`, `.success`,
  `.warning`, `.error`, `.tap`, `.longPress`. Use `@Environment(\.haptics)` in views and
  `haptics:` in models. Never play one on navigation, toasts or successful deletes (08 §7.2).
- **Announcements.** `.announcesOnChange(text, enabled:, queued:)` announces when the view
  appears and whenever `text` changes. `ComponentAnnouncer.announce(_:)` interrupts and
  `.announceQueued(_:)` waits for current speech. `app.platform.announce` and
  `\.shellAnnounce` post the same way but are silent in previews and tests. VoiceOver has no
  live regions, so whatever RN marked live is announced.

### 1.9 Previews, galleries, screenshots, tests

- **Previews.** `#Preview { ShellPreviewHost { NavigationStack { SpacesScreen() } } }` boots
  `AppContainer.preview()`: an in-memory database seeded with `AppContainerPreviewData`, no
  network and silent dialogs. `ShellPreviewHost(seed: false, onboardingCompleted: false)` covers
  the other states. A component that needs no container needs no host.
- **DEBUG launch arguments** (`App/Shell/ShellDemo.swift`; §5.3 has the details and the
  seeded names):
  - `-demo YES` runs the sample inventory in memory; add `-demoOnboarding YES` to start on
    onboarding, or `-demoSeed empty` to start with no inventory.
  - `-demoHousehold offline|revoked` shows the connection banner after 2.5 s, or the
    removed-phone layer.
  - `-demoArea <area> -demoState <state>`: your area's own hook (`<Area>Demo`).
  - `-demoTab spaces|scan|dropZone`.
  - `-demoRoute <spec>[><spec>…]` opens any route by the names in the inventory, e.g.
    `'container:Tool_chest>containerEdit:Tool_chest'` (quote a chain: `>` is a shell redirect).
    `-demoOpen settings|label|add|addOverSheet|capture|review|move` still works (mapped onto
    routes).
  - `-demoToast info|error|action`.
- **Galleries** (`App/Shared/DebugGallery.swift`): `-gallery components -galleryPage N` (0–17:
  tokens, item rows chip and tools, place rows, where card, quantity, banners, buttons, empty
  and error, inputs, pickers, three place-picker pages, space form, item details, thumbs, taps;
  long pages take `-galleryAnchor <section>`), `-gallery media -galleryPage N` (0–11:
  permission, scanner states, QR card, share picture, camera preview) and
  `-gallery foundation -galleryPage N` (0–7: `PlacePickerHost` in move, file, choose, bind, open,
  move busy with a notice, nothing at all, no match; a bar under the title shows the last
  pick, `foundation-picked`). Add a gallery for your area by adding a case to `DebugGallery`.
- **Screenshots.**
  - `scripts/mac.sh run out.png -demo YES` builds and launches; `mac.sh launch out.png …` only
    relaunches. Each launch argument reaches the app as given, so quote one with spaces or a `>`;
    `RUN_SETTLE_SECONDS=8` waits longer before the screenshot (default 4).
  - `mac.sh openurl inventory://c/<token> out.png` opens a link. On a running app, iOS 26 asks
    "Open in Inventory?" first.
  - Add `APPEARANCE=dark` and `CONTENT_SIZE=accessibility-extra-extra-extra-large` to check dark
    mode and the largest text.
  - Look at every screenshot with the Read tool.
- **Tests.**
  - `mac.sh test`: package logic, the place for screen-model tests.
  - `mac.sh apptest`: hosted SwiftUI and UIKit tests. `AppTests/Shell/ShellHostingSupport.swift`
    and `AppTests/Components/ComponentsHost.swift` host a view in a window.
  - `mac.sh uitest`: XCUITest in `UITests/`, launched with `-demo YES`. Find elements by the
    RN testIDs kept as accessibility identifiers.

## 2. Shared components

All are in the app target (module `Inventory`). Logic and copy behind them live in
`InventoryAppModels/Components` (`ItemRowText`, `PlaceRowText`, `FeedbackText`, `CodeFieldText`,
`TextFieldCopy`, `QuantityStepperCopy`, `WhereCardCopy`, `SpacePalette`, `TileSpread`,
`ThumbnailLoader`, `ItemRowQuantityModels`).

### Design (`App/Design`)

| API | Purpose |
|---|---|
| `Color(spaceHex: String?)` | A stored space colour through `safeColor`; junk draws grey. |
| `Color(.tape)`, `Color(.tapeInk)`, `Color(.searchMark)`, `Color(.pipRing)`, `Color.accentColor` (ink) | Asset colours. Tape only where yellow carries meaning (U2), never as a text or control tint. |
| `DesignColor.signal`, `.signalWash` | Errors and "None left" (system red), and the warning banner's wash. |
| `DesignMetrics` | `contentMaxWidth` 640, `narrowWidth` 360, `minTouchTarget` 44, `thumbSmall/thumb/thumbPhoto/thumbDetail` 48/56/76/88, `thumbRadius`, `cardRadius`, tile sizes. |
| `SpaceTileSurface` `.cell/.page/.plain` | The opaque surface a space tile is mixed onto. |
| `.readableContentWidth()` | The 640 pt centred column. |
| `Glyph` (`.systemName`, `Glyph.container(_:)`), `Image(glyph:)`, `Label(_:glyph:)` | The RN icon names as SF Symbols. |
| `.textRole(_ role: TextRole, header: Bool? = nil)` | RN type scale on Dynamic Type: `display, title, whereCard, itemTitle, heading, code, name, where, body, section, label, meta, aside, caption, factLabel, badge, tapeS/M/L, stepper, stepperL`. Headings get the header trait. Fixed-geometry roles are capped. |
| `LayoutScale()` (a `DynamicProperty`: `isStacked`, `isNarrow`; `static isStacked(dynamicTypeSize:windowWidth:)`) | Stack at `.xxxLarge` and up or below 360 pt. Use it as `private let layout = LayoutScale()`. |
| `.measuresLayoutWindowWidth()` | Sets `\.layoutWindowWidth` from this view's width. Only for roots outside `RootView` (galleries). |
| `AdaptiveStack(horizontalAlignment:verticalAlignment:spacing:forceStacked:) { }` | An HStack that becomes a VStack when `LayoutScale` says so. |
| `WrappingHStack(horizontalSpacing: 6, verticalSpacing: 2, alignment: .center)` | A wrapping row (`Layout`): the location line, chips. |
| `.accessibilityIdentifierIfPresent(_:)`, `.accessibilityLabelIfPresent(_:)`, `.accessibilityHintIfPresent(_:)` | Optional accessibility modifiers. |
| `.announcesOnChange(_ text:, enabled: = true, queued: = false)`, `ComponentAnnouncer.announce(_:)` / `.announceQueued(_:)` | The one way announcements are posted. |

### Primitives

| Init | Purpose |
|---|---|
| `Tape(code:size: = .small, spoken: = false)`; sizes `.small/.medium/.large/.badge` | Yellow label tape with the code as stored, never truncated. `spoken` reads it letter by letter. |
| `BrandMark(size: = .regular)`; `.regular` 52×46, `.large` 72×64 | The household mark (boot, the removed-phone layer). Decorative. |
| `SpacePip(color:size: = 12)` | The colour dot before a space name. |
| `SpaceTile(icon:color:size: = 56, surface: = .cell)` | A space's emoji on a 24 % tint. Sizes 32/48/56/64. |
| `TypeTile(type:size: = 48, glyph: = nil)` | A container type's symbol. Sizes 40/48/72. |
| `HighlightedText(text:terms:)` | Text with search matches on `SearchMark`. |
| `Thumb(uri:size: = 56, action: = nil, accessibilityLabel: = nil, identifier: = nil)` | A photo decoded off the main actor at the drawn size and cached (cleared on memory warnings). Pass `photoThumbUri ?? photoUri`. With `action` it becomes a labelled button. |

### Buttons and feedback

| Init | Purpose |
|---|---|
| `LoadingButton(label:glyph:variant: = .primary, size: = .regular, isLoading:isDisabled:fullWidth:accessibilityLabel:accessibilityHint:identifier:action:)` | The app's button. Busy keeps its label, ignores presses, shows a spinner after 150 ms and reads "Loading…". `ButtonVariant` is `.primary` (filled ink, the only filled control on a screen), `.secondary`, `.quiet` or `.destructive`; `ButtonSize` is `.regular` or `.small`. |
| `.buttonVariant(_:size:)` | A variant's stock style on any `Button`. For `.primary`, prefer `LoadingButton`: a bare `.borderedProminent` label is unreadable on the light ink in dark mode. |
| `BannerView(tone:glyph:title:message:primary:secondary:onDismiss:live: = .polite, chrome: = .card, identifier:)`; `BannerAction(label:accessibilityHint:isLoading:identifier:action:)` | An inline notice. `tone` is `.info` or `.warning`, `chrome` is `.card` or `.row`, and `live: .off` keeps it from being announced. |
| `SuggestionBannerView(state:onRetry:onRefresh:chrome:)` | The photo-suggestion banner from `AddSheetModel.suggestionBanner`. |
| `SaveNotice(copy: SaveNoticeCopy, action:identifier:)` | A failed save in plain words, announced at once. |
| `EmptyStateView(title:message:glyph:primary:secondary:identifier:)`; `StateAction(label:glyph:isLoading:identifier:action:)` | An empty list and the next step. |
| `ErrorStateView(cause: ErrorStateView.Cause?, context: = .read, subject: = .list, title: = nil, body: = nil, onRetry: = nil, secondary: StateAction? = nil, identifier: = nil)` | A failed read with Try again (`error-retry`) and an optional quiet second button (`error-secondary` unless the action has an id). `Cause` is `.failed(error)` or `.gone`; nil means the screen gives both texts (the boot gate). The heading is announced. |
| `SkeletonView(variant: = .rows, rows: = 6, thumb: = 56, label: = "Loading…")`; variants `.rows/.list/.options/.detail/.grid` | The shape of what loads, after 180 ms. Static, one VoiceOver element. |
| `DropZoneLocked(onGoToDropZone:)` | The answer to a stale link to the drop zone's forms. |
| `ConnectionBanner(state:retry:)` (`App/Shell`) | "Reconnecting…" while `offline`: a warning `BannerView`, never announced, its text capped at AX1 because it is pinned. `ScreenFrame` draws it, so screens do not. |
| `SearchButton(identifier: = "search-button")` (`App/Shell`) | The toolbar search button: Home with the keyboard up. |

### Rows

| Init | Purpose |
|---|---|
| `ListRow(action:showsChevron:isSelected:isDisabled:minHeight: = 44, alignment:accessibilityLabel:accessibilityHint:identifier:) { leading } content: { } aside: { }` (an init without `aside:` too) | The base row: a plain `Button` in a `List`, so the list draws the highlight. `isDisabled` draws undimmed and reads as a dimmed button. A pressable row needs `accessibilityLabel`. |
| `RowWithTool { row } tool: { control }` | A row and its control as siblings (their own VoiceOver stops; a tap on the control never opens the row). It stacks at large sizes; stacked, the whole line under the row is inert, so a tap beside the control does nothing (the chip row's stacked line too). |
| `.absorbsListRowTaps()` | Stops taps on the blank parts of a control area from opening the row. |
| `ItemRow(item:line: = .where, tool: = .none, terms:now:thumb: = 56, identifier:onPress:)` | An item: name over "where is it". `ItemRowLine` is `.where`, `.detail` or `.added`. `Tool` is `.chip(model, isExpanded:onToggle:)` (or the helper `.chip(model, itemId:expandedId: Binding<String?>)`), `.stepper(model)`, `.file { }`, `.delete { }` or `.none`. It keeps its model in step with the item. |
| `SpaceRow(space:tileSize: = 56, terms:onPress:)` | A space with its counts. |
| `ContainerRow(container: ContainerRowData, context: = .space, terms:onPress:)` | A container with its tape. The `.search` context adds its location and contents. |
| `PlaceRow(hit:spaces:containers:terms:onPress:)` | A search hit drawn as a space or container row. |
| `LocationLine(place: some PlaceLike, size: = .row, showsContainer: = true, onCamera: = false, links: = nil)`; sizes `.row/.card/.inline`; `LocationLine.Links(openSpace:openContainer:)` | "Space › Container" with its tape. The only way a location is drawn. |
| `WhereCard(place:name:links: = nil, actionFocus: AccessibilityFocusState<Bool>.Binding? = nil, onMove:)` | The item screen's "Kept in" card with Move or "File it…". |
| `SettingsRow(label:value:tone: = .normal, glyph:identifier:)` | A settings line. Put it in a `NavigationLink` or a `DisclosureGroup` label. |
| `FactRow(label:) { content }`, `FactRow(label:text:)`, `FactRow(label:selectableText:)` | A labelled fact on the item screen. |

### Quantity

| Init | Purpose |
|---|---|
| `QuantityStepper(value:onChange:size: = .large, itemName:error:isDisabled:identifierSuffix:commitWhileTyping: = false)`; sizes `.compact` (48 pt) / `.large` (56 pt) | Minus, number, plus: tap, hold-repeat, typed entry, haptics. VoiceOver adjusts it, and a double tap types. Free of I/O. |
| `SavedQuantityStepper(model: SavedQuantityModel, itemName:size: = .large, identifierSuffix:)` | Writes through with no Save, and shows "None left right now". |
| `QuantityChip(quantity:itemName:itemId:isExpanded:onToggle:)` | The "×3" chip that opens the stepper under a row. |

### Inputs and pickers

| Init | Purpose |
|---|---|
| `LabeledTextField(label:text:placeholder:error:hint:isRequired:isOptional:isMultiline:grows:counter:accessibilityLabel:input:chrome: = .formRow, identifier:focus:field:)` (without `focus:field:` outside a focus chain; the full memberwise init adds `trailing:`) | A labelled field. The error replaces the hint and is announced (queued). `chrome` is `.formRow` or `.boxed`. |
| `LabeledFieldInput(maxLength:submitLabel:onSubmit:capitalization:disablesAutocorrection:keyboard:)` | Keyboard behaviour for a field. |
| `FieldMessage(text:)` | The red warning line under a field. |
| `CodeInput(label:value:length:hint:error:identifier:onSubmit:)` | A household or recovery code: grouped, normalised, and Return submits. |
| `ItemDetailsFields(values: Binding<ItemFormValues>, suggestions:focus: FocusState<ItemDetailsField?>.Binding)` | Category (with recent-category chips), Tags and Notes. |
| `SpaceFields(values:nameError:onSubmit:previewMeta:previewFallbackName:focus:)` | Space name, icon and colour, with a live row preview. |
| `FormLayout(contentIdentifier: = nil) { notice } content: { }` and `FormLayout { notice } content: { } bottomBar: { }` | A form with a notice inset above it (see 1.4 for the bar). `contentIdentifier` puts the screen's `screen-*` identifier on the form alone (§4). |
| `TagChip(label:isSelected:identifier:action:)` | A tag pill. It is tappable with an action. |
| `ChoiceList(options: [ChoiceOption], selection:accessibilityLabel:)`; `ChoiceOption(value:title:subtitle:leading:identifier:)` | A short single choice with checkmarks. |
| `SegmentedChoice(options: [SegmentOption], selection:accessibilityLabel:onCamera:isDisabled:accessibilityHint:)`; `SegmentOption(value:label:glyph:identifier:)` | A stock segmented picker, on glass over the camera. It drops option glyphs. |
| `EmojiPicker(label:value:color:options:)`, `SwatchPicker(label:value:palette:)`, `TypeGrid(label:value:)` | Space icon, space colour and container type. They play `.choice`. |
| `SpreadGrid(tileWidth:minGap:rowGap:maxColumns:)` | Fixed tiles spread edge to edge (`Layout`). |
| `PlacePicker(mode:options:spaces:recentIds:isLoading:failure:onRetry:currentContainerId:selectedContainerId:showsDropZone:allowsNewContainer:autoFocusesFilter:placeholder:initialQuery:busyId:notice:onPick:onNewContainer:onNewSpace:filterText:handlesPickFeedback:)` (`notice:` optional; an optional view that is nil adds no section) | The drawing of the one place picker. **Screens embed `PlacePickerHost` instead** (§5.1), which reads, opens the forms and drives this view (`filterText:` binds its model's query, `handlesPickFeedback: false` leaves the haptic and the busy guard to the model). Present it inside a `NavigationStack` (it uses `.searchable`; the stock field takes no identifier, so UI tests use `app.searchFields.firstMatch`). |

## 3. Media views (`App/Media`)

| API | Purpose |
|---|---|
| `CameraController(use: CameraUse, discover: = CameraDiscovery.backCamera)`; `CameraUse` `.photo/.qrCodes` | One capture session per screen, kept for the screen's life. It exposes `onEvent`, `onCodes`, `lastEvent` and `isRunning`, plus `setRunning(_:)`, `setTorch(_:)`, `focus(atLayerPoint:)`, `capturePhoto(flashOn:) async throws -> CapturedPhoto?` (throws `CameraCaptureError.notRunning/.busy`), `deliverEvents(to:)` and `reportEvents(to: CaptureModel)` (both replay the last event), and `static cropAspect(previewSize:previewAngle:captureAngle:)`. Pass `discover: { nil }` in galleries. |
| `CameraPreview(camera:runs: = true, focus: TapToFocusModel? = nil)` | The live picture. It runs while shown, `runs` is true and the scene is not in the background. With `focus`, a tap focuses and draws the square. Decorative chrome on top must use `.allowsHitTesting(false)`. |
| `CameraPreviewLayerView(camera:)`, `CameraTapToFocusLayer(focus:onFocus:)`, `CameraFocusSquare()`, `CameraPreviewUIView` | The parts `CameraPreview` is built from. |
| `CameraPermissionView(model:isPaired: = false, onLibrary:onManual:onCancel:closeIdentifier: = "camera-close", isProcessing: = false)` | The one permission screen (rationale or Settings), with the ways on without the camera. It re-reads on activation. |
| `CameraPermissionModel.device(purpose:telemetry:)`, `CameraAuthorizationAccess` | The AVFoundation permission. Screens use `app.makeCameraPermission(purpose:)`. |
| `QrScannerView(model:title:onManual:onClose:closeIdentifier:torchIdentifier: = "scanner-torch", managesFocus: = true, makeFeed:) { footer }` (a no-footer init too) | Camera, reticle, torch and title pill, the permission screen, and the failure panel. It reports focus to the model unless `managesFocus: false`. |
| `QrScannerFeed`, `QrScannerBridge(model:feed:)`, `StandInQrScannerFeed()` | The feed seam. The stand-in draws a fake scene for galleries and tests. |
| `CameraGlassIconButton(systemImage:label:isSelected: = nil, identifier:action:)` | A round 48 pt glass button. A toggle that is on turns tape yellow and reads as selected. |
| `CameraTitlePill(text:systemImage:updatesFrequently: = false, identifier:announces: = false)` | White text on a glass capsule (RN `StatusPill`): the scanner title or the running count. Capped at AX1. `announces` reads each new text (queued). |
| `ScannerReticle(isLocked:)` | The four corner brackets. Tape yellow once a code locks. |
| `CameraPanel(tone:title:message:actions:)`, `CameraPanel(_ panel: ScanPanel, perform:)`; `CameraPanelAction(id:label:systemImage:perform:)` | A notice over the picture: hint, busy or error (the coral edge). Busy and error notices are announced. Scan ids are `scan-again`, `scan-try-again` and `scan-type-code`. |
| `MediaPalette` | Camera-only colours: `tape`, `errorBar`, `reticle`, `glassTint`, `qrInk`, `qrPaper`. |
| `.captureLibraryPicker(isPresented:onFinish:)`; `CaptureLibraryPickGate`, `CaptureLibraryFile` | The photo library picker. Attach it once at the capture screen's root. It answers each presentation exactly once (`.picked`, `.cancelled` or `.failed`). |
| `QrCodeRenderer.modules(for:) -> CGImage?`; `QrCodeImage(payload:side:quietZone:)` | A QR symbol (error correction M, margin trimmed) drawn crisp. |
| `QrLabelCard(token:name:shortCode:)` | The printed label: QR, name and tape, black on white in both schemes, one spoken image (`qr-card`). |
| `QrLabelShareLink(token:name:shortCode:)` | "Share label…" with the 1024 px picture (`qr-share`). Apply `.disabled(busy)` while the screen works. |
| `QrLabelPicture.render(payload:cardSize:)`, `.pngData(payload:cardSize:)`, `.write(payload:shortCode:cardSize:in:) throws -> URL` | The 1024 px share picture; `write` saves `label-<code>.png` (temporary directory by default). |

Capture chrome that does not exist yet and belongs to the capture screen: the Into pill, the
shutter and its flash, the mode picker, Done, the last-shot tile and the camera notice (warning
icon, error bar, "Type it instead"). Build them from `CameraGlassIconButton`, `CameraTitlePill`,
`CameraPanel` and `SegmentedChoice(onCamera: true)`.

## 4. Rules that are easy to miss

- One copy of each concept. Before adding a view, search `App/Components`, `App/Media`,
  `App/Shell` and `App/Screens/Shared`.
- Copy comes from `L10n` (`InventoryStrings`). Never pass an error's message to the screen; use
  `describeError` through `ErrorStateView` or `SaveNoticeCopy`. Copy RN never had goes in your
  area's `scripts/strings/native/<area>.ts` (§5.4).
- Keep RN's testIDs as accessibility identifiers. The UI tests depend on `screen-*`, the `tab-*`
  identifiers, `sheet-close` and others.
- Where the `screen-*` identifier goes matters. Around a whole `ScreenFrame` it replaces the
  identifiers of everything outside the list: the bottom bar's buttons (`item-save` read as
  `screen-add`) and a `FormLayout` notice. Applied to a `Group` of sections it replaces the rows'.
  Put it on the list itself: `FormLayout(contentIdentifier:)`, or the `List`/`PlacePickerHost`.
- Never use `onDisappear` for "this screen is gone"; use `router.onRemoval(of:)`.
- A screen under a sheet is unfocused. Stop cameras, scanners and timers there.
- `EmptyStateView` and `ErrorStateView` are `ContentUnavailableView`s and do not scroll. Put
  them in a `List` or `ScrollView` so their text and buttons stay reachable at AX5. As a `List`
  row a long heading can be cut to one line at default sizes ("Your inventory could not…");
  where the state fills the screen, prefer `GeometryReader { p in ScrollView { state.frame(maxWidth:
  .infinity, minHeight: p.size.height) }.scrollBounceBehavior(.basedOnSize) }` (centred while it
  fits, as `PlacePicker`'s failure state), and check the heading in a screenshot.
- Simulator caveats: colour emoji draw as "?" boxes on the build Mac's simulator, and the camera
  is unavailable (galleries use `discover: { nil }` or `StandInQrScannerFeed`).
- Check every screen in light and dark mode, at AX5 and on a 360 pt-wide window. The iPad
  layout is untested so far.

## 5. Screen foundation

What the screen wave builds on beyond the shell: the place picker every picking screen embeds,
the row quantity factory, the DEBUG demo routes and hooks, and the native-only copy source.

### 5.1 `PlacePickerHost` (`App/Screens/Shared/PlacePickerHost.swift`)

The one view a screen embeds to pick a place (RN `<PlacePicker>`, 07 §4.1): Move and File, the
Add sheet's place step, the label bind and the Scan tab's typed code. Present it inside a
`NavigationStack`; its filter is the stock search field in the navigation bar.

```swift
PlacePickerHost(
    mode: PlacePickerMode,                 // .move, .file, .choose, .bind, .open
    currentContainerId: String? = nil,     // move/file: "Here now", not pickable
    selectedContainerId: String? = nil,    // choose: checked (the drop zone when nil)
    showsDropZone: Bool = false,           // choose: "Drop zone · Sort it later" first
    allowsNewContainer: Bool? = nil,       // nil: everywhere but .open
    busyId: String? = nil,                 // the row saving the pick; the list is locked
    placeholder: String = L10n.Picker.filter,
    initialQuery: String = "",
    autoFocusesFilter: Bool? = nil,        // nil: only .open
    @ViewBuilder notice: () -> Notice,     // optional (an init without it); `if let` works
    onPick: @escaping (PickedPlace) -> Void
)

// Move / File:
PlacePickerHost(mode: move.pickerMode, currentContainerId: item.containerId, busyId: move.busyId) {
    if let notice = move.notice { BannerView(tone: .warning, message: notice.message) }
} onPick: { place in
    Task { await move.pick(place) }
}
```

- It builds one `PlacePickerModel` for the screen's life from `app.repositories` and
  `app.recentPlaces` (the recent places as the screen first saw them), and drives its two
  reads (`containers-all`, `spaces`) from `\.isScreenFocused` and `app.database.revision`. A
  form opened over the picker unfocuses it; it reads again when the form closes.
- `onPick` runs after the `.choice` haptic and never while `busyId` is set; the host always
  calls the newest closure it was given. Saving, the busy row, the notice and closing are the
  screen's (`MoveModel.pick`, `AddSheetModel.pickPlace`, the label bind, the Scan tab's open).
- "New container in <space>…" opens `.sheet(.containerNew(spaceId:request:))` with
  `router.presentForResult(NewContainerResult.self)` and hands the container it made to
  `onPick` without a re-read or haptic. So **`ContainerNewSheet` must deliver**
  `app.router.results.deliver(request, NewContainerResult(container))` when it has a request,
  and close itself in the same step (it opens the container itself when `deliver` returns
  false). One form at a time; a form closed without an answer picks nothing.
- No containers at all: the empty state's action (`move-no-containers`) opens
  `.sheet(.spaceNew(request:))` for a `NewSpaceResult` (**`SpaceNewSheet` delivers** likewise),
  then the container form in that space, and picks the result. Where no "New container" is
  offered (`.open`) it presents `.spaceNew(request: nil)` and waits for nothing.
- Loading, failure and empty follow 07 §4.1: the skeleton while either list has no data and is
  loading; `ErrorStateView` with Try again (both lists) when the containers failed with no
  data or the spaces have no data and failed; "Nothing matches “q”" above the lists.
- Identifiers (RN testIDs): `place-drop-zone`, `move-to-<containerId>`,
  `place-recent-<containerId>`, `place-new-container-<spaceId>`, `move-no-containers`. The
  filter takes no identifier (the stock field cannot): UI tests use `app.searchFields.firstMatch`.
- The logic is `PlacePickerModel` (`InventoryAppModels/Entities/Places/PlacePickerModel.swift`):
  inputs `mode`, `allowsNewContainer` (fixed), and `currentContainerId`, `selectedContainerId`,
  `showsDropZone`, `busyId`, `query` (settable); outputs `options`, `sections`,
  `noMatchMessage`, `isLoading`, `failure`, `isNothingAtAll`, `isBusy`, `recentIds`, and the
  two queries `containers` and `spaces`; actions `pick(_:)`, `newContainer(in:spaceName:) async`,
  `newSpace() async`, `retry()`, `focusChanged(_:revision:)`, `revisionChanged(_:)`.
  `PlacePickerHost.makeModel(app:mode:…:onPick:)` builds it with the host's wiring (tests use
  it); `PlacePickerHost.forms(router:)` is the router side (`PlacePickerModel.Forms`).
- Look at it with `-gallery foundation -galleryPage 0…7` (§1.9).

### 5.2 The row quantity factory

`app.makeRowQuantityModels() -> ItemRowQuantityModels` (an `AppContainer` extension in
`Composition/AppContainer+RowQuantity.swift`): one per list screen, kept in `@State` (or the
screen's model). Each row's `SavedQuantityModel` writes through `app.repositories.items` with
`app.database` as the invalidator and the platform's haptics, and a quantity that did not save
shows the error toast "The quantity of “Wood screws” was not saved. …"
(`SavedQuantityModel.notSavedMessage(itemName:kind:)`), as RN's `ItemRow` and
`SavedQuantityStepper` did. Hand rows `.chip(quantities.model(for: item), itemId:expandedId:)`
or `.stepper(quantities.model(for: item))`, and call `quantities.keep(only: ids)` after each
read. The toast names the item as its row last asked for its model
(`ItemRowQuantityModels.latestName(of:)`), so a rename made meanwhile is respected.

### 5.3 DEBUG demo: routes, seed and area hooks (`App/Shell/ShellDemo.swift`)

Every state can be reached from launch arguments, so screenshots and UI tests need no taps:
`scripts/mac.sh run out.png -demo YES -demoRoute move:Cordless_drill`. The order is `-demoTab`,
then the area hook's `run`, then `-demoRoute`, then `-demoToast`.

**`-demoRoute <spec>[><spec>…]`** opens routes in order, 0.7 s apart. A spec is `name` or
`name:argument`. Names match case-insensitively, the first match wins, and `_` stands for a
space, so a spec needs no quotes for its spaces; a quoted argument may hold real spaces. **Quote
a chain** for `mac.sh` (`-demoRoute 'item:Cordless_drill>itemEdit:Cordless_drill'`): unquoted,
the shell takes `>` as a redirect and the app gets only the first spec. A spec naming nothing
known is logged (category `demo`) and skipped; the rest still open. Only a spec that names
something reads the inventory first (through the household when joined); `add`, `settings` and
the like open at once. A chain takes a few seconds after launch: give screenshots
`RUN_SETTLE_SECONDS=8`.

| Spec | Opens |
|---|---|
| `settings`, `privacy`, `household`, `backup` | that screen, pushed on the selected tab |
| `label[:<token>]` | the label screen; no token: the unbound one below |
| `space:<name>`, `container:<name or code>`, `qrLabel:<container>` | pushed (`container:Drop_zone` goes to its tab) |
| `item:<name>`, `itemFiling:<name>` | the item screen (filing: as opened from the drop zone) |
| `add[:<container>]` | the Add sheet (into that container) |
| `spaceNew`, `spaceEdit:<space>`, `containerNew:<space>`, `containerEdit:<container>`, `itemEdit:<item>` | that sheet |
| `move:<item>`, `file:<item>` | the Move or File sheet |
| `capture[:<container>]` | the single-photo camera (the drop zone by default) |
| `quickSnap`, `review` | Quick Snap; the review pushed over it |
| `photo:<item>`, `linkSticker:<container>` | that cover |

`item:` with no argument (also `move:`, `photo:`, …) names the unnamed Quick Snap shot.
Examples: `'container:Tool_chest>containerEdit:Tool_chest'`, `'add>containerNew:Garage'`,
`'item:Cordless_drill>itemEdit:Cordless_drill'`, `container:CAB-J92R` (by code), `review`. `-demoOpen` maps onto specs:
`settings`, `label`, `add`, `addOverSheet` = `add>containerNew:Garage`, `capture` = `quickSnap`,
`review`, `move` = `file:HDMI_cable`.

**`-demoSeed empty`** starts with no inventory (onboarding done). `-demoOnboarding YES` starts
on onboarding; `-demoHousehold offline|revoked` joins a household that is unreachable or
answers 401.

**`-demoArea <area> -demoState <state>`**: each area has `App/Screens/<Area>/<Area>Demo.swift`
(home, account, labels, places, item, add, capture) with two hooks it fills in itself; nobody
edits `ShellDemo.swift` for them:

```swift
enum AccountDemo {
    /// The container for `state`, or nil for the default demo container (seeded, or empty with
    /// -demoSeed empty). Build it with AppContainer.preview(platform: platform, …).
    @MainActor static func container(state: String, platform: AppPlatform) -> AppContainer?
    /// Once the main shell shows, after -demoTab and before -demoRoute.
    @MainActor static func run(state: String, app: AppContainer) async
}
```

For example a paired household answering from a fake transport, backup states (on, failing,
the keychain unreadable, the Restore offer), or a seeded Quick Snap review.

**The seeded inventory** (`AppContainerPreviewData`, behind `-demo YES`, `ShellPreviewHost` and
`AppContainer.preview()`). Short codes and the label are fixed; ids are random.

| Space | Container (type, code) | Items (quantity 1 unless shown) |
|---|---|---|
| Garage 🧰 `#5B8DEF` | Tool chest (cabinet, `CAB-J92R`, QR label) | Cordless drill (Tools, photo, notes, tag "power tools"), Screwdriver set (Tools) |
| | Red bin (bin, `BIN-4F2A`) | Extension cord ×2 |
| | unnamed, "Unnamed box" (box, `BOX-7K2M`) | Christmas lights (Decorations) ×3 |
| Kitchen 🍳 `#E07A5F` | Pantry shelf (shelf, `SHF-3PQX`) | Olive oil (Food, photo) ×2 |
| | Top drawer (drawer, `DRW-8HNC`) | AA batteries (Batteries) ×12, Printer ink ×0 (none left) |
| Attic 📦 `#81B29A` | Winter clothes (bag, `BAG-5WTD`) | Wool scarf (Clothes) |
| Drop zone | | HDMI cable ×2, Spare keys, Bike pump (photo), an unnamed Quick Snap shot (photo) |

Label tokens: the Tool chest's is `AppContainerPreviewData.toolChestLabelToken`
(`c0ffee00c0ffee00c0ffee00c0ffee00`: `label:c0ffee00c0ffee00c0ffee00c0ffee00`, or
`mac.sh openurl inventory://c/c0ffee00c0ffee00c0ffee00c0ffee00`);
`AppContainerPreviewData.unboundLabelToken` (`0123456789abcdef0123456789abcdef`) is bound to
nothing. Recent places start empty.

### 5.4 Native-only copy (`scripts/strings/native/<area>.ts`)

Copy RN never had goes in your area's own file, shaped like `strings.ts` and merged into the
same tree: `native/account.ts`'s `backup.unreadable.title` is `L10n.Backup.Unreadable.title`.
Run `node native-ios/scripts/strings/generate.mjs` and commit the outputs; the generator fails
on a key that already exists in `strings.ts` or another area's file, and on a file not named
after an area. No booleans in native functions: one key per branch, chosen in Swift. Details
in `scripts/strings/README.md`.

Already there for the Backup screen (account area), from `SyncModel`'s outcomes (03 B8, B12):

| Key | When |
|---|---|
| `L10n.Backup.Unreadable.title`, `.body`, `.retryHint` | `sync.isAccountUnreadable`: hide Turn on and Restore; Try again (`L10n.Common.tryAgain`) calls `await sync.retryAccountLoad()` |
| `L10n.Backup.RestoreOffer.title`, `.body`, `.action`, `.actionHint` | `sync.suggestsRestore`: the neutral Restore offer (it also reads right for a new user whose only backup is of an empty inventory). The action replaces this phone's inventory, which may no longer be empty (`suggestsRestore` stays until a backup is stored), so confirm first exactly as RN's Restore… did (`L10n.Backup.restoreConfirmTitle`, `.restoreConfirmBody`, destructive `.restoreConfirm`), then `await sync.restoreFromAccount()`; success is the `L10n.Backup.restored` toast with the success haptic |
| `L10n.Backup.RestoreOffer.working` | the status line while `restoreFromAccount()` runs (the status is `.working`, whose own line says "Backing up…") |
| `L10n.Backup.RestoreOffer.failedTitle` | `restoreFromAccount()` failed: the banner title over `BackupFailureReason.message` |
| `L10n.Backup.keptExistingCode` | `enable()` returned `.backupHeldBack`: the code revealed is the one already on this phone |
| `L10n.Backup.accountAlreadyOnThisPhone` | `restoreFromCode(_:)` returned `.accountAlreadyOnThisPhone` |
| `L10n.Backup.restoredCodeNotKept` | `restoreFromCode(_:)` returned `.restored` but `sync.account` is nil (the keychain refused the code) |
