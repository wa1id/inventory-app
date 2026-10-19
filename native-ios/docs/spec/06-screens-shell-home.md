# 06 — Navigation shell, tabs, Home, Spaces, Scan, Drop zone, Onboarding, Settings

Porting spec for the native iOS app (Swift 6, SwiftUI, iOS 26+, same bundle id
`com.wystudio.inventory`). Source of truth: the Expo / React Native app at the
repo root. Every behaviour below cites `path:line` in that app.

Conventions used in this document:

- **Copy** is referenced by key in `src/i18n/strings.ts` (for example
  `strings.tabs.home`). Functions in that file (for example
  `strings.home.summary(s, c, i)`) must be ported with identical output. They
  rely on `plural` and `sentenceList` from `src/i18n/format.ts:10-18`: "1 item",
  "2 items"; "a", "a and b", "a, b and c" (no serial comma).
- **"Native:"** paragraphs give the recommended SwiftUI or system replacement
  under the fully native look decision: system fonts, stock controls, Liquid
  Glass, brand accent colour only. Styling in the RN code (plaster, sheets, 1 pt
  rules, paddings) is deliberately not specified.
- **Timing constants** come from `src/ui/motion.ts:11-37`:
  `duration = { press 100, toastIn 160, toastOut 120, expand 180, stepSwap 180, reticleLock 250, focusSpot 700, shutterFlash 120 }` ms (all become 0 with Reduce Motion);
  `delay = { skeleton 180, spinner 150, bootCaption 400, reconnect 2500, searchDebounce 200, searchSkeleton 600, toast 5000, toastWithAction 9000, stepRepeat 400, stepRepeatEvery 80 }` ms (unaffected by Reduce Motion).
- System record ids (`src/db/constants.ts:26-27`): `DROP_ZONE_CONTAINER_ID = "drop-zone"`,
  `DROP_ZONE_SPACE_ID = "drop-zone-space"`.

Scope covered: `app/_layout.tsx` (shell), `app/(tabs)/*`, `app/onboarding.tsx`,
`app/settings.tsx`, `app/privacy.tsx`, `app/c/[token].tsx`, the Add sheet logic
(`src/ui/add/**`, plus how `app/item/new.tsx` uses it), the providers
`OnboardingProvider`, `DropZoneProvider`, `ToastProvider`, the shared list and
state components, navigation helpers and the UI-side hooks listed in the task.

---

## 1. Recommended native architecture (summary)

```
@main InventoryApp
 └─ WindowGroup → RootView                         (§2 boot gate)
     ├─ BootFailedView / BootView
     ├─ OnboardingView                             (§11) when onboarding == .pending
     └─ MainShell                                  when onboarding == .completed
         TabView(selection: $router.tab)            (§4)
           Home      → NavigationStack(path: $router.paths[.home])     (§5)
           Spaces    → NavigationStack(path: $router.paths[.spaces])   (§6)
           [Add]     → action, not a destination                       (§4.3)
           Scan      → NavigationStack(path: $router.paths[.scan])     (§8)
           Drop zone → NavigationStack(path: $router.paths[.dropZone]) (§7)
         .sheet(item: $router.sheet)                (modal routes, §3.1)
         .fullScreenCover(item: $router.cover)      (camera, photo viewer, sticker link)
         .onOpenURL(perform: router.open)           (§3.6)
 └─ ToastWindow: passthrough UIWindow above all sheets (§14), also hosts the
    removed-phone layer owned by the household area.
```

- `Router` is a `@MainActor @Observable` class that owns the selected tab, one
  `[Route]` path per tab, the presented sheet and cover, the pending
  search-focus request (§3.5) and pending results (§3.4). It replaces
  `src/ui/navigation.ts`, `src/ui/routeResult.ts`, `src/ui/searchFocus.ts` and
  expo-router's stack.
- **Structural difference to decide (Open question Q2).** In RN every pushed
  screen (settings, space, container, item, `/c/<token>`…) is pushed on the
  **root** stack *over* the tab shell, so the tab bar is hidden on every
  pushed screen (`app/_layout.tsx:163-213`, tabs have no nested stacks:
  `app/(tabs)/_layout.tsx:20-32`). Idiomatic iOS keeps one `NavigationStack` per
  tab and the tab bar stays visible. This spec assumes per-tab stacks and calls
  out each place where that changes behaviour.

---

## 2. Boot and root gating

Source: `app/_layout.tsx:104-249`.

Provider nesting, outermost first (`app/_layout.tsx:223-249`): SafeArea →
Font → Database → Household → Connection → Sync → Onboarding → RootNavigator.
Connection sits above Sync so both share one connection state
(`app/_layout.tsx:230`); Sync is above the readiness gate so it is not
restarted by gate re-renders (`app/_layout.tsx:232-237`).

Root states, evaluated in this order:

| # | Condition | Shows | Source |
|---|---|---|---|
| 1 | database `state.status == "error"` | Full-screen error: title `strings.boot.failedTitle`, body `strings.boot.failedBody`, "Try again" button calls the database provider's `retry` | `app/_layout.tsx:142-152` |
| 2 | database loading **or** onboarding status `loading` **or** household session not yet read from secure storage (`!household.ready`) | Boot screen | `app/_layout.tsx:154-156` |
| 3 | otherwise | Navigation, gated by onboarding status | `app/_layout.tsx:158-220` |

Boot screen (`src/ui/components/BootScreen.tsx:15-31`): the app mark (52 pt)
and, only after 400 ms (`delay.bootCaption`), the caption
`strings.boot.opening` in a polite live region. The caption's line is
reserved so the mark does not move.

Onboarding gate (`app/_layout.tsx:165-213`): while status is `completed`, all
app routes exist and `onboarding` does not; while `pending`, only `onboarding`
exists (no header, swipe-back disabled). Nothing under the gate mounts or
queries until onboarding is known to be done (`app/_layout.tsx:164`). Flipping
the status (finishing onboarding, or Settings › How it works) swaps the whole
tree, so after a replay the person lands on a fresh Home, not on Settings
(inferred from `Stack.Protected` semantics; verify on device, Q13).

Fonts are never waited for (`app/_layout.tsx:102,226`). The household session
must be known before any screen queries, otherwise a joined phone would flash
its local copy (`app/_layout.tsx:97-103`).

**Native:** `RootView` switches on an enum `{ failed, loading, onboarding, main }`
derived from the database store, `OnboardingStore` (§11.1) and the household
session store. Keep the 400 ms caption delay. Brand fonts, `FontProvider`,
`SystemUI.setBackgroundColorAsync` (`app/_layout.tsx:113-115`) and the custom
navigation theme (`app/_layout.tsx:40-55,122-140`) are not ported (system
fonts and colours). The preferences migration (§20) must finish **before**
`OnboardingStore` reads its flag, or a returning user sees onboarding again.

### 2.1 Modal sheet chrome

Every modal sheet gets a top-left close control: on iOS the word
`strings.common.cancel` (a11y label the same), which goes back exactly like a
swipe-down, so a dirty form's guard still asks first
(`app/_layout.tsx:57-90`). The Add sheet replaces it with its own Cancel that
asks before discarding (§10.6).

**Native:** `ToolbarItem(placement: .cancellationAction) { Button(strings.common.cancel) { dismiss() } }`;
dirty forms use `.interactiveDismissDisabled(isDirty)` plus a confirmation on
Cancel.

### 2.2 Overlay host

`OverlayHost` draws the toast and the removed-phone layer after the stack, so
they sit above every screen and above native modal sheets; on iOS inside a
`FullWindowOverlay` (a separate window) whose accessibility container is modal
only while the phone is revoked (`src/ui/components/Toast.tsx:226-252`,
`app/_layout.tsx:215-216`). The removed-phone layer itself
(`src/ui/components/ConnectionBanner.tsx:49-120`) belongs to the household
area; note it calls `router.dismissAll()` on appear.

**Native:** a second `UIWindow` (`windowLevel = .alert + 1`) whose root view
passes touches through everywhere except the toast card and the revoked layer.
SwiftUI `.overlay` on `MainShell` is not enough: `.sheet` content is presented
above it.

---

## 3. Route map

### 3.1 Every route

Presentation values: **tab** = tab root; **push** = pushed on a stack;
**sheet** = iOS page-sheet modal (`presentation: 'modal'`, with Cancel at top
left, `app/_layout.tsx:87-90`); **cover** = `fullScreenModal`, no header
(`app/_layout.tsx:92-95`). "Title" is the header title from
`app/_layout.tsx:166-212` unless noted.

| Route (expo path) | File | Params (all strings) | RN presentation | Title | Native | Spec owner |
|---|---|---|---|---|---|---|
| `/` | `app/(tabs)/index.tsx` | `q?` (prefills search, §5.4) | tab | in-content | `Tab` Home root | this doc §5 |
| `/spaces` | `app/(tabs)/spaces.tsx` | — | tab | in-content | `Tab` Spaces root | §6 |
| `/scan` | `app/(tabs)/scan.tsx` | — | tab | none (camera) | `Tab` Scan root | §8 |
| `/drop-zone` | `app/(tabs)/drop-zone.tsx` | — | tab | in-content | `Tab` Drop zone root | §7 |
| `/onboarding` | `app/onboarding.tsx` | — | only route while pending; no header; gesture off | — | Root replacement | §11 |
| `/settings` | `app/settings.tsx` | — | push | `strings.settings.title` | push on Home stack | §12 |
| `/privacy` | `app/privacy.tsx` | — | push | `strings.privacy.title` | push | §13 |
| `/household` | `app/household.tsx` | — | push | `strings.household.screenTitle` | push | household area |
| `/backup` | `app/backup.tsx` | — | push | `strings.backup.title` | push | sync area |
| `/c/[token]` | `app/c/[token].tsx` | `token` (string or string[]) | push | `strings.deepLink.title` | push on current tab | §9 |
| `/space/new` | `app/space/new.tsx` | `request?` | sheet | `strings.spaceForm.newTitle` | `.sheet` | spaces area |
| `/space/[id]` | `app/space/[id]/index.tsx` | `id` | push, title collapses (§16.6) | `''` | push | spaces area |
| `/space/[id]/edit` | `app/space/[id]/edit.tsx` | `id` | sheet | `strings.spaceForm.editTitle` | `.sheet` | spaces area |
| `/container/new` | `app/container/new.tsx` | `spaceId`, `request?` | sheet | `strings.containerForm.newTitle` | `.sheet` | containers area |
| `/container/[id]` | `app/container/[id]/index.tsx` | `id` | push, title collapses | `''` | push | containers area |
| `/container/[id]/edit` | `app/container/[id]/edit.tsx` | `id` | sheet | `strings.containerForm.editTitle` | `.sheet` | containers area |
| `/container/[id]/qr` | `app/container/[id]/qr.tsx` | `id` | push | screen sets `strings.qr.title` | push | containers area |
| `/container/[id]/link` | `app/container/[id]/link.tsx` | `id` | cover | — | `.fullScreenCover` | containers area |
| `/item/new` | `app/item/new.tsx` | `containerId?`, `name?`, `photoUri?`, `photoThumbUri?`, `photoWidth?`, `photoHeight?`, `photoBytes?` | sheet | `strings.add.title` (screen overrides, §10.3) | `.sheet` | this doc §10 (logic) |
| `/item/[id]` | `app/item/[id]/index.tsx` | `id`, `filing?` (`"1"` = filing run) | push, title collapses | `''` | push | items area |
| `/item/[id]/edit` | `app/item/[id]/edit.tsx` | `id` | sheet | `strings.editItem.title` | `.sheet` | items area |
| `/item/[id]/move` | `app/item/[id]/move.tsx` | `id`, `filing?`, `request?` | sheet | screen sets it | `.sheet` | items area |
| `/item/[id]/photo` | `app/item/[id]/photo.tsx` | `id` | cover, fade animation | — | `.fullScreenCover` | items area |
| `/capture` | `app/capture/index.tsx` | `containerId`, `mode?` (`"single"` default, or `"fast"`), `since?`, `request?` | cover | — | `.fullScreenCover` | capture area |
| `/capture/review` | `app/capture/review.tsx` | `containerId`, `since`, `expected` | push, back button hidden | `''` | capture area decides | capture area |

### 3.2 Navigation edges from the screens in this doc

| From | Trigger | Effect | Source |
|---|---|---|---|
| Home | Settings gear | push `/settings` | `app/(tabs)/index.tsx:413-418` |
| Home | item row | dismiss keyboard, push `/item/<id>` (query stays) | `app/(tabs)/index.tsx:80-84` |
| Home | place result row | dismiss keyboard; `openSpace(id)` or `openContainer(id)` | `app/(tabs)/index.tsx:92-98` |
| Home | "Add “q”…" on no results | sheet `/item/new?name=<trimmed query>` | `app/(tabs)/index.tsx:500-505` |
| Home | empty (joined) "Add an item" | sheet `/item/new` | `app/(tabs)/index.tsx:514-518` |
| Home | empty (not joined, no spaces) primary / secondary | push `/household` / sheet `/space/new` | `app/(tabs)/index.tsx:527-534` |
| Home | empty (not joined, has spaces) "Add an item" | sheet `/item/new` | `app/(tabs)/index.tsx:541-545` |
| Home | unpaired notice "Join your household" | push `/household` | `app/(tabs)/index.tsx:588-592` |
| Home | drop-zone card "Sort the drop zone" | `goToTab('/drop-zone')` | `app/(tabs)/index.tsx:621` |
| Home | drop-zone card "Quick Snap" | `openQuickSnap()` | `app/(tabs)/index.tsx:622` |
| Spaces | search button | `focusSearch()` | `app/(tabs)/spaces.tsx:98`, `src/ui/components/ScreenFrame.tsx:104-114` |
| Spaces | "+" / "New space" row / empty primary | sheet `/space/new` | `app/(tabs)/spaces.tsx:39,102,140` |
| Spaces | empty secondary (not joined only) | push `/household` | `app/(tabs)/spaces.tsx:144-148` |
| Spaces | space row | `openSpace(id)` | `app/(tabs)/spaces.tsx:161` |
| Drop zone | search button | `focusSearch()` | `app/(tabs)/drop-zone.tsx:143` |
| Drop zone | header "Quick Snap" / empty primary | `openQuickSnap()` | `app/(tabs)/drop-zone.tsx:131-139,174` |
| Drop zone | row | push `/item/<id>?filing=1` | `app/(tabs)/drop-zone.tsx:40-42` |
| Drop zone | "File…" | sheet `/item/<id>/move?request=<id>`, awaits `MoveResult` | `app/(tabs)/drop-zone.tsx:96-116` |
| Scan | linked label | `openContainer(container.id)` | `app/(tabs)/scan.tsx:233-239` |
| Scan | our label, not linked | push `/c/<token>` | `app/(tabs)/scan.tsx:241-246` |
| Scan (code list) | container picked | `openContainer(id)` if Scan still focused | `app/(tabs)/scan.tsx:264-269` |
| Tab bar | Add tap | haptic `tap`, sheet `/item/new` | `src/ui/components/TabBar.tsx:168-171` |
| Tab bar | Add long press (350 ms) | haptic `longPress`, `openQuickSnap()` | `src/ui/components/TabBar.tsx:173-176,182` |
| `/c/<token>` | resolves to linked label | `replace('/container/<id>')`, or `goToTab('/drop-zone')` for the drop zone | `app/c/[token].tsx:89-92` |
| `/c/<token>` | label linked here | `replace('/container/<id>')` if still open | `app/c/[token].tsx:134` |
| `/c/<token>` | not ours, "Go to Home" | `goToTab('/')` | `app/c/[token].tsx:172` |
| Settings | Household / Backup / Privacy rows | push `/household`, `/backup`, `/privacy` | `app/settings.tsx:60,76,96` |
| Settings | How it works | `replay()` → root swaps to onboarding | `app/settings.tsx:85-91` |
| Onboarding | Start / Continue / Use on its own | `complete()` → root swaps to tabs (no navigation call) | `app/onboarding.tsx:46-53` |
| Add sheet | Cancel / Save | back (dismiss) | `app/item/new.tsx:438-454,571-572` |
| Add sheet | camera button | cover `/capture?containerId=<place>&mode=single&request=<id>`, awaits `PhotoResult` | `app/item/new.tsx:385-405` |
| Add sheet | "Snap several at once…" | **replace** sheet with `/capture?containerId=<place>&mode=fast` | `app/item/new.tsx:456-461` |
| Add sheet | "Save and add another" with a photo | **replace** with `/capture?containerId=<place>` | `app/item/new.tsx:565-568` |
| Add sheet (place step) | "New container in …" / "New space…" | sheet `/container/new?spaceId&request` / `/space/new?request` (PlacePicker) | `src/ui/components/PlacePicker.tsx:225-265` |
| Scan (code list, mode `open`) | no containers at all → empty state action `strings.picker.none.action` (testID `move-no-containers`) | **plain push** `/space/new` with no `request` (mode `open` has `allowNewContainer = false`, so nothing waits for the result; the new space simply opens) | `src/ui/components/PlacePicker.tsx:255-259,340-348` |
| `/c/<token>` (picker, mode `bind`) | "New container in …" / "New space…" | `/container/new?spaceId&request` (after `/space/new?request` when no space exists); the created container is handed to `onPick` and the label is linked to it (§9.3) | `src/ui/components/PlacePicker.tsx:224-265`, `app/c/[token].tsx:187` |
| Revoked layer | appears / "Join again" | `dismissAll()` (only if `router.canDismiss()`); push `/household` | `src/ui/components/ConnectionBanner.tsx:61-76` |

Other areas also call `focusSearch` (search button in the headers of
`/space/[id]`, `/container/[id]`, `/item/[id]`) and `goToTab`
(`app/item/[id]/index.tsx:173-176,213-215`, `app/household.tsx:59-65`,
`app/capture/review.tsx:198`, edit sheets' "Go to Spaces").

### 3.3 Navigation helpers → Router API

Source: `src/ui/navigation.ts`.

| RN helper | Behaviour | Native `Router` method |
|---|---|---|
| `goToTab(href)` (`:18-21`) | If anything can be dismissed (a pushed screen or modal over the tab shell), `dismissTo(href)`: pops the root stack back to the tab shell and selects that tab. Otherwise `navigate(href)` within the tabs. Exists only so a second tab shell is never pushed. | `goToTab(_ tab:)`: dismiss sheet and cover, select `tab`, reset `paths[tab]` to `[]`. Whether to also clear the other tabs' paths is Q2. |
| `openContainer(id)` (`:27-30`) | `id == "drop-zone"` → `goToTab('/drop-zone')`; else push `/container/<id>`. Nothing ever navigates to `/container/drop-zone`. | `openContainer(_:)`: same rule; push `.container(id)` on the current tab's path. |
| `openSpace(id)` (`:33-36`) | `id == "drop-zone-space"` → `goToTab('/drop-zone')`; else push `/space/<id>`. | `openSpace(_:)` |
| `focusSearch()` (`:43-46`) | `requestSearchFocus({ afterTransition: router.canDismiss() })`, then `goToTab('/')`. | `focusSearch()`: set the one-shot request (§3.5), then `goToTab(.home)`. |
| `openQuickSnap()` (`:52-54`) | push `/capture?containerId=drop-zone&mode=fast` (a cover). | `present(.capture(containerId: "drop-zone", mode: .fast))` |

### 3.4 Results handed back between routes

Source: `src/ui/routeResult.ts` (full file), shapes in
`src/ui/navigation.ts:56-96`.

Contract:

- `openForResult(open)` creates a request id
  (`Date.now().toString(36)` + 6 random base-36 chars, `:16-18`), stores a
  resolver in an in-memory map, calls `open(requestId)` (which navigates with
  `?request=<id>`) and returns a promise. `open` runs inside the promise
  executor: if it throws, the entry is removed and the **returned promise
  rejects** with that error (it is not thrown synchronously to the caller)
  (`:26-37`). The random part is `Math.random().toString(36).slice(2, 8)`, so it
  is *up to* 6 characters; ids are opaque, only uniqueness matters.
- `deliverResult(id, value)` resolves once and returns `true`; returns `false`
  if `id` is missing or nobody is waiting (`:44-51`). The answering screen uses
  `false` to fall back to its own behaviour (example: `/space/new` replaces
  itself with `/space/<new id>`, `app/space/new.tsx:190-195`).
- `abandonResult(id)` resolves `undefined`; idempotent; answering screens call
  it on unmount (`:57-63`).
- Pending requests are memory-only; lost on restart (`:1-12`).

Result shapes:

| Route answering | Type | Fields |
|---|---|---|
| `/item/[id]/move?request=` | `MoveResult` | `itemId`, `from`, `to` (container ids), `updatedAt: number` (for a non-conflicting Undo), `waiting?: [string]` (drop-zone ids read right after a filing-run move; absent if that read failed) (`navigation.ts:64-75`) |
| `/container/new?spaceId&request=` | `NewContainerResult` | `containerId`, `name: string?`, `shortCode`, `visualType`, `spaceId` (`:81-87`) |
| `/space/new?request=` | `NewSpaceResult` | `spaceId`, `name` (`:90-93`) |
| `/capture?…&request=` | `PhotoResult` = `StoredImage` | from the capture area (`:96`) |

**Native:** `await router.present(.move(itemId:filing:), expecting: MoveResult.self) -> MoveResult?`
implemented with a `CheckedContinuation` stored per presentation and resumed
exactly once: with the value on deliver, with `nil` from the sheet's
`onDismiss`. Keep the "deliver returns false when nobody waits" semantics.
Port `src/ui/__tests__/routeResult.test.ts` (§21).

### 3.5 One-shot search-focus request

Source: `src/ui/searchFocus.ts` (full file).

- `requestSearchFocus({ afterTransition })` stores a single module-level request
  (`:12,24-26`); a later request overwrites it.
- Home calls `useSearchFocusRequest(focusField)`: each time Home gains focus it
  consumes the request (`:29-33`). Without `afterTransition` it focuses at once.
  With it, it waits for the root stack's `transitionEnd` (not closing) or a
  600 ms fallback (`TRANSITION_FALLBACK_MS`, `:15`), whichever first, and
  cancels if Home loses focus first (`:40-78`).
- It is a flag rather than a `?focus=` param so the keyboard does not come back
  on every later visit (`:9-11`).

**Native:** `router.pendingSearchFocus: Bool`; Home observes it in `.onAppear`
and when the tab becomes selected, consumes it, and sets
`.searchable(isPresented:)` to `true` after the dismissal/pop animation (use
the sheet `onDismiss` or a ~600 ms fallback; focusing a field during a
transition makes the keyboard fight the animation).

### 3.6 Deep links

- URL schemes registered: `inventory` and `com.wystudio.inventory`
  (`ios/Inventory/Info.plist:25-34`, `app.json` `"scheme": "inventory"`). Keep
  both in the native `CFBundleURLTypes`; printed QR labels encode
  `inventory://c/<token>` (`src/repositories/qr.ts:23-33`) and must keep
  opening the app from the system Camera.
- expo-router maps the URL path to a route file, so in principle **every**
  route in §3.1 is linkable (`inventory://item/<id>`, `inventory:///?q=…`). The
  app itself only produces `inventory://c/<token>`. Home honours `?q=` (§5.4).
  Which links the native app supports is Q4.
- Cold start: `unstable_settings = { anchor: '(tabs)' }` puts the tab shell (Home)
  under a deep-linked screen so Back has somewhere to go
  (`app/_layout.tsx:33-37`).
- While onboarding is pending the protected routes do not exist, and there is
  no code that remembers the link; it is effectively dropped. (Verify, Q4.)
- `NSUserActivityTypes = $(PRODUCT_BUNDLE_IDENTIFIER).expo.index_route` in
  `Info.plist` is Expo plumbing; not needed natively.

**Native:** `.onOpenURL { router.open($0) }`. Parse: scheme is `inventory` or
`com.wystudio.inventory`; for `inventory://c/<token>` `URLComponents.host == "c"`
and the token is the first path component; also accept `inventory:///c/<token>`
(empty host, path `/c/<token>`). Apply `tokenParam` semantics (§9.2: first
value, trimmed) and push `.qrLabel(token)` (§9). The token is validated by the
repository (`parseQrPayload`, §8.6), not by the router.

---

## 4. Tab bar

Source: `app/(tabs)/_layout.tsx` (full), `src/ui/components/TabBar.tsx` (full).

### 4.1 Slots and order

`Home · Spaces · [Add] · Scan · Drop zone` (`TabBar.tsx:20-28`). Add is an
action, not a route (`TabBar.tsx:19,35-43`). Tabs are lazy: a tab's screen
mounts on first visit (`app/(tabs)/_layout.tsx:25`) and then stays mounted in
the background. Tab roots draw their own titles; there is no tab header
(`app/(tabs)/_layout.tsx:8-12,23`). Settings is deliberately **not** a tab
(issue #2): it is a button on Home (`app/(tabs)/_layout.tsx:10-11`).
`DropZoneProvider` wraps the tabs so the badge, Home's card and the Drop zone
list share one read (`app/(tabs)/_layout.tsx:12,19`; §7.1).

| Slot | Label key | RN icon | Suggested SF Symbol | testID |
|---|---|---|---|---|
| Home | `strings.tabs.home` | `home` | `house` | `tab-home` |
| Spaces | `strings.tabs.spaces` | `spaces` | `square.grid.2x2` | `tab-spaces` |
| Add | `strings.tabs.add` | `plus` (filled block) | `plus` | `tab-add` |
| Scan | `strings.tabs.scan` | `scan` | `qrcode.viewfinder` | `tab-scan` |
| Drop zone | `strings.tabs.dropZone` | `inbox` | `tray` | `tab-drop-zone` |

### 4.2 Behaviour

- Pressing a tab emits `tabPress`; if it is not the active tab it navigates
  (`TabBar.tsx:60-73`). Pressing the **active** tab is left to the screen:
  - Home: scrolled (offset > 1) → scroll to top, animated; already at top →
    focus the search field (`app/(tabs)/index.tsx:191-200`).
  - Spaces and Drop zone: scroll to top (`useScrollToTop`,
    `app/(tabs)/spaces.tsx:70-72`, `app/(tabs)/drop-zone.tsx:73-74`).
  - Scan: back to the camera (off the code list), clear any notice unless a
    lookup is in flight (`app/(tabs)/scan.tsx:191-201`).
- Drop zone badge (`TabBar.tsx:58,93,140-148`): `waiting = dropZone.loading ? 0 : dropZone.count`;
  shown only when `> 0`; text `"99+"` when `> 99`, else the number. RN draws it
  as yellow label tape on purpose: "waiting is not an alarm"
  (`TabBar.tsx:39-41`).
- Tab accessibility: role tab, selected state; label is the tab label, or with a
  badge `"<label>, " + strings.tabs.waitingA11y(n)` → "Drop zone, 3 waiting"
  (`TabBar.tsx:126-131`).
- The bar reports its height so toasts float above it (`TabBar.tsx:50-53`, §14).
- Android hides the bar while the keyboard is up (`TabBar.tsx:46-55`): not
  ported.

### 4.3 Add (action slot)

- Tap: haptic `tap` (light impact), open the Add sheet `/item/new` with no
  params (`TabBar.tsx:168-171`).
- Long press, 350 ms: haptic `longPress` (medium impact), Quick Snap
  (`TabBar.tsx:173-176,182`).
- Accessibility: role button, label `strings.tabs.addA11y`, hint
  `strings.tabs.addHint`, custom action named `longpress` labelled
  `strings.tabs.quickSnapAction` that runs Quick Snap (`TabBar.tsx:183-189`).

**Native (TabBar → TabView):** `TabView(selection:)` with `Tab(_:systemImage:value:)`
for the four destinations and `.badge(count)` on Drop zone (`.badge(Text("99+"))`
above 99; no badge at 0 or while the first read is pending). There is no stock
"action tab" and no long press on a tab item. Options for Add (Q1):

1. **Intercepted middle tab** (closest to RN): a fifth `Tab(value: .add)` with
   `plus`; a custom `selection` binding refuses `.add`, keeps the previous tab
   and presents the Add sheet. Loses long-press Quick Snap; replace it with a
   Home Screen quick action ("Quick Snap", `UIApplicationShortcutItem`) and the
   existing Quick Snap buttons (Home card, Drop zone, Add sheet's
   "Snap several at once…"). Tab items cannot carry VoiceOver custom actions.
2. **`.tabViewBottomAccessory`** (iOS 26) holding an Add button with a
   `contextMenu` or long-press gesture for Quick Snap.
3. A toolbar `+` on every tab root.

`Tab(role: .search)` exists on iOS 26 but the RN app keeps search on Home
(§5); using the search role for Add would mislabel it for VoiceOver. See Q3.
Badge colour: SwiftUI badges are system red; reproducing the yellow tape
needs `UITabBarAppearance` `badgeBackgroundColor` (Q7).
Re-tap detection: a custom `Binding` setter that sees "set to the current
value" lets Home implement "scroll to top, else focus search"; SwiftUI already
pops a tab's `NavigationStack` to root on re-tap.

---

## 5. Home tab

Source: `app/(tabs)/index.tsx` (full), `src/ui/home/homeList.ts` (full),
`src/ui/home/TotalLine.tsx`, `src/ui/home/DropZoneCard.tsx`,
`src/ui/home/unpairedNotice.ts`, `src/hooks/useSearch.ts`.

Purpose: the first screen. It answers "where is it?" and "do we still have
it?" in place, and shows the household at a glance (`app/(tabs)/index.tsx:100-111`).
One list: a title block that scrolls away, a search field that stays pinned,
then either the overview or search results in place of it.

### 5.1 Data and queries

| Data | Query (repository call) | Key | When | Source |
|---|---|---|---|---|
| Spaces with counts | `spaces.listWithCounts()` | `spaces` | always | `app/(tabs)/index.tsx:149` |
| Recent items | `items.listRecent(recentLimit)`; `recentLimit` starts at 12, "Show more" sets 40 | `recent:<limit>` | always | `app/(tabs)/index.tsx:150-155` |
| All containers with space | `containers.listAllWithSpace()`, else an empty list | `containers-all` / `containers-none` | only once the field has been focused or holds a query (`wantsPlaces` latches true) | `app/(tabs)/index.tsx:141-159` |
| Drop zone | shared `useDropZone()` (§7.1) | `drop-zone` | always | `app/(tabs)/index.tsx:118` |
| Search | `useSearch(query)` (§5.6) | — | while the query is non-empty | `app/(tabs)/index.tsx:160` |
| Household session | `session?.householdName`, paired = `session != nil` | — | — | `app/(tabs)/index.tsx:116,170-172` |
| Connection state | `local / online / unsure / offline / revoked` | — | — | `app/(tabs)/index.tsx:117` |

Local SQL (data layer owns it; repeated here for reference):

- `spaces.listWithCounts` (`src/repositories/spaces.ts:63-82`):
  ```sql
  SELECT s.*,
         (SELECT COUNT(*) FROM containers c WHERE c.space_id = s.id) AS container_count,
         (SELECT COUNT(*) FROM items i JOIN containers c ON c.id = i.container_id
           WHERE c.space_id = s.id) AS item_count
    FROM spaces s WHERE s.kind = 'normal' ORDER BY s.name COLLATE NOCASE ASC
  ```
- `items.listRecent(limit)` (`src/repositories/items.ts:194-201`):
  `ITEM_CONTEXT_SELECT ORDER BY i.created_at DESC LIMIT ?` with
  `cap = max(1, min(floor(limit), 100))`. Drop-zone items are included.
  `ITEM_CONTEXT_SELECT` is at `src/repositories/items.ts:72-91` (first photo by
  `created_at ASC`, tags joined with `char(31)`).
- `containers.listAllWithSpace` (`src/repositories/containers.ts:225-240`):
  `SELECT c.*, s.name AS space_name, (SELECT COUNT(*) FROM items i WHERE i.container_id = c.id) AS item_count FROM containers c JOIN spaces s ON s.id = c.space_id WHERE c.kind = 'normal' ORDER BY s.name COLLATE NOCASE ASC, c.created_at DESC`.
- Paired (household HTTP, `src/services/household/httpRepositories.ts`):
  `GET /v1/spaces` → `{spaces}` (`:127-130`); `GET /v1/items?recent=1&limit=<n>`
  → `{items}`, then each row's thumbnail is fetched (`:233-238,107-125`);
  `GET /v1/containers` → `{containers}` (`:214-217`); `GET /v1/search?q=` (`:359-363`).

Side effect: every time `recent.data` changes its categories are fed to the
category memory used by item forms (`app/(tabs)/index.tsx:187-189`;
`rememberCategories`, `src/ui/categoryMemory.ts:76`).

"Show more" keeps rows on screen: a failed 40-row read would otherwise drop the
12 rows (the query keeps data only for its own key), so the screen remembers
the last non-null recent list and shows it under the refresh-failed banner
(`app/(tabs)/index.tsx:162-168`).

### 5.2 Header (title block)

Hidden while compact (field focused or query non-empty), so results start
right under the field (`app/(tabs)/index.tsx:137-139,409`).

- Title: `session.householdName.trimmed()`, or `strings.home.title` if empty
  or not joined (`app/(tabs)/index.tsx:172,411-412`).
- Trailing button: settings gear, a11y label `strings.home.settings`, testID
  `home-settings`, pushes Settings (`app/(tabs)/index.tsx:413-420`).
- Subtitle line 1, the household summary, shown only when `counts != nil` and
  `counts.spaces + counts.items > 0` (`app/(tabs)/index.tsx:423-428`):
  - `counts` is computed only when spaces data is present, the drop zone is not
    loading, and not (drop zone failed with count 0)
    (`app/(tabs)/index.tsx:403-406`).
  - `householdCounts(spaces, dropZoneCount)` (`src/ui/home/homeList.ts:56-67`):
    spaces = number of normal spaces; containers = sum of `containerCount`;
    items = sum of `itemCount` + drop-zone count. The drop zone's own container
    is not counted.
  - Text `strings.home.summary(spaces, containers, items)` → "5 spaces, 13 containers and 45 items."
- Subtitle line 2, where the data lives, always shown
  (`app/(tabs)/index.tsx:429-447`): icon `server` when joined, `phone`
  otherwise; text `strings.connection.sharedReconnecting` (in signal colour,
  icon too) when joined and connection is `offline`, else
  `strings.connection.shared` when joined, else `strings.connection.local`.

**Native:** `.navigationTitle(householdName)` with large title display; gear as
`ToolbarItem(placement: .primaryAction)`; iOS 26 `.navigationSubtitle(...)` for
the summary and the "where it lives" caption (or a header row in the list).
Large titles hide automatically while `.searchable` is active, which matches
"compact".

### 5.3 Search field

- Always the first entry and the list's one sticky row
  (`src/ui/home/homeList.ts:43-44`, `app/(tabs)/index.tsx:724`).
- Placeholder `strings.home.searchPlaceholder` (the component's own default,
  used only by callers that pass none, is `strings.common.findAnything`); a11y
  label `strings.a11y.searchHousehold`; role search on iOS; no autocorrect, no
  spell check, no autocapitalisation (`autoCapitalize` prop, `'characters'`
  in the Scan code list picker), no autofill; return key "search"; submit
  blurs the field; testID `search-input` on Home
  (`src/ui/components/SearchField.tsx:38-52,88-116`, `app/(tabs)/index.tsx:565-576`).
- Clear button when non-empty: a11y `strings.common.clearSearch`, testID
  `search-clear`; clears, refocuses, haptic `choice` (selection)
  (`SearchField.tsx:61-65,118-130`).
- `busy = search.pending`: the magnifier turns into a spinner after 180 ms
  (`SearchField.tsx:59,83-87`, `app/(tabs)/index.tsx:573`).
- A bottom rule appears once rows scroll under the pinned field
  (`app/(tabs)/index.tsx:127,311-318,553-563`): styling only.

Focus and typing (`app/(tabs)/index.tsx:268-284`):

- `changeFocus(next)`: animate the layout if "compact" changes; set focused.
- `changeQuery(text)`: animate if compact changes; when the query goes from
  empty to non-empty, jump the list to the top (no animation); collapse any
  expanded quantity chip; cancel any summary waiting to be announced; set the
  query.

**Native:** `.searchable(text: $query, isPresented: $searchPresented, placement: .navigationBarDrawer(displayMode: .always), prompt: strings.home.searchPlaceholder)`,
`.textInputAutocapitalization(.never)`, `.autocorrectionDisabled()`,
`.onSubmit(of: .search) { announceResults() }`. `isPresented` gives
programmatic focus for re-tap and `focusSearch`. The in-field spinner has no
stock equivalent (Q9).

### 5.4 `?q=` prefill

`/?q=<text>` fills the field once per distinct value; typing afterwards is
hers (`app/(tabs)/index.tsx:130-135`). Nothing in the app links to it; it only
arrives by deep link. Keep only if Q4 says so.

### 5.5 Idle list (nothing typed)

Built by `idleEntries` (`src/ui/home/homeList.ts:130-158`) from an `IdleBody`
computed in the screen (`app/(tabs)/index.tsx:343-359`):

```
idleBody:
  recentRows == nil                         → status(recent.cause != nil ? .error : .loading)
  recentRows.isEmpty && dropZone.count == 0:
      !paired && spaces.data == nil         → status(spaces.cause != nil ? .error : .loading)
      else                                  → status(.empty)
  else → list(recent: recentRows,
              canShowMore: recentLimit == 12 && recentRows.count == 12)

startHere = idleBody == status(.empty) && !paired && (spaces.data?.isEmpty ?? true)
```

Entry order (`homeList.ts:136-157`):

1. `refreshFailed` banner, if `refreshFailed` (below).
2. Unpaired notice, if `notice.visible && !startHere` (`app/(tabs)/index.tsx:386-387`).
3. Drop-zone card, if `dropZone.count > 0`.
4. If body is a status: the status entry, and stop.
5. If `recent` is empty: stop (no empty section).
6. Section title `strings.home.recent` with count = recent rows; `first` is
   true when nothing came before it.
7. One item row per recent item, in query order (newest first).
8. "Show more" when `canShowMore`.

`refreshFailed` for the idle list is true when any of these has a cause **and**
its data is on screen **and** the cause is not explained elsewhere
(`app/(tabs)/index.tsx:388-397`): spaces (`spaces.data != nil`), recent
(`recentRows != nil`), drop zone (`dropZone.count > 0`).

`explainedElsewhere(cause, connectionState)` (`app/(tabs)/index.tsx:69-78`):
`describeError(cause).kind == .revoked || (kind == .offline && state != .online)`.
The connection banner explains an unreachable home server only while the
state says so; a blip that recovered gets the screen's own Try again.

Status renderings (`app/(tabs)/index.tsx:454-550`):

| Status | Rendering |
|---|---|
| `loading` | skeleton, variant `list`, 4 rows |
| `error` | `cause = recent.cause ?? spaces.cause`. If explained elsewhere: plain text `strings.home.waitingForServer` (testID `home-waiting`). Otherwise `ErrorState(cause:, onRetry: reloadOverview)` (testID `home-error`). Never an empty list for a failed read. |
| `empty`, joined | Empty state: title `strings.home.empty.paired.titleIn(householdName)`, body `strings.home.empty.paired.body`, primary `strings.home.empty.paired.add` (icon plus) → Add sheet. testID `home-empty`. |
| `empty`, not joined, `startHere` | title `strings.home.empty.unpaired.title`, body `…unpaired.body`, primary `…unpaired.join` → Household, secondary `…unpaired.start` → New space sheet. |
| `empty`, not joined, has spaces | title `strings.home.empty.local.title`, body `…local.body`, primary `…local.add` (icon plus) → Add sheet. |

Unpaired notice (`app/(tabs)/index.tsx:579-601`, `src/ui/home/unpairedNotice.ts`):

- Info banner, icon `phone`, title `strings.home.unpaired.title`, message
  `strings.home.unpaired.body`, primary `strings.home.unpaired.join`
  (testID `unpaired-join`) → Household, secondary `strings.common.notNow` with
  a11y hint `strings.home.unpaired.notNowHint`. Not announced (part of the page,
  `live="off"`).
- Visibility: `!paired && dismissed == false`. `dismissed` is `nil` until the
  preference is read, so the notice never flashes (`unpairedNotice.ts:15-34,41`).
  Preference key `notice.unpaired.dismissed.v1`, value `"1"` when dismissed
  (`:4,23`). Read failure → treat as not dismissed. "Not now" sets it in memory
  at once and writes `"1"`; a write failure only means it returns next launch
  (`:34-39`).

Refresh-failed banner (`app/(tabs)/index.tsx:602-614`): info banner, message
`strings.errors.refreshFailed`, action `strings.common.tryAgain` →
`search.retry()` while searching, else `reloadOverview()`. Announced (polite).

Drop-zone card (`src/ui/home/DropZoneCard.tsx`, used at
`app/(tabs)/index.tsx:615-625`):

- Heading (a11y header) `strings.home.dropZone.title(count)`; body
  `strings.home.dropZone.body`; overlapping thumbnails of the first 3 waiting
  items (`THUMBS = 3`, `photoThumbUri ?? photoUri`) (`DropZoneCard.tsx:13,43-66`).
- Buttons side by side, never nested: `strings.home.dropZone.sort`
  (testID `drop-zone-open`) → Drop zone tab; `strings.home.dropZone.quickSnap`
  (icon layers, testID `quick-snap`) → Quick Snap (`DropZoneCard.tsx:67-84`).
  The card itself is not tappable (`:25-36`).
- At large text the thumbnails go above the text (`:28-31,43`).

"Show more" (`app/(tabs)/index.tsx:680-691`): label `strings.common.showMore`,
a11y label `strings.home.recentMoreA11y`, testID `recent-more`; sets the limit
to 40 for the rest of the screen's life. The 12 rows stay while the 40 load.

### 5.6 Search model (`useSearch`)

Source: `src/hooks/useSearch.ts` (full).

State: `settled = { query, run, results, cause }`; `run = "<seenRevision>|<nonce>"`.

- `trimmed = query.trimmed()`. Empty → no search; reset the "already logged"
  query so searching the same words later counts again (`:85-90`).
- **Debounce:** a query different from the settled one waits 200 ms
  (`delay.searchDebounce`); the same query re-run (focus, write, retry) starts
  at once (`:92`). Each change cancels the previous timer and in-flight answer
  (`:121-124`).
- Success → `settled = {trimmed, run, results, nil}`; feed result categories to
  the category memory; log `search_performed` once per distinct settled query
  with `termCount`, `resultCount` (items + locations), `queryLength`; the text
  is never logged (`:95-107`).
- Failure → `settled = {trimmed, run, previous.query == trimmed ? previous.results : nil, cause}`:
  a failed re-run keeps the last results for the same query (`:109-117`).
- Re-run triggers: Home gaining focus (`nonce += 1`, `:127-131`); a database
  write (`revision`) **only while Home is focused**, caught up on next focus
  (`:65-68`); `retry()` (`nonce += 1`, `:133`).
- Outputs (`:135-145`):
  - `results` = `settled.results` (may belong to an **older** query; used to
    keep older rows visible, dimmed). `settled` is **never cleared** when the
    field is emptied, so after clearing "glue" and typing "tape", the "glue"
    results show dimmed (§5.7) until "tape" settles; on the same words again
    the re-run starts with no debounce.
  - `pending` = `trimmed != "" && settled.query != trimmed`.
  - `refreshing` = query current but `settled.run != run`.
  - `cause` = only when current **and** answered for this run.
  - `settledQuery`.

The repository call is `search.search(trimmed)` returning
`SearchResults { terms: [String], locations: [LocationSearchResult], items: [ItemSearchResult] }`
(`src/repositories/search.ts:13-30`); `ItemSearchResult.matchKind` is
`direct` (the item's own name, category or tags matched) or `location` (only
its space or container matched). Matching rules, limits (200 items, 30
places) and ordering belong to the search area.

### 5.7 Results list

Screen logic (`app/(tabs)/index.tsx:324-379`):

```
showingOlder = search.pending && search.results != nil
               && (results.items.count + results.locations.count) > 0
mountSkeleton = delayedFlag(showingOlder, 600 - 180 = 420 ms)
dropOlder     = delayedFlag(showingOlder, 600 ms)
searchStarted = delayedFlag(searching && !showingOlder
                            && (search.pending || search.results == nil), 200 ms)
dim = showingOlder && !dropOlder

searchBody:
  if search.pending:
     if dim && results != nil:
        older = resultEntries(results, refreshFailed: false)
        return mountSkeleton ? [searching] + older : older
     return [searching]
  if results == nil:
     return [search.cause != nil ? searchFailed : searching]
  return resultEntries(results,
           refreshFailed: search.cause != nil && !explainedElsewhere(search.cause, connection.state))
```

`delayedFlag(active, ms)` is true only after `active` has stayed true for `ms`
(`src/hooks/useDelayedFlag.ts:12-24`). The `searching` status renders a
skeleton (variant `rows`, 5 rows) when `searchStarted || mountSkeleton`
(`app/(tabs)/index.tsx:462-467`); the skeleton has its own 180 ms appear delay
(`src/ui/components/Skeleton.tsx:96`). Net effect to reproduce:

- With older results on screen: they stay, at 50 % opacity, not tappable,
  hidden from VoiceOver (`app/(tabs)/index.tsx:697-713,777-780`); at 600 ms
  after the new query became pending the skeleton replaces them with no gap.
- Without older results: the skeleton appears 380 ms after the query became
  pending (200 ms + 180 ms), so a quick search never flashes one.

`resultEntries(results, refreshFailed)` (`src/ui/home/homeList.ts:176-239`):

1. Split items with `splitMatches` (`:161-169`), keeping search order:
   `direct`, `location`. `places = results.locations`.
2. All three empty → `[status(noResults)]` only (no banner).
3. `refreshFailed` banner if set.
4. Summary line `strings.search.summary(results.items.count, places.count)`
   only when **more than one** of `direct`, `places`, `location` is non-empty.
   Not a live region (`app/(tabs)/index.tsx:626-634`).
5. If `direct` non-empty: title `strings.search.items` (count, `first`), then a
   totals line if `nameTotals(direct)` is non-empty, then the direct item rows
   (keys `item-<id>`).
6. If places non-empty: title `strings.search.places` (count), then place rows
   (keys `place-<kind>-<id>`).
7. If `location` non-empty: title `strings.search.keptInThose` (count), rows
   (keys `kept-<id>`).

`first` is true only on the first section actually shown. Every entry key is
unique even when an id is both a place and an item.

`nameTotals(items)` (`homeList.ts:76-99`): group by `name.trimmed().lowercased()`
skipping empty names; sum `quantity`; collect distinct `containerId`s; keep
groups with **2 or more distinct containers**; output in order of first
appearance; the display name is the first item's trimmed spelling. **Swift:**
use an ordered structure (array + index), not `Dictionary` order.

Totals line (`src/ui/home/TotalLine.tsx:13-31`): per total, text
`strings.search.totalName(name)` + `×N` (`strings.rows.times`) or, at 0,
`strings.quantity.noneLeftValue` in signal colour + `strings.search.totalIn(places)`
/ `strings.search.totalNoneIn(places)`. Accessibility label
`strings.search.total(name, quantity, places)` or
`strings.search.totalNone(name, places)`. Plain text, not a control.

Status renderings while searching (`app/(tabs)/index.tsx:484-507`):

| Status | Rendering |
|---|---|
| `searchFailed` | `ErrorState(cause:, title: kind == .offline ? <described title> : strings.search.failed, onRetry: search.retry)` |
| `noResults` | Empty state, icon search, title `strings.search.none.title(trimmed)`, body `strings.search.none.body`, secondary `strings.search.none.add(trimmed)` (icon plus, testID `search-add-missing`) → Add sheet with `name` |

Place rows (`app/(tabs)/index.tsx:665-679`, `src/ui/components/PlaceRows.tsx:163-212`)
join the hit with `spacesById` / `containersById`:

- Space hit with a known space → space row (tile 48, name with highlighted
  terms, `strings.entities.spaceCounts(containers, items)`), a11y
  `strings.rows.spaceA11y(name, counts)`.
- Container hit with a known container → container row: type tile (48), name
  (highlighted terms; or `strings.entities.unnamedContainer(typeName)` in
  secondary colour, not highlighted), code tape, item count
  `strings.entities.contents(n)` as the trailing aside (`n` = the **hit's**
  `itemCount`, not the containers list's), and an inline location line with the
  space only (`showContainer: false`; pip colour = `spacesById[hit.spaceId]?.color`,
  else `""`); a11y `strings.rows.containerA11y(label, type, spellCode(code), items, hasLabel)`
  where **`hasLabel` is always `false` in search** (PlaceRow never passes
  `qrToken`, so " Has a QR label" is never spoken here). `typeName` =
  `strings.entities.typeNames[visualType] ?? typeNames.other ?? visualType`
  (`PlaceRows.tsx:74-76,82-141,175-195`). Row testIDs: wrapper
  `place-row-<hitId>`, inner `space-row-<id>` / `container-row-<id>`.
- Otherwise (join missing: list still loading, place just created) a plain
  row: leading `TypeTile(type: "other")`, the hit's own `title` (highlighted)
  and preformatted `subtitle` (never parsed), chevron; a11y
  `"<title>. <subtitle>"`; testID `place-row-<hitId>` (`PlaceRows.tsx:198-211`).
- Tap → `openPlace` (§3.2): dismiss keyboard, `openSpace` / `openContainer`
  (both send the drop zone's records to the Drop zone tab).

Item rows on Home use `ItemRow` with `line: .where`, `tool: .chip`, the search
`terms` (only while searching), and the shared expanded id
(`app/(tabs)/index.tsx:647-664`). See §15.2.

### 5.8 Item quantity chip expansion

- One expanded row at a time; tapping a chip toggles it; any query change
  collapses it (`app/(tabs)/index.tsx:125,214-220,279-280`).
- Expanding dismisses the keyboard first (the stepper would open behind it)
  (`:215-217`).
- Reveal: once the expanded row has its new height, if it is not **fully**
  visible (viewability threshold 100 %, `:67,222-227`) the list scrolls so the
  row's bottom is visible plus `space.md` (12 pt) of margin, animated unless
  Reduce Motion (`:229-246`).

**Native:** `ScrollViewReader.scrollTo(id, anchor: .bottom)` after the
expansion animation, only when the row's frame is not inside the visible
rect.

### 5.9 Pull to refresh and Try again

- `reloadOverview()` = reload spaces, recent, drop zone
  (`app/(tabs)/index.tsx:248-252`).
- `refresh()` = `reloadOverview()` and, while searching, `search.retry()` and
  reload containers (place rows take codes and types from them) (`:254-261`).
- The spinner shows only for a pull she made, and ends when
  `spaces.loading || recent.loading || (searching && search.refreshing)` is
  false (`:262-266`; `src/ui/spaces/usePullToRefresh.tsx:14-39`).

**Native:** `.refreshable { await model.refresh() }` where `refresh()` awaits all
the reads it started.

### 5.10 Announcing results

The summary is not a live region; it is spoken when she presses the search key
(`app/(tabs)/index.tsx:286-309`):

- Empty query → nothing.
- Results pending or nil → remember "announce when settled".
- Otherwise announce `strings.search.summary(items.count, locations.count)`.
- When the pending query settles: results → announce and clear; a failure →
  clear (the error state announces itself). Typing again clears the pending
  announcement (`:281-282`).

**Native:** `AccessibilityNotification.Announcement(text).post()`.

### 5.11 Other Home details

- Keyboard: list taps do not dismiss it unless handled
  (`keyboardShouldPersistTaps="handled"`), dragging dismisses it
  (`app/(tabs)/index.tsx:729-730`). Native: `.scrollDismissesKeyboard(.interactively)`.
- Search-focus requests from other screens focus the field (§3.5,
  `app/(tabs)/index.tsx:202-203`).
- Layout animation (180 ms cross-fade) on compact changes; skipped under
  Reduce Motion (`src/ui/motion.ts:94-100`). Native: `withAnimation` gated on
  `accessibilityReduceMotion`.

**Native layout:** `List` (`.insetGrouped`) with sections; the RN "bordered
sheets" (`sheetCell`, `src/ui/components/Sheet.tsx:49-70`) are exactly inset
grouped sections. Section headers show title plus count (secondary). Banners
and the card are their own sections at the top.

---

## 6. Spaces tab

Source: `app/(tabs)/spaces.tsx` (full).

Purpose: the house room by room, and where the owner sets it up
(`:57-63`).

- Query: `spaces.listWithCounts()`, key `spaces` (`:74-77`); SQL in §5.1.
  Ordered by name, case-insensitive; drop-zone space excluded.
- Header: title `strings.spaces.title`; subtitle `strings.spaces.count(n)` only
  when `n > 0` (no "0 spaces" over the empty state) (`:84-95`); actions: search
  button (a11y `strings.a11y.searchHousehold`, hint `strings.a11y.searchHint`,
  testID `spaces-search`) and `+` (a11y `strings.spaces.newSpace`, testID
  `spaces-create`) → New space sheet (`:96-106`).
- Refresh-failed banner when `needsRefreshBanner(refreshFailed, cause)`
  (`:108-117`; `src/ui/errors.ts:90-94`): message `strings.errors.refreshFailed`,
  action Try again → reload. Rule: `refreshFailed && describeError(cause).kind ∉ {offline, revoked}`.
  **Note the difference from Home's `explainedElsewhere` (§5.5):** Spaces and
  Drop zone suppress an `offline` failure unconditionally, Home suppresses it
  only while the connection state is not `online`. Port both rules as written.
- Rows: space row per space (tile 56: emoji on a tint of the space colour; name;
  `strings.entities.spaceCounts(containerCount, itemCount)`; chevron), a11y
  `strings.rows.spaceA11y(name, counts)`, testID `space-row-<id>`; tap →
  `openSpace(id)` (`:159-163`; `src/ui/components/PlaceRows.tsx:35-51`).
- Last row of the same group, only when there is at least one space: "New space"
  (plus glyph, label `strings.spaces.newSpace`, testID `spaces-create-row`) →
  New space sheet (`:26-55,166-168`).
- Empty / loading / error (`:121-151`):
  - `data == nil` and cause → `ErrorState(cause:, onRetry: reload)` (a failed
    first read is never "no spaces yet", issue #12).
  - `data == nil`, no cause → skeleton `rows` (6 rows).
  - `data == []` → empty state, icon spaces, title `strings.spaces.start.title`,
    body `strings.spaces.start.body`, primary `strings.spaces.start.action`
    (icon plus, testID `spaces-empty`) → New space; secondary
    `strings.spaces.start.join` → Household, **only when not joined**.
- Re-tap the active tab: scroll to top (`:70-72`). Pull to refresh (`:78`).

`entities.spaceCounts` (strings.ts): 0 containers → "No containers yet";
items 0 → "N container(s), empty" / "all empty"; else "N containers and M items".

**Native:** `List` with one section of `NavigationLink`-style rows plus a final
"New space" button row; `+` in the toolbar; `ContentUnavailableView` for empty.

---

## 7. Drop zone tab

Source: `app/(tabs)/drop-zone.tsx` (full), `src/providers/DropZoneProvider.tsx` (full).

Purpose: the holding area for things added "somewhere" or photographed with
Quick Snap, and the owner's filing queue. Filing a named item is two taps and
she stays on the list; opening a row starts a filing run on the item screen
(`app/(tabs)/drop-zone.tsx:44-59`).

### 7.1 Shared drop-zone read (`DropZoneProvider`)

- One `items.listUnsorted()` read, key `drop-zone`, shared by the tab badge,
  Home's card and this list (`DropZoneProvider.tsx:23-36`).
- SQL: `ITEM_CONTEXT_SELECT WHERE i.container_id = ? ORDER BY i.created_at DESC`
  with the bound parameter `"drop-zone"` (`DROP_ZONE_CONTAINER_ID`)
  (`src/repositories/items.ts:185-191`). Paired: `GET /v1/items?unsorted=1`
  plus thumbnails (`httpRepositories.ts:227-232`).
- Exposed value (`DropZoneProvider.tsx:38-49`): `items` (`[]` until the first
  read), `count`, `loading` = loading **and** no data yet (badges and cards stay
  hidden rather than showing 0), `cause`, `refreshFailed`, `reading` = any read
  in flight (pull spinner), `reload`.
- Mounted in the tabs layout, which is a screen of the root stack: it re-reads
  when the tab shell comes back into view, and after writes while in front
  (`:28-30`).

**Native:** a `@MainActor @Observable DropZoneStore` owned by `MainShell`,
reloaded on: launch of the shell, any tab root appearing, database revision
bumps, explicit reload. Same derived flags.

### 7.2 Screen

- Rows = `visibleRows(items, hidden)` (`app/(tabs)/drop-zone.tsx:84`;
  `src/ui/capture/captureFlow.ts:186-210`): rows filed a moment ago leave at
  once rather than when the refetch lands. The hidden set belongs to the list
  instance it was made against; a fresh read replaces it, so an item moved back
  by Undo shows again. **Swift:** key the hidden set by a read generation
  number instead of array identity.
- Header (`:118-156`): title `strings.dropZone.title`; when rows exist, subtitle
  `strings.dropZone.intro2(rows.count)` and a "Quick Snap" button
  (`strings.dropZone.quickSnap`, icon layers, testID `drop-zone-capture`) under
  it; action: search button (testID `drop-zone-search`).
- Refresh-failed banner: `needsRefreshBanner(refreshFailed, cause)` (`:146-154`).
- Row: `ItemRow` with `line: .added`, `tool: .file`, `thumb` 76 or 56,
  `now` (`:186-198`):
  - Second line: quantity lead (`×N`, or `strings.rows.noneLeft` in signal at 0;
    nothing when 1) + `strings.rows.separator` + `ago(createdAt, now)`; without a
    lead: `strings.rows.addedShort(ago)` ("Just now", "5 minutes ago")
    (`src/ui/components/ItemRow.tsx:75-110`).
  - "File…" button: `strings.rows.file`, a11y `strings.rows.fileA11y(name)`,
    icon move, testID `drop-zone-file-<id>` (`ItemRow.tsx:254-263`).
  - Tap row → `/item/<id>?filing=1` (`:40-42`).
- Thumbnail size: 76 when stacked or `width >= 390 * max(fontScale, 1)`, else 56
  (`:28-35,65`). RN-only layout tuning; natively pick by Dynamic Type.
- "Added just now" ages: `now` ticks every 60 s while the tab is in front, and
  immediately on refocus (`:76-77`; `src/hooks/useNow.ts:11-27`).
- Categories of waiting items go to the category memory (`:79-82`).

Filing (`:93-116`):

1. Ignore if a move sheet is already opening (`filingRef`).
2. `openForResult<MoveResult>` → sheet `/item/<id>/move?request=<rid>` (no
   `filing=1`: the list is the run, and the move sheet's toast — "Filed in …"
   with Undo — is the confirmation; owned by the items area).
3. If no result (closed): nothing.
4. Else, using the list as last drawn (`shownRef`, `:86-91`), animate and hide
   the row, then `reload()`.

Empty, loading, error (`:158-178`):

- `loading` (no data yet) → skeleton `rows` (default 6 rows) with the chosen
  thumbnail size.
- These states only render when `rows` is empty (they are the list's
  `ListEmptyComponent`); with rows on screen a failed refresh shows only the
  banner above them.
- `cause && !refreshFailed` → `ErrorState(cause:, onRetry: reload)` (a failed
  first read is never "everything is filed").
- else → empty state, icon inbox, title `strings.dropZone.emptyAll.title`, body
  `strings.dropZone.emptyAll.body`, primary `strings.dropZone.emptyAll.action`
  (icon layers) → Quick Snap; testID `drop-zone-empty`.

Re-tap the active tab: scroll to top. Pull to refresh uses `reading`.

**Native:** `List` of rows with a trailing bordered "File…" button (a
`Button` beside the row content, not inside a `NavigationLink`, so it is its
own VoiceOver stop); optionally also `.swipeActions` "File…". Removal with
`withAnimation`.

---

## 8. Scan tab

Source: `app/(tabs)/scan.tsx` (full), `src/ui/components/QrScanner.tsx` (full),
`src/ui/components/CameraPermission.tsx` (full), `src/ui/scan/scanRules.ts`,
`src/repositories/qr.ts`.

Purpose: "What's in this box?" (issue #10). Point the camera at a label and its
container opens. A label this app made but never linked goes to `/c/<token>`
(the one place labels are linked, so the Scan tab and the iPhone Camera behave
the same). Anything else says plainly it is not ours; a failed lookup says what
went wrong (`app/(tabs)/scan.tsx:141-155`).

### 8.1 State

```
Phase  = camera | code
Result = idle | opening | notOurs | failed(cause)
lookupGeneration: Int     // lookupRef
cameraUp: Bool            // phase == camera, read by late callbacks
```

(`app/(tabs)/scan.tsx:34-43,159-177`)

Transitions:

| Event | Effect | Source |
|---|---|---|
| Tab gains focus | `phase = camera`, `result = idle` | `:179-189` |
| Tab loses focus | `lookupGeneration += 1` (drops a lookup in flight) | `:185-187` |
| Re-tap Scan while focused | `phase = camera`; `result = idle` unless `opening` | `:191-201` |
| Code read (`open(raw)`) | ignored unless `cameraUp` and tab focused; `gen += 1`; `result = opening`; `qr.resolveScan(raw)` | `:215-223` |
| Lookup throws (and still current) | log error `qr_scan_failed {errorClass}`; haptic `error`; `result = failed(cause)` | `:224-230` |
| Outcome `bound` | log `qr_scan {outcome: "bound"}`; haptic `success`; `result = idle`; `openContainer(container.id)` | `:233-239` |
| Outcome `unknown` | log `qr_scan {outcome: "unknown"}`; `result = idle`; push `/c/<token>` | `:241-246` |
| Outcome `invalid` | log `qr_scan {outcome: "invalid"}`; haptic `error`; `result = notOurs` | `:248-250` |
| "Scan again" / "Try again" | `result = idle` (re-arms the scanner; does **not** re-run the old lookup) | `:253-255` |
| "Type a code instead" | `gen += 1`; `result = idle`; `phase = code` | `:257-262` |
| Code list pick (container) | `openContainer(id)` only if still focused (no double push) | `:264-269` |
| "Back to the camera" | `phase = camera` | `:278-286` |

A result is applied only if `lookup == lookupGeneration` at completion
(`:225,231`).

### 8.2 Camera phase rendering

- Scanner `active = !revoked && (result == idle || result == opening)`; off
  while a notice waits for an answer, and under the removed-phone layer
  (`:336-338`).
- Scanner title pill: `strings.scan.title` (`:339`).
- Footer panel over the bottom of the picture (`:302-331`; panel at
  `:52-99`):

| Condition | Tone | Title | Message | Buttons |
|---|---|---|---|---|
| `notOurs` | error | `strings.scan.invalidTitle` | `strings.scan.invalidBody` | `strings.scan.scanAgain` (testID `scan-again`), Type a code |
| `failed(cause)` | error | `describeError(cause).title` | `describeError(cause).body` | `strings.common.tryAgain` (icon refresh, testID `scan-try-again`), Type a code |
| `opening` for ≥ 180 ms | busy (spinner) | — | `strings.scan.opening` | — |
| otherwise | hint | — | `strings.scan.hint` | Type a code |

"Type a code" = `strings.scan.typeCode`, icon keyboard, testID `scan-type-code`.
Error panels are assertive live regions, busy polite, hint none; on iOS any
non-hint panel posts the announcement `"<title>. <message>"` (or the message)
(`:57-77`).

### 8.3 Code phase rendering

- Heading `strings.scan.codeTitle`; button `strings.scan.backToCamera` (icon
  camera, testID `scan-back-to-camera`) (`:271-287`).
- Frame: the code phase is a normal tab root (`ScreenFrame kind="tabRoot"`, so
  the connection banner shows at the top); the camera phase is
  `kind="camera"` (testID `scan-camera`), full-bleed black with **no**
  connection banner (`:273,334`; `src/ui/components/ScreenFrame.tsx:45-64`).
- Place picker in mode `open` with placeholder `strings.scan.codePlaceholder`
  (`:288`). Mode `open` (`src/ui/components/PlacePicker.tsx:38-64,110-121`):
  filter autofocused, capitalised characters, no "New container in …" rows; the
  filter matches names, label codes with or without the hyphen, spaces and
  types ("drw7k" finds DRW-7K2M); recent places first (max 4), then spaces in
  the Spaces tab's order with containers sorted by label. Only a container pick
  does anything. Picker internals belong to the places area.
- Android back on the code list returns to the camera (`:203-213`): not ported.

### 8.4 QrScanner behaviour

Source: `src/ui/components/QrScanner.tsx`.

- Camera permission not granted → `CameraPermission(purpose: scan)` with
  `onManual = typeCode`; no close button on the Scan tab (`:139-150`). §8.5.
- The camera runs **only** while the screen is focused **and** `active`
  (`:160-169`); a background tab must not hold the camera (battery, camera
  light, other apps) (`:56-65`). Back camera, QR symbology only (`:163-164`).
- Torch toggle: icon button, selected state, a11y `strings.camera.torchState(on)`,
  testID `scan-torch` on this tab; turned off whenever the screen loses focus
  (`:107,152-154,194-203`). Hidden once the camera failed to start.
- **One scan per arming** (`:86-137`):
  - `arming` increments on every focus and each time `active` goes false → true.
  - A read sets the per-arming guard **synchronously** before anything is
    awaited, so the 2nd and 3rd frames of the same label are ignored.
  - The reticle corners switch to the accent colour ("locked"), then after
    250 ms (`duration.reticleLock`, 0 with Reduce Motion) `onScan(raw)` is called;
    the lock clears when `onScan` finishes.
- **Same label after coming back** (`:91-95,102-109,113-124`): on focus, the
  last handed-over code is remembered as "ignore"; frames with that same code
  are ignored as long as it keeps being seen within 1500 ms
  (`SAME_CODE_GAP`, each sighting refreshes the timestamp). A different code,
  or the same code after ≥ 1500 ms out of view, ends the ignore. "Scan again"
  (re-activation, not focus) does not set the ignore, so the same code is
  accepted.
- Mount failure → panel `strings.camera.didNotStartScan` with button
  `strings.permissions.typeCodeInstead` (icon keyboard, testID `scanner-manual`);
  footer and torch hidden (`:207-228`).
- Status bar light while focused (`:158-159`).
- Reticle 240 pt square, decorative, hidden from accessibility (`:51,236-255`).
- The component is shared with the sticker-link cover
  (`app/container/[id]/link.tsx`, containers area). Its full prop surface
  (`:17-48`): `active`, `title`, `onScan(raw) async`, `onManual?` (permission
  screen and mount-failure panel), `onClose?` (shows a close button, a11y
  `strings.camera.close`, testID `closeTestID ?? "scanner-close"`; absent on the
  Scan tab), `torchTestID` (default `scanner-torch`), `footer?` (drawn only while
  the camera is up and has not failed), `torchLabelOn?` / `torchLabelOff?`
  (override `strings.camera.torchState(on)`). The native wrapper should expose
  the same knobs.

**Native:** `DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, isHighlightingEnabled: false)`
(check `DataScannerViewController.isSupported` and `.isAvailable`) or
`AVCaptureSession` + `AVCaptureMetadataOutput` with `.qr` as the fallback. Start in `onAppear` / when `active` becomes true, stop in
`onDisappear` / when inactive (the tab view stays alive). Torch via
`AVCaptureDevice.torchMode`. Keep the arming guard and the 1500 ms same-code
ignore on the main actor; DataScanner also delivers repeated callbacks. The
title pill: `Text` on `.glassEffect()` / material capsule.

### 8.5 Camera permission screen (scan purpose)

Source: `src/ui/components/CameraPermission.tsx:47-177`.

| Permission | UI |
|---|---|
| unknown (still reading) | black screen; spinner after 180 ms |
| can ask | icon camera; title `strings.permissions.cameraRationaleTitle`; body `strings.permissions.scanBody`; primary `strings.permissions.grant` (testID `camera-allow`) → system prompt, then log `permission_result {permission: "camera", outcome: "granted" \| "denied"}`; secondary `strings.permissions.typeCodeInstead` (icon keyboard, testID `camera-manual`) |
| denied permanently (`!canAskAgain`) | title `strings.permissions.cameraDeniedTitle`; body `strings.permissions.offBodyScan`; primary `strings.permissions.openSettings` (testID `camera-open-settings`) → app settings (`Linking.openSettings()`); same secondary |

Scrollable so the way on is never pushed off screen at large text.

**Native:** `AVCaptureDevice.authorizationStatus(for: .video)`:
`.notDetermined` → rationale + `requestAccess`; `.denied`/`.restricted` →
blocked + `UIApplication.openSettingsURLString`. Layout:
`ContentUnavailableView` with actions.

### 8.6 QR payload rules (repository)

Source: `src/repositories/qr.ts`.

- Payload format: `inventory://c/<token>` (`QR_URI_PREFIX`, `:29-33`). Tokens
  are generated as 32 lowercase hex chars (`newQrToken` = hex of 16 random
  bytes, `src/core/id.ts:62-64`). **Printed labels in the wild carry this exact
  string; never change it.**
- `parseQrPayload(raw)` (`:41-46`): trim; strip the prefix if present; accept
  only `/^[0-9a-f]{32}$/i`; return the token **lowercased**, else nil. Bare
  tokens from other tooling are accepted. The prefix test is a
  **case-sensitive `startsWith("inventory://c/")`**: `INVENTORY://c/…`,
  `inventory:///c/…` and `com.wystudio.inventory://c/…` are **not** stripped, so
  a QR containing them resolves to `invalid` on the Scan tab (the second
  scheme only works as a system URL open, §3.6). Keep this exact behaviour in
  `parseQrPayload`; do not reuse the URL router's more lenient parsing for scans.
- `resolveScan(raw)` (`:56-90`): invalid → `{kind: invalid, raw}`; else
  ```sql
  SELECT c.* FROM containers c JOIN qr_bindings q ON q.container_id = c.id WHERE q.token = ?
  ```
  no row → `{kind: unknown, token}`; row → `{kind: bound, token, container}`.
- Paired: `POST /v1/qr/scan` with JSON `{ "raw": "<raw>" }` returns the same
  `ScanOutcome` shape (`httpRepositories.ts:319-321`).

---

## 9. QR label screen (`/c/<token>`)

Source: `app/c/[token].tsx` (full), `src/ui/scan/scanRules.ts` (full).

Purpose: a QR label opened from the iPhone Camera (`inventory://c/<token>`) or
handed over by the Scan tab. A linked label replaces this screen with its
container; an unlinked label of ours is linked here to a picked container so
the token is never lost; a failed lookup offers Try again
(`app/c/[token].tsx:28-43`). Presentation: pushed, title `strings.deepLink.title`.

### 9.1 Lookup

- `token = tokenParam(params.token)` (`:45-46`).
- `request = "<token>|<attempt>"`; the screen is "resolving" while it has no
  answer for the current request (`:69-71`). Try again increments `attempt`
  (`:149`).
- On each new request: `qr.resolveScan(token)` (`:76-104`). Unmount cancels
  late answers. It is a one-shot read, deliberately not a refreshing query
  (re-reading would replace the screen twice) (`:40-42`).
  - Success → log `qr_deeplink {outcome: <kind>}`; store; if `bound`: drop-zone
    container → `goToTab('/drop-zone')`, else **replace** this screen with
    `/container/<id>` (`:86-92`).
  - Failure → log error `qr_deeplink_failed {errorClass}`; show the error state.

### 9.2 Rendering

| State | UI | Source |
|---|---|---|
| failed | `ErrorState(cause:, onRetry: attempt += 1)` | `:146-152` |
| no answer yet, or `bound` (until replaced) | skeleton `detail` with label `strings.deepLink.opening` | `:154-163` |
| `invalid` | empty state, icon qr, title `strings.scan.invalidTitle`, body `strings.scan.invalidBody`, primary `strings.common.goToHome` → `goToTab('/')` | `:165-176` |
| `unknown` | heading `strings.deepLink.newTitle`, body `strings.deepLink.newBody`, place picker in mode `bind` with `busyId` | `:178-189` |

### 9.3 Linking (`link(place, token)`, `:106-144`)

1. Only container picks; ignore if a bind is already running (`bindingRef`).
2. `label = labelFor(option)`; `busyId = option.id` (that row shows a spinner,
   the list locks).
3. `existing = qr.getByContainer(option.id)`:
   - local `SELECT * FROM qr_bindings WHERE container_id = ? ORDER BY created_at DESC LIMIT 1` (`qr.ts:92-98`);
   - paired `GET /v1/containers/<id>` → `qrToken` (`httpRepositories.ts:322-339`).
4. `plan = planBind(existing, token, label)`.
5. If the screen was left meanwhile: stop, write nothing (`:119-120`).
6. If `plan.confirm`: ask (destructive confirm, §9.4); No → clear busy and
   guard, stop.
7. If `plan.write`: `qr.bind(token, option.id)`; log `qr_bound`; bump the
   database revision.
   - local bind (`qr.ts:117-140`): reject the drop zone (`throw Error("system_record")`);
     `now = Date.now()` (integer **milliseconds** since epoch, used for both
     `created_at` and `updated_at`); `id = newId()` (lowercase UUID v4 with
     hyphens, `src/core/id.ts:41-54`, `src/core/bytes.ts:11-17`; Swift's
     `UUID().uuidString` is **uppercase**, so lowercase it — data-layer rule);
     in one transaction
     `DELETE FROM qr_bindings WHERE token = ?`,
     `DELETE FROM qr_bindings WHERE container_id = ?`, then
     `INSERT INTO qr_bindings (id, token, container_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?)`.
     The token written is the **lowercased** one from `resolveScan`
     (`outcome.token`), never the raw URL text.
   - paired: `POST /v1/qr/bind` `{ "token", "containerId" }` (`httpRepositories.ts:341-346`).
8. Remember the place as recent (§10.4) — **also when `plan.write` was false**
   (label already linked meanwhile); haptic `success`; if still open,
   **replace** with `/container/<id>`; toast `strings.deepLink.linked(label)`
   (even if she left). `bindingRef`/`busyId` are not reset on success (the
   screen is being replaced) (`app/c/[token].tsx:126-135`).
9. Any error: clear busy and guard; log error
   `qr_bind_failed {errorClass: describeError(cause, "label", "container").kind}`;
   haptic `error`; error toast `linkFailureMessage(cause)`. The label and list
   stay, so trying again is one tap.

`openRef` (`:56-67`): a late answer must not `replace` whatever is in front
(it would replace the tab shell). **Native:** before replacing, check that the
`.qrLabel(token)` route is still the top of the path that pushed it.

### 9.4 Pure rules (`src/ui/scan/scanRules.ts`)

- `labelFor(container)` (`:15-17`): `name` if `name.trimmed()` is non-empty
  (returns the untrimmed name), else `shortCode`.
- `tokenParam(value: String | [String] | nil)` (`:24-27`): first element if an
  array; trimmed; `""` when missing.
- `planBind(existing, token, label)` (`:48-63`):
  - no existing binding → `{write: true, confirm: nil}`;
  - existing token equals `token` case-insensitively → `{write: false, confirm: nil}`
    (linked on another phone meanwhile);
  - else `{write: true, confirm: {title: strings.deepLink.replaceTitle(label), body: strings.deepLink.replaceBody(label), confirmLabel: strings.deepLink.replace}}`.
    Confirm buttons: Cancel `strings.common.cancel`, confirm destructive
    (`src/ui/confirm.ts:25-47`).
- `linkFailureMessage(cause)` (`:69-73`): `describeError(cause, "label", "container").kind`;
  `gone` → `strings.deepLink.containerGone`; else
  `strings.deepLink.linkFailed(kind == .offline)`.

**Native:** confirmation via `.confirmationDialog` or `.alert` with a
`.destructive` button.

---

## 10. Add sheet (`/item/new`) and its logic

Source: `src/ui/add/addSheet.ts`, `src/ui/add/addDraft.ts`, `src/ui/add/WhereList.tsx`
(all full), consumer `app/item/new.tsx` (full). The items area may also cover
`app/item/new.tsx`; this section is authoritative for the `src/ui/add` rules.

### 10.1 Entry points

| From | Params |
|---|---|
| Tab bar Add | none (may restore a draft) |
| Home no-results "Add “q”…" | `name` |
| Home empty states | none |
| Container screen "Add" | `containerId` (`app/container/[id]/index.tsx:207`) |
| Capture, photo stored and nobody waiting for it (single mode, or a `request` whose opener is gone) | **replace** with `containerId`, `photoUri`, `photoThumbUri`, `photoWidth`, `photoHeight`, and `photoBytes` only when the byte size is known (`app/capture/index.tsx:193-210`) |
| Capture "type it instead" (`continueManually`, no `request`) | **replace** with `containerId` only (`app/capture/index.tsx:158-166`); from Quick Snap that is `containerId=drop-zone`, which counts as "opened" (no draft restore) |

`AddParams` (`addSheet.ts:25-33`): `containerId?`, `name?`, `photoUri?`,
`photoThumbUri?`, `photoWidth?`, `photoHeight?`, `photoBytes?` (strings).

### 10.2 Initial state (`initialAddState`, `addSheet.ts:119-153`)

`opened = containerId or name or photoUri is a non-empty string`.

- Not opened **and** a fresh draft exists → restore it:
  `cutOff = draft.suggestion.status in {running, refreshing}`;
  `recognize = cutOff && draft.photo != nil`;
  `suggestion = recognize ? .running : (cutOff ? .idle : draft.suggestion)`;
  `restored = true`.
- Otherwise new: `values = EMPTY_ITEM_FORM` with `name = params.name?.trimmed() ?? ""`;
  `placeId = params.containerId (if non-empty) ?? "drop-zone"`; `picked = nil`;
  `photo = photoFromParams(params)`; `suggestion = photo != nil ? .running : .idle`;
  `showMore = false`; `restored = false`; `recognize = photo != nil`.

`EMPTY_ITEM_FORM = { name: "", category: "", tags: "", quantity: "1", notes: "" }`
(`src/ui/components/ItemForm.tsx:25-31`).

Helpers:

- `toPositiveInt(s)` (`:36-40`): nil/empty → nil; parse number; must be an
  integer > 0, else nil. Tests: `"1400"`→1400; `""`,`"0"`,`"-3"`,`"2.5"`,`"wide"`→nil.
  JS `Number()` also accepts `" 12 "`, `"1e3"`, `"0x10"`; Swift `Int(_:)` does
  not. The only producer is the capture screen (`String(width)`), so plain
  `Int(s)` with `> 0` is acceptable; do not rely on the exotic forms.
- `photoFromParams` (`:43-52`): nil without `photoUri`; `thumbUri` = param or nil
  if empty; `width`/`height`/`byteSize` via `toPositiveInt`.
- `photoFromStored(stored)` (`:55-63`): copies `uri, thumbUri, width, height`;
  `byteSize: nil → nil`.
- `photoFiles(photo)` (`:68-70`): `[]` for nil, else `[uri, thumbUri ?? nil]`
  (both files, so thumbnails are never left behind).
- `hasDetails(values)` (`:73-75`): category, tags or notes non-blank after trim.
- `formHasContent(values, photo, empty)` (`:82-93`): photo present, or name
  non-blank, or `hasDetails`, or `quantity.trimmed() != empty.quantity`. The
  place alone is not content.

### 10.3 Screen structure (from `app/item/new.tsx`)

- Title: place step → `strings.add.placeTitle`; opened for a container (known)
  → `strings.add.titleTo(containerTitle(option))`; else `strings.add.title`
  (`:584-589`).
- Header left: form step → Cancel (§10.6, testID `add-cancel`); place step →
  `strings.add.back` (testID `add-back`) back to the form (`:591-612`).
  Swipe-down disabled while saving (`:596`).
- Places read (key `add-places`): `containers.listAllWithSpace()` and
  `spaces.listWithCounts()` in parallel, joined into `PlaceOption`s
  (`joinPlaceOptions`) (`:187-200`). `PlaceOption = {id, name?, shortCode, visualType, spaceId, spaceName, spaceColor, spaceIcon, itemCount}`
  (`src/ui/placeMatch.ts:6-16`).
- `paramOption` = the opened-for container (ignored if it is the drop zone)
  (`:202-204`). `place = resolvePlace(placeId, options, picked)`;
  `entries = whereEntries(param: paramOption, recentIds, options ?? [:], selectedId: place.id, picked)` (`:205-212`).
- Form step, top to bottom (`:632-828`):
  1. Save problem notice (if the last save failed while the sheet was open).
  2. Restored-draft banner: `strings.add.draft`, action `strings.add.clearDraft`
     (testID `add-draft-clear`) → clear everything (photo deleted, place back to
     drop zone, name refocused) (`:424-436,655-666`).
  3. Name field (testID `item-name`): label `strings.add.nameLabel`, a11y
     `strings.add.nameA11y`, placeholder `strings.add.namePlaceholder`,
     sentence capitalisation, inline error `nameError`; return key "done"
     **saves** (`save(false)`; the keyboard stays up) (`:668-701`). Trailing:
     photo thumbnail 40 pt (`photo.thumbUri ?? photo.uri`; a11y
     `strings.add.photoOptions`, testID `item-photo-options`) → action sheet
     Retake `strings.add.retake` / Remove `strings.add.removePhoto` destructive
     (§10.7), or camera button (a11y `strings.add.addPhoto`, testID
     `item-photo-take`) → `takePhoto()` (§10.7).
  4. "Saved. Add the next one." banner (`strings.add.savedNext`, icon check,
     testID `add-saved-next`, announced) after "Save and add another" without
     photo, until a new name is typed (`:704-711,343-347`). `edit(next)` also
     clears the name error as soon as the name is non-blank.
  5. Suggestion banner, only when there is a photo (§15.4): it is given
     `stale(forName: staleName)` when `staleName = staleSuggestionName(suggestion, typedName)`
     is non-nil (so the stale title shows **the typed name**), else the stored
     `suggestion`. Retry → `suggestion = running`, `runRecognition(photo.uri, typedName or nil)`;
     "Update the other details" (only when stale) → `suggestion = refreshing`,
     `runRecognition(photo.uri, staleName, overwrite: true)` (§10.7)
     (`:713-732`).
  6. "Where it goes": label `strings.add.where`; if the places read failed with
     no data, info banner `strings.add.placesFailed` + Try again
     (testID `add-places-retry`); then `WhereList` (§10.5) (`:734-757`).
  7. "How many" (`strings.add.howMany`): compact quantity stepper,
     `value = parseQuantityInput(values.quantity) ?? 1`, `onChange(n)` sets
     `values.quantity = String(n)` (functional update from the latest values,
     so a hold-repeat never undoes a suggestion that landed meanwhile),
     `itemName = typedName or nil`, committing while typing (Save sits outside
     the scroll view) (`:630,759-777`).
  8. "More details" toggle (label `strings.forms.moreDetails`, a11y
     `strings.forms.moreDetailsA11y(expanded)`, chevron down/right, testID
     `item-more-details`), followed by `ItemDetailsFields` when open. Open when
     `showMore || (hasDetails(values) && detailsKey != collapsedAt)` with
     `detailsKey = [category, tags, notes].joined("\u{0000}")`. Closing sets
     `showMore = false, collapsedAt = detailsKey`; opening sets `showMore = true`.
     So details changed later (by AI) reopen it: AI-changed details are never
     hidden (`:216-218,364-371,781-793`).
  9. "Snap several at once…" (`strings.add.snapSeveral`, icon layers, testID
     `item-snap-several`) → ignored while saving; dismiss keyboard; **replace**
     the sheet with `/capture?containerId=<place.id>&mode=fast`; the draft is
     kept (`:456-461,795-802`).
  10. Bottom bar: `strings.add.saveAndAnother` (secondary, testID
      `item-save-and-add`), `strings.add.save` (primary, a11y
      `saveA11yLabel(place)`, testID `item-save`); each shows a spinner while it
      saves and disables the other (`:805-824`).
- Name is focused on arrival (after the sheet's own `transitionEnd` with
  `closing == false`, fallback 700 ms `ARRIVAL_FALLBACK_MS`, whichever first,
  once) only when the sheet opened **without** a photo (`initial.photo == nil`),
  and only if the sheet is still the focused screen at that moment (not if the
  camera or another sheet is already on top) (`:87-88,287-310`).
- "Where it goes" label is `strings.add.where`; the places-failed banner shows
  only when `places.cause != nil && places.data == nil` (`:734-748`).
- Place step: place picker mode `choose` with the drop zone first and the
  current place selected; picking sets the place (and `picked` for a
  container) and returns to the form with a 180 ms cross-fade; Back / swipe /
  Android back return to the form without changing the place, except while
  revoked (`:313-362,614-628`).

### 10.4 Saving (`save(andAnother)`, `app/item/new.tsx:498-582`)

1. Ignore re-entry (`savingRef`). Validate (`validateItemForm`,
   `src/ui/components/ItemForm.tsx:48-79`; parsed = trimmed name, category
   trimmed or nil, tags split on `,` trimmed and blanks dropped, quantity,
   notes trimmed or nil): if `parsed == nil`: when the name is
   blank set field error `strings.add.nameRequired` (not the form's own
   `strings.forms.itemNameRequired`) and focus the name; **an invalid quantity
   (`parseQuantityInput` → nil) with a valid name makes Save do nothing, silently**
   (no error is surfaced on this sheet); stop. Then `target = place`,
   `addedPhoto = photo` are captured, `saving = 'another' | 'save'`, the save
   problem and the "Saved. Add the next one." banner are cleared.
2. `items.create({containerId: place.id, ...parsed, photo})` (atomic: item,
   photo, tags).
3. Failure: `described = describeError(cause, "save", "container")`; log error
   `item_create_failed {errorClass: described.kind}`; haptic `error`; re-arm
   (`savingRef = false`, `saving = nil`); if the sheet is still in front show
   the save-problem notice (`SaveNotice(cause, subject: "container")`, testID
   `add-save-problem`, pinned above the scroll view, owned by the forms area
   `src/ui/spaces/FormLayout.tsx`), else an error toast with `described.body`.
   Nothing else changes; the draft keeps the typing.
4. Success: log `item_created {hasPhoto, suggestionAccepted, hinted}` where
   `suggestionAccepted = status in {applied, refreshed}`, `hinted = status == refreshed`;
   `clearDraft`; bump revision; haptic `success`; remember the place as recent
   (`rememberPlace`, never the drop zone; keeps 6, most recent first, AsyncStorage
   key `places.recent.v1`, `src/services/places/recentPlaces.ts:5-8,16-23,57-66`);
   record the category.
5. Then:
   - "another", no photo, still in front → re-arm Save, then `startNext()`:
     `values = EMPTY_ITEM_FORM`, `suggestion = idle`, `showMore = false`,
     `collapsedAt = nil`, `restored = false`, scroll to top (animated unless
     Reduce Motion), focus name; place and `picked` are kept; show the inline
     "Saved. Add the next one." (no toast: the keyboard would hide it)
     (`:463-472,551-564`).
   - "another", with photo, still in front → **replace** with
     `/capture?containerId=<target.id>` (no `mode`, so single; no `request`, so
     the shot opens a fresh Add sheet via the capture handoff). Save stays
     locked (the sheet is leaving).
   - otherwise dismiss (if in front) and toast `savedMessage(place)` with action
     `strings.common.undo` (a11y `strings.add.undoA11y(name)`) (9 s toast).
6. Undo (`:474-491`): `items.delete(id)`; delete `result.orphanedPhotoUris` +
   `photoFiles(addedPhoto)`; log `item_deleted`; bump revision; haptic `undo`
   (selection); toast `strings.add.removedAgain`. Failure:
   `kind = describeError(cause, "delete", "item").kind`; log error
   `item_delete_failed {errorClass: kind}`; haptic `error`; error toast
   `strings.add.undoFailed(kind == .offline)`.

### 10.5 "Where it goes" list

`whereEntries` (`addSheet.ts:180-218`), `MAX_RECENT_WHERE = 3` (`:156`):

```
entries = []
if param: append .container(param, source: .param)
append .dropZone
recent = 0
for id in recentIds:
    if recent >= maxRecent: break
    if id == param?.id || id == "drop-zone": continue
    guard let option = options[id] else continue
    append .container(option, .recent); recent += 1
listed = ids of entries
selected = selectedId == "drop-zone" ? nil
           : options[selectedId] ?? (picked?.id == selectedId ? picked : nil)
extras = []
if selected && !listed.contains(selected.id): extras.append(selected)
if picked && !listed.contains(picked.id) && picked.id != selected?.id:
    extras.append(options[picked.id] ?? picked)
entries = extras.map { .container($0, .picked) } + entries
```

`entryId(entry)` (`:221-223`): drop zone → `"drop-zone"`, else the option id.

`resolvePlace(selectedId, options, picked)` (`:237-248`): drop zone →
`{id, nil}`; found in options (or `picked` with that id) → `{id, option}`;
options not loaded (nil) → `{id, nil}` (keep the id); loaded but missing
(deleted elsewhere) → `{"drop-zone", nil}` (the sheet then shows the drop zone
selected).

`containerTitle(option)` (`:251-253`): `name ?? shortCode`.

`saveA11yLabel(place)` (`:256-261`): drop zone → `strings.add.saveA11yDropZone`;
no option → `strings.add.save`; else
`strings.add.saveA11y(option.name ?? strings.a11y.labelCode(spellCode(shortCode)), spaceName)`.

`savedMessage(place)` (`:264-268`): drop zone → `strings.add.savedInDropZone`;
no option → `strings.add.saved`; else
`strings.add.savedIn(containerTitle(option), spaceName)`.

`WhereList` rendering (`src/ui/add/WhereList.tsx:51-133`):

- One radio group (a11y label `strings.add.where`). Rows: drop zone (tray tile,
  `strings.add.dropZone` over `strings.add.sortLater`; a11y
  `"<dropZone>, <sortLater>"`; testID `item-where-drop-zone`) or a container
  (type tile + location line "● Space › Container [CODE]"; a11y
  `strings.picker.optionA11y(label, spaceName, spellCode(code))` where label is
  the name or `strings.entities.unnamedContainer(typeName)`; testID
  `item-where-recent-<id>` for recents, else `item-where-<id>`).
- Selected row: checkmark, selected state. Tapping an unselected row selects it
  with haptic `choice` (`app/item/new.tsx:349-352`); tapping the selected one
  does nothing (`WhereList.tsx:64-66`).
- After the group: "Somewhere else…" (`strings.add.elsewhere`, hint
  `strings.add.elsewhereHint`, chevron, testID `item-where-more`) → place step.

**Native:** `Picker(selection:) { … }.pickerStyle(.inline)` inside a `Form`
section (gives radio semantics and checkmarks), followed by a "Somewhere else…"
button row.

### 10.6 Draft (`src/ui/add/addDraft.ts`)

One in-memory slot `{owner, draft}`; lost on app restart (`:4-13,23`).
`AddDraft = AddDraftState + savedAt` where `AddDraftState = {values, placeId, picked, photo, suggestion, showMore}`
(`addSheet.ts:96-105`).

- `DRAFT_TTL_MS = 30 * 60 * 1000` (`:20`); fresh when `now - savedAt <= TTL`
  (inclusive) (`:25-27`).
- `restorableDraft(now)` (`:33-35`): the slot's draft if fresh, no side effects.
- `discardStaleDraft(now)` (`:38-42`): stale → delete its photo files, clear.
  Called on mount when nothing was restored (`app/item/new.tsx:220-223`).
- `keepDraft(owner, draft?)` (`:51-60`): nil → clear only if this owner wrote it;
  else, if a different draft photo (`slot.photo?.uri != draft.photo?.uri`) is
  being replaced, delete the old photo's files; store `{owner, draft}`. Called on
  every change with the current state when `formHasContent`, else nil
  (`app/item/new.tsx:225-233`).
- `clearDraft(owner)` (`:66-68`): forget without deleting the photo (after a save
  the item owns it; after a discard the sheet deleted it).
- Cancel (`app/item/new.tsx:438-454`): if content, confirm
  (`strings.add.discardTitle`, `strings.add.discardBody`, confirm
  `strings.forms.discard`, cancel `strings.forms.keepEditing`); on discard delete
  the photo files; then `clearDraft`, dismiss. Swipe-down keeps the draft.

**Native:** `@MainActor final class AddDraftStore` (singleton) with the same
API; `owner` = a per-sheet UUID.

### 10.7 Photo and recognition flow in the Add sheet

Source: `app/item/new.tsx:247-285,373-436`. The recognition service and
`applySuggestion` belong to the capture/AI and items areas; the sheet-side state
machine is specified here because nothing else describes it.

`runRecognition(uri, nameHint?, overwrite = false)` (`:247-273`):

1. `recognitionRef = uri` (the photo recognition is running for).
2. `result = await recognizeItem({ imageUri: uri, nameHint })`.
3. If `recognitionRef != uri` now (photo removed/replaced meanwhile): drop the
   answer.
4. `result.status == failed` → `suggestion = failed(reason)`; stop.
5. `values = applySuggestion(values, result.suggestion, overwrite:)` applied to
   the **latest** values (functional update). `applySuggestion`
   (`src/ui/components/ItemForm.tsx:97-114`): `name = current.name || (s.name ?? "")`
   (never overwrites a typed name, not even with `overwrite`); with `overwrite`:
   `category = s.category ?? ""`, `tags = s.tags.joined(", ")`; without:
   `category = current.category || (s.category ?? "")`,
   `tags = current.tags || s.tags.joined(", ")`. Notes and quantity are never touched.
   (`||` is JS truthiness: only the empty string counts as blank, `" "` does not.)
6. `suggestion = (overwrite && nameHint) ? refreshed(forName: nameHint)
   : applied(confidence: s.confidence, forName: s.name ?? "")`.

Who sets `running` / `refreshing` and starts it:

| Trigger | State set first | Call |
|---|---|---|
| Arrival with `initial.recognize` (fresh photo from params, or a restored draft whose recognition was cut off and still has a photo) | already `running` from `initialAddState` | `runRecognition(initial.photo.uri, initial.values.name.trimmed() or nil)` (`:275-285`) |
| Camera returned a photo (`takePhoto`) | `photo = photoFromStored(taken)`, `suggestion = running` | `runRecognition(next.uri, typedName or nil)` (`:400-404`) |
| Banner "Try suggestions again" | `running` | `runRecognition(photo.uri, typedName or nil)` |
| Banner "Update the other details" (stale only) | `refreshing` | `runRecognition(photo.uri, staleName, overwrite: true)` |

`takePhoto()` (`:385-405`): ignored while saving or while the camera is already
open for this sheet (`cameraOpenRef`); dismiss keyboard;
`openForResult<PhotoResult>` → cover `/capture` with
`containerId = place.id, mode = "single", request`; on `nil` (closed without a
photo) nothing changes.

`dropPhoto()` (`:374-379`): `recognitionRef = nil` (cancels a pending answer);
delete both files (`photoFiles(photo)`); `photo = nil`; `suggestion = idle`.

Photo options (`:407-421`): ignored while saving; action sheet with **Retake**
(`strings.add.retake`: `dropPhoto()` then `takePhoto()`) and **Remove**
(`strings.add.removePhoto`, destructive: `dropPhoto()`), plus the system Cancel
(`src/ui/confirm.ts`, `showActionSheet`).

Clear restored draft (`:424-436`, banner action `strings.add.clearDraft`,
banner testID `add-draft`): ignored while saving; `dropPhoto()`;
`values = EMPTY_ITEM_FORM`; `placeId = "drop-zone"`; `picked = nil`;
`showMore = false`; `collapsedAt = nil`; `restored = false`; clear the name
error and the save problem; focus the name.

**Swift tests to write (none in RN):** stale answer dropped after
`dropPhoto`; `overwrite` replaces category/tags but never the name;
`refreshed.forName` is the hint, not the echoed name; typed name survives an
`applied` result.

---

## 11. Onboarding

Source: `app/onboarding.tsx` (full), `src/providers/OnboardingProvider.tsx`,
`src/services/onboarding.ts`.

### 11.1 Completion store

- Key `onboarding.completed.v1`, value `"true"` when done; absent otherwise
  (`src/services/onboarding.ts:3,10-30`).
- Read: `== "true"`; any read error → `false` (show onboarding once more rather
  than block launch).
- Write errors are swallowed.
- Status `loading → pending | completed` (`OnboardingProvider.tsx:6,29-31`).
- `complete()`: set status `completed` **first** (the root gate flips in the same
  tick), then write `"true"` (`:33-36`).
- `replay()`: set status `pending` first, then remove the key (`:38-41`).

**Native:** `@MainActor @Observable OnboardingStore` over `UserDefaults`
(after the one-time AsyncStorage import, §20).

### 11.2 Steps

`welcome → join → joined` (`app/onboarding.tsx:16`). No header; swipe-back
disabled; content column max width 480 pt (iPad) (`:22,228-233`).

Welcome (`:126-190`):

- App mark (72 pt), wordmark `strings.onboarding.brand`, title
  `strings.onboarding.title`.
- Three facts `strings.onboarding.facts[0…2]` with icons search, plus, scan
  (`:19,151-160`) (SF Symbols `magnifyingglass`, `plus`, `qrcode.viewfinder`).
- Buttons:
  - Replaying on a joined phone (`session != nil`): only
    `strings.onboarding.continue` (testID `onboarding-continue`) → finish
    `completed`, step 0. The prop is named `replaying` but the condition is
    **only** `session != nil` (`app/onboarding.tsx:82`); there is no separate
    "is a replay" flag. In-place upgrade consequence: if the Keychain session
    survives while the onboarding flag is absent (iOS Keychain items survive an
    uninstall/reinstall; or the AsyncStorage import failed), the person sees
    Welcome with Continue only. That matches RN; keep it.
  - Otherwise: `strings.onboarding.join` (primary, testID `onboarding-join`) →
    Join step; `strings.onboarding.local` (quiet, testID `onboarding-local`) →
    finish `skipped`, step 0.

Join (`:87-115`): the shared `JoinForm` (household area) with a header of
"Back" (`strings.onboarding.back`, testID `onboarding-back`) → Welcome, title
`strings.household.joinHeading`, body `strings.household.joinBody`. What she
typed (code and name) survives Back → Welcome → Join (`joinDraft`, `:41-43`).
On success: store the household name, go to Joined (`:68-71`). The form's
`hasImportOffer` is ignored here.

Joined (`:192-219`): check badge, title `strings.onboarding.joinedTitle`, body
`strings.onboarding.joinedBody(name)` where name = the joined household's name,
else `session?.householdName ?? ""`; button `strings.onboarding.start`
(testID `onboarding-start`) → finish `completed`, step 1.

`finish(outcome, step)` (`:46-53`): ignore re-entry; `await complete()`; log
`onboarding_finished {outcome, step}`. No navigation call: the root gate swaps
to the tabs.

Android back handling (`:57-66`): not ported.

**Native:** a full-screen view swapped in by `RootView`; a `NavigationStack`
for Welcome → Join is fine, but Join must keep its draft when going back.

---

## 12. Settings

Source: `app/settings.tsx` (full), `src/ui/household/status.ts:22-48`,
`src/ui/household/join.ts:84-90`.

Pushed from Home's gear; title `strings.settings.title`. Nothing on this screen
writes inventory (`:22-31`); the one write is **How it works**, which removes
the `onboarding.completed.v1` preference via `replay()` (§11.1). Every row's
value is spoken with its label.

| Section (header key) | Row | Value | Action | Source |
|---|---|---|---|---|
| `strings.settings.household` (first) | icon server, `strings.settings.household` | joined: `strings.settings.joinedAs(session.deviceName)`; else `strings.settings.thisPhoneOnly` | push Household (testID `settings-household`) | `:41-45,54-64` |
| `strings.settings.onThisPhone`, only if `showBackupRow(paired, syncStatus)` | icon backup, `strings.settings.backup` | `backupSummary(status).value`, signal colour when `tone == signal` | push Backup, except `status == unavailable` → static row (testID `settings-backup`) | `:66-81` |
| `strings.settings.help` | icon info, `strings.settings.howItWorks` | — | `replay()` (testID `settings-replay`) | `:83-91` |
| | icon shield, `strings.settings.privacy` | — | push Privacy (testID `settings-privacy`) | `:93-98` |
| `strings.settings.about` | icon phone, `strings.settings.version` | app version (`Constants.expoConfig.version`, fallback `"0.0.0"`, `src/services/appInfo.ts:4`; currently `0.1.0` from `app.json`) | static | `:102-104` |
| | icon settings, `strings.settings.technical` | — | expands in place (animated), expanded state for a11y (testID `settings-technical`) | `:106-115` |

Technical facts when expanded (`:116-133,145-159`), each one accessibility
element "label, value":

- `strings.settings.environment` → `appConfig.environment` (`development` |
  `preview` | `production`, from `EXPO_PUBLIC_ENV`, `src/services/config.ts:59-63`).
- `strings.settings.schema` → `strings.settings.schemaValue(LATEST_SCHEMA_VERSION)`
  ("v<n>", `n = MIGRATIONS.length`, `src/db/migrations.ts:265`).
- `strings.settings.suggestions` → `strings.settings.suggestionsOn` if a
  recognition endpoint is configured, else `strings.settings.suggestionsOff`.
- `strings.settings.serverAddress` → `serverHost(session?.origin ?? appConfig.householdOrigin)`
  (default origin `https://inventory.wystudio.be`, `src/services/config.ts:72-74`).

Rules:

- `backupSummary(status)` (`status.ts:22-36`): `unavailable` →
  `strings.settings.backupSummary.notConfigured`; `off` → `.off`; `working` →
  `.working`; `error` → `.attention` (tone signal); `idle` → `.notYetRun` when
  `lastBackupAt == nil`, else `.on`.
- `showBackupRow(paired, status)` (`status.ts:45-48`): not joined → always;
  joined → only when state is not `off` and not `unavailable` (#48).
- `serverHost(origin)` (`join.ts:84-90`): **trim**, strip a leading scheme
  matching `/^[a-z][a-z0-9+.-]*:\/\//i`, cut at the first `/`, `?` or `#`
  (`/[/?#].*$/`); fall back to the original (untrimmed) input when that leaves
  nothing. Test: `https://inventory.wystudio.be` → `inventory.wystudio.be`;
  `http://192.168.1.5:8788/` → `192.168.1.5:8788`; `inventory.example` unchanged.

Settings row accessibility (`src/ui/components/SettingsRow.tsx:29-77`): label
`"<label>, <value>"` (or just label), chevron for rows that open a screen,
`expanded` state for the toggle row.

**Native:** `Form` with `Section(header:)`; `NavigationLink { … } label: { LabeledContent(label, value: value) }`
(LabeledContent combines label and value for VoiceOver); the static Backup row
as plain `LabeledContent`; Technical details as a `DisclosureGroup`. App version
from `CFBundleShortVersionString`; environment from a build-configuration
Info.plist key; schema version from the database area.

---

## 13. Privacy

Source: `app/privacy.tsx` (full). Pushed from Settings; title
`strings.privacy.title`. Content follows this build and this phone so it never
promises something untrue (`:30-37`). Parts in order, each a heading plus body
paragraphs (`:38-97`); `paired = session != nil`; `sync` = a backup endpoint is
configured; `recognition` = a recognition endpoint is configured.

| # | Shown when | Heading | Paragraphs |
|---|---|---|---|
| 1 | paired | `householdTitle` | `householdBody` |
| 2 | always | `whereTitle` | `paired ? whereBodyPaired : whereBody`; then `sync ? (paired ? backupOffPaired : backupOff) : (paired ? noBackupServicePaired : noBackupService)` |
| 3 | sync | `backupTitle` | `backupAccount`, `backupPassword`, `backupLocal` |
| 4 | always | `cameraTitle` | `cameraUse`; `paired ? photosPaired : photosLocal`; `photosResized(1400)` (`MAX_IMAGE_DIMENSION`, `src/services/capture/imageScaling.ts:22`); `photosDeleted` |
| 5 | always | `suggestionsTitle` | `recognition ? [suggestionsSent, suggestionsPrivate] : [suggestionsOff]` |
| 6 | always | `diagnosticsTitle` | `diagnosticsBody` |
| 7 | always | `offlineTitle` | `paired ? offlinePaired : offlineBody` |

(All keys under `strings.privacy`.) **Native:** `ScrollView` of headed text
blocks (`.font(.headline)` headings), or a `List` of sections.

---

## 14. Toasts

Source: `src/providers/ToastProvider.tsx` (full), `src/ui/components/Toast.tsx` (full).

Purpose: confirm writes that finished where she is no longer looking ("Saved
in …" with Undo after a sheet closes; a quantity that did not save in a long
list) (`ToastProvider.tsx:69-79`).

API: `show({message, tone = .info | .error, action?: {label, onPress, accessibilityLabel?}, duration?}) -> id`,
`dismiss(id)` (`ToastProvider.tsx:17-42`).

Queue rules (`ToastProvider.tsx:65-239`):

- One toast at a time; ids `"toast-<n>"` from a global counter.
- A new toast replaces the current one **except** when the current one is an
  error shown less than 1500 ms ago (`ERROR_HOLD_MS`). Then the newcomer waits in
  a single pending slot: the newest waiting toast wins, except a waiting error is
  never replaced by an info. One hold timer fires at `1500 - heldFor` ms and
  presents the pending toast (`:194-207`).
- Life: `duration ?? (action ? 9000 : 5000)` ms, doubled while VoiceOver runs
  (`:164-165`). On expiry: leave (exit animation 120 ms), then remove.
- `dismiss(id)`: drops it from the pending slot if waiting, and leaves if
  current (`:216-222`).
- Touch down pauses the life timer, keeping the remaining time; touch up/cancel
  resumes with `max(remaining, 2500)` ms (never gone the instant a finger lifts)
  (`:224-239`; `Toast.tsx:159-161`).
- Presenting announces it to VoiceOver, queued behind current speech:
  `message`, or `"<message>, " + strings.a11y.availableAction(action.label)`
  (`:170-177`).

Card (`Toast.tsx:58-224`):

- Enters with a 160 ms fade and 8 pt rise (no rise with Reduce Motion), leaves
  with a 120 ms fade.
- Swipe down: the drag starts after 6 pt mostly-vertical movement; release
  beyond 24 pt dismisses, otherwise it springs back (`:18-20,98-113`).
- Action button (testID `toast-action`): on tap runs `action.onPress()` **and
  then dismisses the toast** (`dismiss(id)` → leave); runs **once** even if
  tapped again while fading (per-toast guard); disabled (and announced
  disabled) while leaving; a11y label `action.accessibilityLabel ?? label`
  (`:128-141,194-224`).
- Close button: a11y `strings.a11y.dismissToast`, testID `toast-dismiss`. Card
  testID `toast`.
- A toast that is leaving (120 ms exit) is still "current" until removed, so a
  newcomer that arrives **during** an error's exit animation (and within that
  error's first 1500 ms) is still held until the 1500 ms are up; once the error
  has been removed, newcomers present at once (`ToastProvider.tsx:125-145,191-194`).
- `ToastProvider` is mounted inside the root navigator **after** the boot gate
  (`app/_layout.tsx:154-160`), so no toast can exist on the boot / boot-failed
  screens; it wraps both onboarding and the tabs.
- Error tone: warning icon, signal edge, accessibility role alert (`:115-119,158,173`).
- Max width 480; at large text the message keeps the full width and the buttons
  wrap under it; the message is never truncated (`:120-126,174-189,261-264`).
- Position: `bottom = (focused screen's tab bar / bottom bar height, else bottom safe area) + 12`
  (`Toast.tsx:17-18,29`; `ToastProvider.tsx:241-246,286-295`).

Toasts raised in this area: Add saved + Undo, removed again, undo failed,
save failed after the sheet closed (§10.4); label linked / link failed (§9.3);
a row quantity that did not save (`strings.quantity.notSavedNamed(name, offline)`,
error) (`src/ui/components/ItemRow.tsx:162-168`).

**Native:** no stock control. `@MainActor @Observable ToastCenter` with exactly
these rules (Task-based timers with cancellation), drawn in the passthrough
overlay window (§2.2) as a Liquid Glass capsule/card (`.glassEffect()`).
VoiceOver: `UIAccessibility.isVoiceOverRunning` and its change notification;
announcement via `AccessibilityNotification.Announcement` on an
`AttributedString` with `accessibilitySpeechQueueAnnouncement = true`. The
"chrome height" registry becomes: tab bar height when a tab root is in front,
a sheet's bottom bar height when one registers, else the safe area. Write unit
tests for the queue (none exist in RN, §21).

---

## 15. Shared components → stock SwiftUI

### 15.1 Mapping table

| RN component | Behaviour to keep | SwiftUI |
|---|---|---|
| `TabBar` (`src/ui/components/TabBar.tsx`) | §4 | `TabView` + `Tab`, `.badge`; Add per Q1 |
| `ScreenFrame` (`src/ui/components/ScreenFrame.tsx:23-65`) | connection banner at the top of every non-camera screen (never scrolls away); content max 640 pt on iPad | `.safeAreaInset(edge: .top) { ConnectionBanner() }`; readable width via `.frame(maxWidth: 640)` or `.contentMargins` |
| `TabRootHeader` (`ScreenFrame.tsx:81-98`) | big title, actions, subtitle; actions wrap under the title at large text | `.navigationTitle` (large) + toolbar + `.navigationSubtitle` (iOS 26) |
| `SearchButton` (`ScreenFrame.tsx:104-114`) | a11y `strings.a11y.searchHousehold`, hint `strings.a11y.searchHint`; `focusSearch()` | toolbar `Button { router.focusSearch() } label: { Image(systemName: "magnifyingglass") }` |
| `SearchField` (`src/ui/components/SearchField.tsx`) | §5.3 | `.searchable` on Home; picker filter via `.searchable` in the picker's stack |
| `Toast` / `ToastProvider` | §14 | custom overlay window |
| `Banner` (`src/ui/components/Banner.tsx:47-127`) | tone info/warning (icon defaults to `info` / `warning` glyph), optional title, message, primary and secondary actions (each `{label, onPress, loading?, accessibilityHint?, testID?}`; with a secondary the primary becomes bordered, otherwise both are quiet), optional dismiss (`strings.common.dismiss`); `live` defaults to `polite`; announces `"<title>. <message>"` (or the message) on iOS when it appears or that text changes, unless `live: off` | a list row / section: `Label` + `Text` + `.buttonStyle(.bordered/.borderless)`; post an announcement on appear / text change when `live != off` |
| `SuggestionBanner` (`src/ui/components/SuggestionBanner.tsx:45-129`) | §15.4 | same as Banner, `sparkles` / `pencil` symbols |
| `EmptyState` (`src/ui/components/EmptyState.tsx:36-88`) | title, body, optional icon, primary, secondary (quiet under a primary, bordered when alone) | `ContentUnavailableView { Label(title, systemImage:) } description: { Text(body) } actions: { … }` (RN aligns top-leading; Q6) |
| `ErrorState` (`src/ui/components/ErrorState.tsx:41-97`) | words from `describeError` (never raw codes); title/body overrides; "Try again" (`strings.common.tryAgain`, icon refresh) bordered; optional secondary; announces the title on iOS; assertive live region | `ContentUnavailableView` with `arrow.clockwise` and a Try again button; post announcement |
| `Skeleton` (`src/ui/components/Skeleton.tsx:90-137`) | appears only after 180 ms; static (no shimmer); one a11y element, role progress, label `strings.a11y.loading` or override, polite | placeholder rows with `.redacted(reason: .placeholder)` shown after a 180 ms delay, `.accessibilityElement(children: .ignore)` + label |
| `SpaceTile` (`src/ui/components/SpaceTile.tsx:35-78`) | the space's stored icon (trimmed; emoji or letters, not scaled, one line, clipped) on an **opaque** 24 % mix of its colour into the surface colour (`spaceTint`, so adjacent text keeps measured contrast) with a 1 pt edge of the colour at 45 % alpha; invalid/missing colour → `safeColor` fallback (`src/ui/color.ts:15-23,63-77`, design area); empty icon → home glyph at half size; sizes 32/48/56/64; decorative | small custom view: `Text(emoji)` on `RoundedRectangle().fill(mix(color, surface, 0.24))` with a stroke, `.accessibilityHidden(true)`; port `spaceTint`/`safeColor` with `src/ui/__tests__/color.test.ts` (design area) |
| `TypeTile` (`SpaceTile.tsx:89-115`) | container type glyph; decorative | SF Symbol per type in a small rounded square |
| `SpacePip` (`src/ui/components/SpacePip.tsx:19-37`) | space colour dot with a ring; never the only signal (name follows) | `Circle().fill(color).overlay(Circle().stroke(.separator))`, hidden from a11y |
| `StatusPill` (`src/ui/components/StatusPill.tsx:16-29`) | white text on a dark pill over the camera; optional polite live region | `Text` in a capsule with `.glassEffect()` / `.ultraThinMaterial` |
| `ItemRow` (`src/ui/components/ItemRow.tsx`) | §15.2 | list row; chip as `Button`; inline `Stepper` |
| `Row` (`src/ui/components/Row.tsx:61-156`) | a pressable row with leading, text column, aside, chevron; a control (`tool`) is a **sibling** of the pressable area, never inside it (two VoiceOver stops; tapping the control never opens the row); at large text the control drops below the text | `HStack { NavigationLink/Button { content }; control }`; `ViewThatFits` or Dynamic Type check for stacking |
| `SettingsRow` (`src/ui/components/SettingsRow.tsx:29-77`) | §12 | `LabeledContent` in `NavigationLink` / `DisclosureGroup` |
| `StatusPill`, `Reticle`, `ScanPanel`, `CameraButton` (`app/(tabs)/scan.tsx:52-139`) | camera overlays | material/glass overlays; `.buttonStyle(.glass)` (iOS 26) |
| `DropZoneCard` | §5.5 | section with header text, overlapping thumbnails (`HStack(spacing: -16)`), bordered + borderless buttons |
| `TotalLine` | §5.7 | `Text` concatenation / `AttributedString` |
| `WhereList` | §10.5 | inline `Picker` |
| `Sheet`, `sheetCell`, `Section` (`src/ui/components/Sheet.tsx`) | bordered grouped lists; section title with count | `List(.insetGrouped)`, `Section { } header: { HStack { Text(title); Text(count) } }` |
| `QrScanner` | §8.4 | `DataScannerViewController` / AVFoundation wrapper |
| `CameraPermission` | §8.5 | `ContentUnavailableView` + actions |
| `BootScreen` | §2 | custom view, mark + delayed caption |

### 15.2 `ItemRow`

Source: `src/ui/components/ItemRow.tsx`.

- Two implementations: chip rows own a quantity hook; others do not
  (`:295-302`). Default tool is `chip`.
- Name: the item's name (up to 3 lines) with search terms highlighted; an
  unnamed item shows `strings.entities.unnamedItem` in secondary colour
  (`:50-69`).
- Highlighting (`src/ui/components/AppText.tsx:107-115`): only terms of length
  > 1 (JS UTF-16 length); regex-escaped; case-insensitive; matched parts get the
  mark background. Spoken text is unchanged.
- Second line (`:75-110`): `where` (default) → location line (pip, "Space ›
  Container", code tape; drop zone → tray + `strings.where.dropZone` +
  `strings.where.notFiledYet`) (`src/ui/components/LocationLine.tsx:88-180`);
  `detail` → category; `added` → see §7.2. With `tool` file or delete the
  quantity is folded into the second line (`:244,290`). Exact rule: `lead` =
  nothing when the folded count is absent or 1, else `×N` (`strings.rows.times`)
  or `strings.rows.noneLeft` (signal) at 0; `rest` = category for `detail`;
  for `added`: no fold → `strings.rows.added(ago)` ("Added 5 minutes ago"),
  fold with a lead → the bare lowercase `ago` ("×3 · just now"), fold without
  a lead → `strings.rows.addedShort(ago)` (first letter capitalised, "Just now");
  joined by `strings.rows.separator` (" · "); nothing at all when both are empty.
  `ago` is `src/i18n/format.ts:34-44` (i18n area).
- testIDs: row `item-row-<id>` (overridable), chip `qty-chip-<id>`.
- Row a11y: label `strings.rows.itemA11y(displayName, whereSpoken(item), quantitySpoken(q))`
  ("Drill. In Garage, Tool chest, label C A B, J 9 2 R. Quantity 3."), hint
  `strings.a11y.opensItem` (`:127-129,213-215,285-287`). `whereSpoken`,
  `quantitySpoken`, `spellCode` are in `src/ui/a11y.ts:23-47`.
- Tools:
  - `chip` (`:143-223`): quantity chip at the end of the name line (`×N`, or
    `strings.rows.noneLeft` in signal at 0; "×1" shows too); a11y
    `strings.quantity.chipA11y(name, n | strings.quantity.noneLeftValue)`, hint
    `strings.quantity.chipHint`, expanded state (`src/ui/components/QuantityChip.tsx:25-76`).
    Expanded: large stepper + `strings.quantity.done` under the row. Quantity
    saves via `useSavedQuantity` (items area); failures → error toast
    `strings.quantity.notSavedNamed(name, offline)` unless the parent handles it.
  - `stepper`: compact saved stepper, 48 pt thumbnail.
  - `file`: "File…" (§7.2).
  - `delete`: trash button, a11y `strings.rows.deleteA11y(name)` or
    `strings.rows.deletePhotoA11y` when unnamed, testID `review-delete-<id>`.
  - `none`: `×N` / "None left" badge (hidden from a11y; nothing for 1).
- Thumbnail 56 (48 beside a stepper or in the stacked layout) or 76.
- Memo comparator includes place fields because renaming a space or container
  does not change the item's `updatedAt` (`:304-343`). Natively, value-type
  rows rebuild automatically; if rows are `Equatable`, include those fields.

**Native for the chip:** keep parity: a `Button` showing "×N" that toggles an
inline `Stepper` row under the item (one at a time per list). A `Menu` or swipe
action alone would lose the "two taps from a search result" behaviour
(`fe6e940`, `QuantityChip.tsx:18-24`).

### 15.3 Place rows

See §5.7 and `src/ui/components/PlaceRows.tsx`. Space row tile 56 on Spaces, 48
in search.

### 15.4 Suggestion banner states

`SuggestionState` (`src/ui/components/SuggestionBanner.tsx:5-19`): `idle` |
`running` | `applied{confidence, forName}` | `stale{forName}` | `refreshing` |
`refreshed{forName}` | `failed{reason}`.

| State | Banner | Source |
|---|---|---|
| idle | none | `:55` |
| running / refreshing | sparkle; message `strings.suggestions.running` / `.refreshing` | `:57-69` |
| applied / refreshed | sparkle; title `strings.suggestions.applied` / `.refreshed(forName)`; message `strings.suggestions.check` | `:71-84` |
| stale | sparkle; not announced; title `strings.suggestions.stale(forName)`; message `.staleBody`; action `.update` (hint `.updateHint`) | `:86-113` |
| failed | pencil (`edit` glyph); title `strings.suggestions.failed`; message `strings.suggestions.failedBody[reason]`; action `strings.suggestions.retry` unless reason is `not_configured` | `:115-128` |

`RecognitionFailureReason` (`src/services/ai/contract.ts:22-31`), each with a
`failedBody` entry: `not_configured`, `offline`, `timeout`, `rate_limited`,
`server_error`, `malformed_response`, `unsupported_version`, `low_confidence`,
`unrecognized`. Every state except `stale` uses the Banner default (`polite`, so
it is announced on iOS); `stale` is `live: off`. In the Add sheet the `stale`
state is synthesised by the screen with `forName` = the **typed** name (§10.3).

`staleSuggestionName(state, typedName)` (`:30-37`): only for `applied` /
`refreshed`; typed name trimmed; nil if empty or equal to `forName`; else the
trimmed typed name.

---

## 16. Hooks and the screen-data contract

### 16.1 `useInventoryQuery` contract (screens rely on it)

Source: `src/hooks/useInventoryQuery.ts:52-126`. Re-reads on mount, on screen
focus, after any write (revision bump) **while focused** (background screens
catch up on focus), and on `reload()`. Returns `data` (kept across refreshes;
a failed refresh keeps the previous data **only for the same key**), `loading`
(the newest request has not settled), `cause` (only for the newest request),
`refreshFailed = failed && data != nil`. **Key change:** `data` is the last
settled value regardless of key, so after a key change (Home's `recent:12` →
`recent:40`) the old key's rows are still returned while the new key loads; if
the new key's read *fails*, `data` becomes nil (old key's data dropped). This
is why Home keeps `shownRecent` (§5.1). `DropZoneProvider` lives in the tabs
layout, so its "focused" means "the tab shell is the top of the root stack",
whichever tab is selected. Owned by the data-layer area; a native
`QueryModel` must reproduce these flags because every state table above uses
them.

### 16.2 `useDelayedFlag(active, ms = 180)`

True only after `active` has stayed true for `ms`; resets at once when
`active` goes false (`src/hooks/useDelayedFlag.ts:12-24`). Native: a small
`DelayedFlag` helper driven by `.task(id: active) { try await Task.sleep(for: .milliseconds(ms)); flag = true }`.

### 16.3 `useNow(intervalMs = 60_000)`

Current time, ticking every `intervalMs` only while the screen is focused;
catches up immediately on refocus (`src/hooks/useNow.ts:11-27`). Native:
`TimelineView(.periodic(from: .now, by: 60))` or a timer started in `onAppear`.

### 16.4 `useSearch`

§5.6. Native: `@MainActor @Observable SearchModel` with `query`, `settled`,
`run` (revision + nonce), a cancellable `Task` with the 200 ms debounce, and the
same derived outputs. Write tests (none in RN).

### 16.5 `usePullToRefresh(loading, reload)`

Spinner only for a user pull; the pull ends when `loading` goes false
(`src/ui/spaces/usePullToRefresh.tsx:14-39`). Native: `.refreshable` awaiting
completion.

### 16.6 `useCollapsingTitle(title)` (detail screens)

The header shows nothing until the in-content title has scrolled up past its
own bottom edge, then shows the title and a header shadow; updated only when
the crossing changes, in a layout effect so no frame shows the wrong title
(`src/hooks/useCollapsingTitle.ts:15-44`). Used by space, container and item
detail screens. Native: `.navigationTitle(title)` with
`.navigationBarTitleDisplayMode(.large)`; the system collapse replaces this
hook. (RN avoided large titles because iOS 26 hides them under a custom header
background, `app/_layout.tsx:125`; not an issue natively.)

### 16.7 `searchFocus`, `routeResult`, `navigation`

§3.3-§3.5.

---

## 17. Accessibility catalogue (this area)

| Element | Label / hint / trait | Source |
|---|---|---|
| Tab items | tab label; Drop zone with badge: `"Drop zone, " + strings.tabs.waitingA11y(n)` | `TabBar.tsx:126-131` |
| Add slot | label `strings.tabs.addA11y`, hint `strings.tabs.addHint`, custom action `strings.tabs.quickSnapAction` | `TabBar.tsx:183-189` |
| Home gear | `strings.home.settings` | `app/(tabs)/index.tsx:416` |
| Search field | `strings.a11y.searchHousehold`, search trait | `SearchField.tsx:113-114` |
| Clear search | `strings.common.clearSearch` | `SearchField.tsx:125` |
| Search buttons | `strings.a11y.searchHousehold`, hint `strings.a11y.searchHint` | `ScreenFrame.tsx:104-114` |
| "Show more" | `strings.home.recentMoreA11y` | `app/(tabs)/index.tsx:685` |
| Unpaired "Not now" | hint `strings.home.unpaired.notNowHint` | `app/(tabs)/index.tsx:596` |
| Section titles, drop-zone card heading | header trait | `Sheet.tsx:113-117`, `DropZoneCard.tsx:45` |
| Dimmed older results | hidden from VoiceOver, not interactive | `app/(tabs)/index.tsx:703-712` |
| Search summary | announced on the search key, not live | §5.10 |
| Item rows / chips / File… / delete | §15.2, §7.2 | `ItemRow.tsx` |
| Space row | `strings.rows.spaceA11y(name, counts)` | `PlaceRows.tsx:42` |
| Container row | `strings.rows.containerA11y(...)` | `PlaceRows.tsx:100-106` |
| New space row / `+` | `strings.spaces.newSpace` | `app/(tabs)/spaces.tsx:47,101` |
| Scan panels | error assertive, busy polite; iOS announces non-hint panels | `app/(tabs)/scan.tsx:57-77` |
| Torch | `strings.camera.torchState(on)`, selected state | `QrScanner.tsx:152-154,197-200` |
| Reticle, tiles, pips | hidden | `QrScanner.tsx:236-243`, `SpaceTile.tsx:47-48,95-96`, `SpacePip.tsx:23-24` |
| Skeletons | one element, progress role, `strings.a11y.loading` or `strings.deepLink.opening` | `Skeleton.tsx:99-105`, `app/c/[token].tsx:159` |
| Boot caption | polite live region | `BootScreen.tsx:22` |
| Error states | title announced on iOS | `ErrorState.tsx:60-62` |
| Banners | announced on iOS unless `live: off` (unpaired notice, connection banner, stale suggestion are off) | `Banner.tsx:65-69` |
| Toasts | queued announcement with "<action> available"; error = alert | §14 |
| Where list | radio group labelled `strings.add.where`; rows radio with selected state | `WhereList.tsx:56,76-86` |
| Save button | `saveA11yLabel(place)` | `app/item/new.tsx:817` |
| Settings rows | `"<label>, <value>"`; expanded state | `SettingsRow.tsx:69-70` |
| Technical facts | one element each, label then value | `app/settings.tsx:149-156` |
| Onboarding facts | plain text | `app/onboarding.tsx:151-160` |

Reduce Motion: layout animations skipped (`src/ui/motion.ts:94-100`), toast
rise and reticle lock wait become 0, reveal scroll not animated.
Large text (RN `stacked` at font scale ≥ 1.35 or width < 360,
`src/hooks/useLayoutScale.ts:13-16`, `src/ui/tokens.ts:178-179`): controls wrap
under text. Native: Dynamic Type and `ViewThatFits`; do not port the
thresholds.

---

## 18. Haptics catalogue (this area)

Source: `src/ui/haptics.ts:15-34`. All fire-and-forget.

| Name | RN call | When (this area) | SwiftUI `.sensoryFeedback` |
|---|---|---|---|
| `tap` | impact light | Add slot pressed | `.impact(weight: .light)` |
| `longPress` | impact medium | Add slot long-pressed (Quick Snap) | `.impact(weight: .medium)` |
| `choice` | selection | search cleared; Where list choice; place picker pick | `.selection` |
| `undo` | selection | Add undone | `.selection` |
| `success` | notification success | label resolved to a container (Scan); label linked; item saved | `.success` |
| `error` | notification error | Scan lookup failed or not ours; link failed; save failed; undo failed; quantity not saved | `.error` |
| `warning` | notification warning | (conflicts, other areas) | `.warning` |
| `step`, `reachedZero` | selection / impact light | quantity steppers (items area) | `.selection` / `.impact(weight: .light)` |

---

## 19. Telemetry events emitted here

Payload keys are filtered by an allowlist (`src/services/telemetry/index.ts:23-66`).
Every `errorClass` is a `describeError(...).kind` value (`offline | revoked |
conflict | gone | photo | server | local`, `src/ui/errors.ts:5`), computed with
these arguments: `qr_scan_failed` and `qr_deeplink_failed` → `describeError(cause)`
(context `read`, subject `list`); `qr_bind_failed` →
`describeError(cause, "label", "container")`; `item_create_failed` →
`describeError(cause, "save", "container")`; `item_delete_failed` →
`describeError(cause, "delete", "item")`.

| Event | Kind | Payload | Source |
|---|---|---|---|
| `search_performed` | event | `termCount`, `resultCount`, `queryLength` | `src/hooks/useSearch.ts:100-106` |
| `qr_scan` | event | `outcome: bound \| unknown \| invalid` | `app/(tabs)/scan.tsx:234,242,248` |
| `qr_scan_failed` | error | `errorClass` | `app/(tabs)/scan.tsx:226` |
| `qr_deeplink` | event | `outcome: <ScanOutcome kind>` | `app/c/[token].tsx:87` |
| `qr_deeplink_failed` | error | `errorClass` | `app/c/[token].tsx:96` |
| `qr_bound` | event | — | `app/c/[token].tsx:128` |
| `qr_bind_failed` | error | `errorClass` | `app/c/[token].tsx:140` |
| `onboarding_finished` | event | `outcome: completed \| skipped`, `step: 0 \| 1` | `app/onboarding.tsx:52` |
| `permission_result` | event | `permission: camera`, `outcome: granted \| denied` | `src/ui/components/CameraPermission.tsx:97-100` |
| `item_created` | event | `hasPhoto`, `suggestionAccepted`, `hinted` | `app/item/new.tsx:538-542` |
| `item_create_failed` | error | `errorClass` | `app/item/new.tsx:525` |
| `item_deleted` | event | — | `app/item/new.tsx:481` |
| `item_delete_failed` | error | `errorClass` | `app/item/new.tsx:487` |

---

## 20. Device preferences and in-memory state

Persisted by the RN app (AsyncStorage default export = **legacy** storage,
`node_modules/@react-native-async-storage/async-storage/src/index.tsx`): on iOS a
JSON manifest at
`Library/Application Support/com.wystudio.inventory/RCTAsyncLocalStorage_V1/manifest.json`;
values up to 1024 chars (`RCTInlineValueThreshold`) are inline as strings, longer
ones are stored with a JSON `null` in the manifest and the value in a separate
file named by the MD5 hex of the key in the same directory
(`node_modules/@react-native-async-storage/async-storage/apple/legacy_storage/RNCAsyncStorage.mm:17-21,129-179,507-510,631-650`).
Every value is a **string** (the manifest is `{ "<key>": "<string>" | null }`).
The native app must import these once, before first use (storage-migration
area):

| Key | Value (exact string) | How RN reads it | Owner | Read by (this area) |
|---|---|---|---|---|
| `onboarding.completed.v1` | `"true"` or absent | completed **iff** the value `=== "true"` (any other value, absent, or a read error → not completed) | `src/services/onboarding.ts:3,10-17` | root gate (§2, §11) |
| `notice.unpaired.dismissed.v1` | `"1"` or absent | dismissed **iff** `=== "1"`; read error → not dismissed | `src/ui/home/unpairedNotice.ts:4,21-28` | Home notice (§5.5) |
| `places.recent.v1` | JSON array of container-id strings, most recent first, max 6, never `"drop-zone"` | `JSON.parse`; non-array → `[]`; non-string entries dropped; first 6 kept; any error → `[]` | `src/services/places/recentPlaces.ts:5-8,40-54` | Where list, place pickers |
| `categories.recent.v1` | JSON array of category strings, most recent first, trimmed, de-duplicated case-insensitively (`trim().toLowerCase()`), max 20 (`MAX_SAVED`) | `JSON.parse`; non-array ignored; non-strings dropped; merged behind anything saved this session; any error → no suggestions | `src/ui/categoryMemory.ts:3-5,45-73` | written by `recordCategory` after an Add (§10.4); `rememberCategories` (Home recent, Drop zone, search) is **memory only** and never persisted |

Native: the one-time import is owned by `02-device-storage-migration.md` §5.4.
It copies these keys into `UserDefaults` **verbatim as the same strings under
the same key names** (no typed `Bool`), and the native readers apply the same
exact-string tests (`"true"`, `"1"`) and the same tolerant JSON parsing on
read. Never interpret e.g. `"True"` or `"yes"` as completed. Keeping raw
strings lets every RN read rule and test port one-to-one; if a store wants a
typed accessor, wrap the string, do not rewrite the stored value.

Secure storage read here: `household.session.v1` (`{origin, token, deviceId, deviceName = "This phone", householdName = "Home"}`,
`src/services/household/session.ts:5-26`); Home and Settings read
`householdName`, `deviceName`, `origin`. Owned by the household area.

Memory only (not persisted, fine to keep in memory natively): the Add draft
(§10.6), pending route results (§3.4), the search-focus request (§3.5), the
toast queue, Home's `recentLimit`, expanded chip and scroll position.

---

## 21. Tests to port (Swift Testing)

Each line: file › test name: what it asserts.

`src/ui/home/__tests__/homeList.test.ts`

- householdCounts › adds the drop zone’s items but not its container: `[{4,21},{9,20}]`, dz 4 → `{2, 13, 45}`.
- householdCounts › counts an empty household as nothing: `([], 0)` → `{0,0,0}`.
- householdCounts › reads as one sentence: `summary(5,13,45)` = "5 spaces, 13 containers and 45 items."; `(1,1,1)` = "1 space, 1 container and 1 item.".
- nameTotals › adds up a name kept in two containers, ignoring case and spaces: "AA batteries" 12 (c1) + " aa Batteries " 2 (c2) → `[{AA batteries, 14, 2}]`; "Drill" excluded.
- nameTotals › says none are left when every place is empty: two zero-quantity "Printer ink" (c1, drop-zone) → `{0, 2}`; `totalNone` = "“Printer ink”: none left in any of 2 places".
- nameTotals › counts places, not items, and needs a second place: two "Screws" in c1 → `[]`; plus one in c2 → `{16, 2}`.
- nameTotals › never totals unnamed items: `""`, `"  "` → `[]`.
- nameTotals › keeps the order the names first appear in: Tape, Glue.
- idleEntries › shows the notice, the card and then Recently added with sheet positions: kinds `notice, dropZone, title, item×3, more`; title `{Recently added, 3, first: false}`; positions 0/3, 1/3, 2/3.
- idleEntries › leaves out the card when nothing is waiting, and the section when nothing is stored: → `[]`.
- idleEntries › puts the section first when nothing comes before it: title `first: true`.
- idleEntries › shows a status in place of the list, and the stale-data notice on top: `refreshFailed, dropZone, status`.
- resultEntries › orders items, places, then items kept in those places: `summary, title, item, item, title, place, place, title, item, item`; summary "4 items and 2 places found"; titles Items(first), Spaces and containers, Kept in those places.
- resultEntries › gives every entry its own key, even an id that is both a place and a row.
- resultEntries › puts the totals at the top of the items: `title, totals, item, item`, totals `{AA batteries, 14, 2}`.
- resultEntries › starts with the first section that has anything: `summary, title(places, first), place, title, item`; "1 item and 1 place found".
- resultEntries › leaves the summary to the section title when there is one section: `title, item, item`; places only → `title(count 1, first), place`.
- resultEntries › says nothing was found as a status, not an empty list: `[status noResults]` even with refreshFailed.
- resultEntries › keeps the results under the stale-data notice when a refresh failed: starts `refreshFailed, title` / `refreshFailed, summary`.
- splitMatches › keeps each kind in the order the search returned it.
- search copy › summarises what was found: (3,1) "3 items and 1 place found", (1,0) "1 item found", (0,0) "Nothing found".
- search copy › reads the total line as one sentence: "“AA batteries”: ×14 in 2 places".

`src/ui/add/__tests__/addSheet.test.ts`

- params › reads positive whole numbers only (cases in §10.2).
- params › turns capture params into a photo: `photoBytes: "x"` → `byteSize nil`; width 1400, height 1050.
- params › takes a stored camera photo, dropping an unknown size.
- params › lists both files of a photo, so the thumbnail is never left behind: `[]`, `[a, b]`, `[a, nil]`.
- content › counts typing, a changed quantity and a photo, not blanks.
- content › opens the details when any of them holds something.
- initialAddState › starts empty in the drop zone from the tab bar (full expected struct).
- initialAddState › starts in the container it was opened for, with a name from search.
- initialAddState › recognises a photo from the camera on arrival (`running`, `recognize`).
- initialAddState › restores a draft only on a plain open (containerId or name params override it).
- initialAddState › restarts recognition that was cut off, and drops it without a photo.
- initialAddState › keeps an applied suggestion as it was.
- whereEntries › offers the drop zone and up to three recent places that still exist: `drop, recent:shelf, recent:bin, recent:bag`.
- whereEntries › puts the container it was opened for first, without repeating it.
- whereEntries › shows a place picked from the full list on top (`picked:new`; `picked:crate`).
- whereEntries › keeps a picked place listed after choosing another one (`picked:crate, picked:new, drop`).
- whereEntries › does not repeat a picked place that is already listed.
- resolvePlace › knows the drop zone and listed containers.
- resolvePlace › keeps the id while the list loads, and a container just made.
- resolvePlace › falls back to the drop zone for a container that is gone.
- labels › names a container by its name, or the code on its label.
- labels › says where Save puts the item: "Save to the drop zone"; "Save in Drawer by the oven, Kitchen"; "Save in label B I N, 4 F 2 A, Loft"; "Save".
- labels › reports where it was saved: "Saved in the drop zone."; "Saved in Drawer by the oven (Kitchen)."; "Saved in BIN-4F2A (Loft)."; "Saved.".

`src/ui/add/__tests__/addDraft.test.ts` (photo deletion mocked)

- addDraft › restores a draft for half an hour, then not (boundary inclusive at exactly 30 min).
- addDraft › deletes a stale draft’s photo, both files, and leaves a fresh one.
- addDraft › deletes a replaced draft’s photo unless the new draft carries it.
- addDraft › lets only the sheet that wrote the draft clear it (and `clearDraft` never deletes the photo).

`src/ui/scan/__tests__/scanRules.test.ts`

- labelFor › uses the name, or else the code on the label (`"   "` → code).
- tokenParam › reads one token from the route (trims).
- tokenParam › keeps the first of a repeated parameter.
- tokenParam › is empty when there is nothing to read (`nil`, `[]`).
- planBind › links straight away when the container has no label.
- planBind › asks before retiring the sticker the container already has (exact title/body/"Replace").
- planBind › writes nothing when this label was linked to it meanwhile (case-insensitive).
- planBind › never says "Move this label?" for a replacement.
- linkFailureMessage › says to check the connection when the home server did not answer (`HouseholdHttpError(0,"offline")`, `(530,"http_530")`).
- linkFailureMessage › says the container is gone when it was deleted elsewhere (`404 not_found`).
- linkFailureMessage › never shows a raw code or message (`SQLITE_CONSTRAINT` → "The label was not linked. Try again.").

`src/ui/__tests__/routeResult.test.ts`

- passes a request id to the opener and resolves with the delivered value.
- resolves only once (second deliver returns false).
- resolves undefined when abandoned, and ignores a delivery after that (abandon idempotent).
- keeps concurrent requests apart.
- ignores a missing or unknown request id.

Shared rules used by these screens (port with their owners, listed here because
the screens depend on them):

- `src/ui/__tests__/errors.test.ts`: describeError offline cases (0 offline, 0 timeout, 502, 530, 520 `origin_down`; rule: code `offline`/`timeout`/`http_502`, or status from `http_NNN` else the HTTP status, equal to 502 or within 520–530); revoked when `status == 401` **or** `code == "unauthorized"` (the test's 403 case carries `unauthorized`; a 403 with another code is `server`), except context `join`; null/404/`not_found` → gone by subject; `photo_missing`; server codes; conflict; local; never raw codes. needsRefreshBanner/isOffline cases (drive `explainedElsewhere` and every refresh banner).
- `src/hooks/__tests__/useRecentPlaces.test.tsx` › "takes the stored list, then holds it while the screen stays open": a mounted picker keeps `["a","b","c"]` after `rememberPlace("b")`; a newly mounted one sees `["b","a","c"]` (the Add sheet's Where list uses this hook, `app/item/new.tsx:189`).
- `src/ui/__tests__/a11y.test.ts`: spellCode ("DRW-7K2M" → "D R W, 7 K 2 M"; "BOX1"; "-AB--C-" → "A B, C"); whereSpoken (named, unnamed, drop zone); quantitySpoken.
- `src/ui/components/__tests__/SuggestionBanner.test.tsx`: staleSuggestionName (5 tests).
- `src/ui/components/__tests__/textHelpers.test.tsx` › splitHighlight: "puts matches at odd indexes, case-insensitively"; "ignores one-letter terms and escapes regex characters".
- `src/ui/household/__tests__/status.test.ts` › backupSummary ("always has a value, including Off"; "marks a failed backup in signal"); showBackupRow (3 tests).
- `src/ui/household/__tests__/join.test.ts` › serverHost "keeps only the host of the address".
- `src/ui/capture/__tests__/captureFlow.test.ts` › hidden rows (3 tests).
- `src/services/places/__tests__/recentPlaces.test.ts` › mergeRecent (4 tests), rememberPlace persistence.
- `src/i18n/__tests__/format.test.ts` › plural, sentenceList, ago (14 cases incl. future → "just now").
- `src/db/__tests__/persistence.test.ts` › "qr bindings" (6 tests: resolve bound, unknown well-formed, invalid, rebind token, rebind container, unbind keeps data).

No RN tests exist for these; write Swift tests: `ToastCenter` queue (error hold
1500 ms, pending replacement rules, durations ×2 with VoiceOver, pause/resume
floor 2500 ms, action once); `SearchModel` (debounce 200 ms for a new query, 0
for the same, results kept on failure, `pending`/`refreshing`, log once per
query); `ScanGuard` (one scan per arming, 1500 ms same-code ignore after
refocus, stale lookup dropped); `OnboardingStore` (status before storage,
read failure → pending); unpaired-notice visibility; Home `idleBody` /
`searchBody` derivations and `explainedElsewhere`.

---

## 22. RN/Expo workarounds not needed natively

- `goToTab` (`dismissTo` vs `navigate`) to avoid a second tab shell
  (`src/ui/navigation.ts:10-21`): a native router owns tab selection.
- `unstable_settings.anchor` for cold deep links (`app/_layout.tsx:33-37`):
  build the path explicitly.
- `FullWindowOverlay` + `unstable_accessibilityContainerViewIsModal`
  (`src/ui/components/Toast.tsx:226-252`): use a real `UIWindow`.
- `useBottomChrome` / `registerChrome` (`ToastProvider.tsx:241-246,286-295`):
  compute the offset in the overlay.
- Android branches: `BackHandler` (Scan code list, onboarding, Add while saving,
  revoked layer), keyboard-hidden tab bar, ripple, close icon vs "Cancel".
- Manual iOS announcements for banners, error states, scan panels and toasts
  exist because RN live regions are Android-only; natively post
  `AccessibilityNotification.Announcement` only where specified.
- `useLayoutScale` / `stacked`, `inlineIconSize`, `adjustsFontSizeToFit`,
  `maxFontSizeMultiplier`, Drop zone's 390 pt thumbnail rule: Dynamic Type.
- `stickyHeaderIndices`, the pinned-field border, `scrollEventThrottle`,
  `onViewableItemsChanged` + `scrollToIndex` reveal: `.searchable` and
  `ScrollViewReader`.
- `LayoutAnimation` (`animateNextLayout`): `withAnimation`.
- `useInventoryQuery`'s FNV hash token and `runRef`, `useDelayedFlag`'s derived
  state, `resolveRef` in `/c/[token]`: React lint constraints; use async/await
  with task cancellation and generation counters.
- `ItemRow` memo comparator: value types.
- `useRecentPlaces` holding the first-read order to avoid an Android renderer
  crash (`src/hooks/useRecentPlaces.ts:13-23`): keep the UX reason (rows do not
  jump under the finger in an open picker) but no crash workaround is needed.
- `SystemUI.setBackgroundColorAsync`, the custom navigation theme,
  `headerBackButtonDisplayMode`, `FontProvider`.
- `expo-router/js-tabs` custom `TabBar`: `TabView`.
- `Keyboard.dismiss()` before pushes: SwiftUI ends editing on navigation; keep
  it before expanding a chip.

Native APIs replacing JS approaches: AsyncStorage → `UserDefaults` (after
import); SecureStore → Keychain; expo-camera barcode → VisionKit/AVFoundation;
expo-haptics → `.sensoryFeedback`; `Linking.openSettings` →
`UIApplication.openSettingsURLString`; `Alert.alert` confirm → `.alert` /
`.confirmationDialog` with `.destructive`; `ActionSheetIOS` →
`.confirmationDialog`; `AccessibilityInfo` → `UIAccessibility` /
`@Environment(\.accessibilityVoiceOverEnabled)` /
`@Environment(\.accessibilityReduceMotion)`; `RefreshControl` → `.refreshable`;
`FlatList` → `List`; focus effects → `.onAppear` / `.task`; long-press Add →
Home Screen quick action (proposed).

---

## 23. Open questions

1. **Add action in the tab bar** (§4.3): intercepted middle tab, iOS 26
   `tabViewBottomAccessory`, or toolbar `+`? How to replace long-press Quick
   Snap (Home Screen quick action proposed)?
2. **Tab bar on pushed screens**: RN pushes every detail over the tab shell
   (tab bar hidden). Native per-tab `NavigationStack` keeps it visible. If
   adopted, should `goToTab` also clear the other tabs' paths (RN effectively
   does, since it pops the single root stack)?
3. **Search placement**: keep search on Home via `.searchable` (RN behaviour),
   or adopt the iOS 26 `Tab(role: .search)`? The latter changes the IA (#1,
   #14, `111b579`).
4. **Deep links**: support only `inventory://c/<token>`, or every route
   (`/?q=`, `/item/<id>` …) as expo-router does? Queue a link that arrives
   during onboarding (RN drops it)? On a warm open with a sheet presented,
   dismiss it first? Which tab hosts `/c/<token>` from an external link (Home
   proposed)? There is no `+not-found` route in `app/`, so an unknown path
   (e.g. `inventory://c/<token>/extra`) currently shows expo-router's built-in
   "Unmatched route" screen; natively decide between ignoring it and opening
   Home.
5. **Toasts above sheets** require a secondary `UIWindow`: acceptable, or show
   toasts only after sheets close?
6. **Empty states**: RN aligns them top-leading by design; stock
   `ContentUnavailableView` is centred. Accept the native look?
7. **Brand accent and badge colour**: the brand accent is presumably the tape
   yellow (`tape` `#FFD23F` light / `#F4CA3C` dark, `src/ui/tokens.ts:40,77`;
   camera accent `#FFD23F`, `:125`). Should the Drop zone badge stay yellow
   ("not an alarm") via `UITabBarAppearance`, or use the system red?
8. **Home header**: use `.navigationSubtitle` (iOS 26) for the counts and the
   "Shared with the household / Kept on this phone" caption, or rows at the top
   of the list?
9. **Search busy indicator**: no stock spinner in `.searchable`; drop it (the
   skeleton covers waits) or add a toolbar `ProgressView`?
10. **Quantity chip**: keep the inline expanding stepper (parity, "two taps from
    a search result") or use a native `Menu`/context menu?
11. **Scan "Type a code instead"**: keep the in-tab phase swap, or push/present
    the code picker?
12. **iPad**: RN supports tablets with a 640 pt content column. Use
    `.tabViewStyle(.sidebarAdaptable)` on iPad?
13. **How it works** replays onboarding and lands on a fresh Home (whole tree
    swapped). Keep, or present onboarding as a cover over Settings?
14. Onboarding ignores `Joined.hasImportOffer`; confirm the import offer is
    surfaced elsewhere (Household screen) natively too.
15. Verify the onboarding-pending + deep-link behaviour in the RN build before
    deciding Q4.

---

## 24. Cross-area dependencies

- **Data layer / repositories / migrations**: `spaces.listWithCounts`,
  `items.listRecent`, `items.listUnsorted`, `containers.listAllWithSpace`,
  `items.create`, `items.delete`, `qr.resolveScan`, `qr.getByContainer`,
  `qr.bind`; revision/invalidate; the `useInventoryQuery` contract (§16.1);
  `LATEST_SCHEMA_VERSION`; boot `retry`.
- **Search**: `search.search(query)`, `SearchResults`, `matchKind`, terms,
  result limits, `rememberCategories` feed.
- **Household / connection / sync**: session (`householdName`, `deviceName`,
  `origin`), `ConnectionState` and `ConnectionBanner`, removed-phone layer, HTTP
  repositories and thumbnail hydration (`/v1/spaces`, `/v1/items?recent=1&limit=`,
  `/v1/items?unsorted=1`, `/v1/containers`, `/v1/search?q=`, `POST /v1/qr/scan`,
  `GET /v1/containers/<id>`, `POST /v1/qr/bind`), `JoinForm` and the import offer,
  Household screen, `SyncStatus` for the backup row, Backup screen.
- **Items**: item detail and filing runs (`?filing=1`), move sheet + `MoveResult`
  + "Filed in …" Undo toast, edit sheet, `useSavedQuantity`, `QuantityStepper`,
  `QuantityChip`, `ItemForm` (`validateItemForm`, `ItemDetailsFields`,
  `applySuggestion`), category memory.
- **Places**: `PlacePicker` (modes `open`, `bind`, `choose`), `placeMatch`,
  recent places store.
- **Capture**: `/capture` modes and params, `PhotoResult`/`StoredImage`,
  `deleteStoredPhotos`, recognition service (`recognizeItem`), review screen.
- **Spaces and containers**: `/space/new` (`NewSpaceResult`), `/container/new`
  (`NewContainerResult`), space and container detail, QR card, sticker link
  screen (shares `QrScanner`).
- **Design system**: brand accent, SF Symbol mapping for the RN glyph set,
  `Thumb`, `Tape` (label code), `LocationLine`, `Mark`.
- **Storage migration**: one-time import of the AsyncStorage manifest keys in
  §20 before `OnboardingStore` and the unpaired notice read them; Keychain
  session.
- **Telemetry**: sink and allowlist.
- **i18n**: `strings.ts` port and `format.ts` (`plural`, `sentenceList`, `ago`).
- **Forms**: `SaveNotice` (`src/ui/spaces/FormLayout.tsx`) for the Add sheet's
  save problem; `ItemDetailsFields`, `validateItemForm`, `applySuggestion`.

---

## Reviewer notes

Adversarial review against the RN source. Citations were re-opened and are
largely accurate; the changes below fix inaccuracies and fill gaps.

Corrections:

- §3.4 `openForResult`: a throwing `open` makes the returned promise reject
  (executor semantics), it is not rethrown synchronously; request id random part
  is up to 6 chars.
- §7.1 drop-zone SQL uses a bound `?` parameter, not a literal.
- §12 Settings is not entirely read-only: How it works removes
  `onboarding.completed.v1`. `serverHost` trims first and falls back to the
  untrimmed input; the app version falls back to `"0.0.0"`.
- §17 SpacePip a11y citation (`:23-24`, not `:28-29`).
- §20 `categories.recent.v1` is a JSON array of ≤ 20 trimmed, case-insensitively
  de-duplicated strings written only by `recordCategory`; it was described only
  as "JSON". AsyncStorage overflow-file citation corrected (`:507-510,631-650`),
  and the null-in-manifest encoding is now stated.
- §21 errors test: revoked is `401` **or** code `unauthorized` (a bare 403 is
  `server`).

Additions:

- §3.2 navigation edges from the Scan code list (no containers → plain push
  `/space/new`) and from the `/c/<token>` bind picker (new space/container →
  linked).
- §5.3 SearchField default placeholder, `autoCapitalize`, Home testID.
- §5.6 `settled` is never cleared when the field is emptied (old results reappear
  dimmed for the next query).
- §5.7 search container rows: `hasLabel` is always false, item count comes from
  the hit, fallback row details, typeName fallback chain, testIDs.
- §6 `needsRefreshBanner` rule and how it differs from Home's
  `explainedElsewhere`.
- §7.2 skeleton row count; empty states render only when the list is empty.
- §8.3 connection banner on the code phase, none on the camera phase.
- §8.4 full `QrScanner` prop surface for the shared sticker-link host.
- §8.5 `camera-open-settings` testID.
- §8.6 `parseQrPayload` prefix is case-sensitive and only `inventory://c/`;
  token format; "never change printed payload".
- §9.3 bind timestamps (ms), binding id format (lowercase UUID; Swift
  `uuidString` is uppercase), lowercase token, `rememberPlace` even when nothing
  was written.
- §10.1 the two capture → Add handoffs (photo params incl. optional
  `photoBytes`; "type it instead" with `containerId` only).
- §10.2 JS `Number()` vs Swift `Int()` note.
- §10.3 missing copy keys / testIDs (`strings.add.howMany`,
  `strings.forms.moreDetails`, `item-name`, `item-photo-*`, `item-more-details`,
  `item-snap-several`, `add-saved-next`), stale banner uses the typed name,
  details-toggle algorithm, focus-on-arrival only if still focused.
- §10.4 invalid quantity makes Save silently do nothing; parsed-field rules;
  error-class contexts; `startNext` details; photo "another" path has no mode.
- New §10.7: the Add sheet's photo/recognition state machine (`runRecognition`,
  `applySuggestion` merge rules, triggers, `takePhoto`, `dropPhoto`, photo
  options, clear-draft) which the spec previously did not describe.
- §11.2 `replaying` is just `session != nil`; Keychain-survives-reinstall edge.
- §14 toast action also dismisses the toast; testIDs; leaving toast still holds
  newcomers; provider mounts only after the boot gate.
- §15.1 Banner defaults (icon by tone, `live = polite`, action shape); SpaceTile
  opaque tint + 45 % edge + `safeColor` fallback.
- §15.2 exact second-line composition for `added`/`detail`; row and chip testIDs.
- §15.4 `RecognitionFailureReason` enum; which states announce.
- §16.1 key-change behaviour of `useInventoryQuery`; DropZoneProvider focus
  scope.
- §19 exact `describeError` arguments behind every `errorClass`.
- §20 exact-string read rules for each persisted preference and import guidance.
- §21 `useRecentPlaces` test.
- §23 Q4: no `+not-found` route (unknown deep-link paths hit expo-router's
  Unmatched screen).

Completeness / consistency pass (cross-spec critic):

- §20: the native-import note said "a typed `Bool` is fine after import". The
  owning spec (`02-device-storage-migration.md` §5.4) copies the seven keys as
  raw strings under the same names so read rules port one-to-one; this section
  now says the same and points at the owner.
- Titles: this spec (§5.2, §16.6) and 07 §0.11 recommend large titles for tab
  roots and detail screens, while 09 §2.5 said "inline titles". 09 was
  corrected to match this spec (RN only avoided large titles because of an
  iOS 26 custom-header-background quirk, `app/_layout.tsx:125`).
- §2.2 / §14 overlay window: the removed-phone layer and toasts share one
  pass-through `UIWindow` (09 §7.7); 04 §9.6 now defers to it as well.
- Coverage check: every file under `app/(tabs)/`, `app/onboarding.tsx`,
  `app/settings.tsx`, `app/privacy.tsx`, `app/c/[token].tsx`, `src/ui/add/*`,
  `src/ui/home/*`, `src/ui/scan/*`, `searchFocus.ts`, `routeResult.ts`,
  `navigation.ts`, `TabBar`, `ItemRow`, `Row`, `Banner`, `EmptyState`,
  `Skeleton`, `SettingsRow`, `Sheet`, `SpacePip`, `StatusPill`, `QrScanner`,
  `SearchField` and the UI hooks listed in §16 is specified; every exported
  symbol is referenced.
