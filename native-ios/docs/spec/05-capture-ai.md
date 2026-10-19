# 05: Camera capture, Quick Snap, photos and AI recognition

Porting spec for the native iOS app (Swift 6, SwiftUI, iOS 26 minimum, same bundle id `com.wystudio.inventory`). Source of truth is the Expo app at `40c0616`. Every behavior cites `path:line`. User-facing copy is referenced by its key in `src/i18n/strings.ts` (written `strings.capture.noRoom` and so on). UI is described as information architecture, states and behavior. Visual styling is left to stock SwiftUI and Liquid Glass. The only exception is the brand accent `camera.accent` `#FFD23F` (`src/ui/tokens.ts:125`), which is used for the focus square and the Done count.

Line numbers in `node_modules/expo-camera/ios/**` are from the **patched** tree (patch-package applies `patches/expo-camera+57.0.3.patch` on install).

---

## 0. Scope and source map

| File | Role |
|---|---|
| `app/capture/index.tsx` | Camera screen: single, request (photo for Add) and fast (Quick Snap) modes, library import, permission gate |
| `app/capture/review.tsx` | Quick Snap review list, which shows rows live as the pipeline lands them |
| `app/item/[id]/photo.tsx` | Full-screen photo viewer |
| `src/ui/capture/captureFlow.ts` | Pure decision functions for capture, review and the drop zone (tested) |
| `src/ui/capture/CameraChrome.tsx` | Overlay chrome: reticle, shutter flash, Into pill, notices, shutter, last-shot tile, Done |
| `src/ui/components/CameraPermission.tsx` | Shared camera-permission screen (capture and scan) |
| `src/ui/components/TapToFocusLayer.tsx` | Tap-to-focus overlay and focus square |
| `src/ui/components/Thumb.tsx` | Item thumbnail with placeholder |
| `src/ui/item/NameItInline.tsx` | "What is it?" inline naming of an unnamed (Quick Snap) item |
| `src/services/capture/fastCapture.ts` | Fast pipeline: store photo, create row, recognize, enrich row |
| `src/services/capture/fastReview.ts` | Session filter and summary for the review |
| `src/services/capture/imageScaling.ts` | Size constants and `scaleToFit` |
| `src/services/capture/imageStore.ts` | Normalize, encode and store photos and thumbnails. Restore, read, delete, free-space check |
| `src/services/ai/contract.ts` | Client wire contract v1 and response validation |
| `src/services/ai/recognition.ts` | HTTP client for `/api/recognize` |
| `server/api/recognize.ts`, `server/api/adapters.ts` | Vercel functions (backend stays in TypeScript, but its behavior defines the contract) |
| `server/src/{contract,auth,prompt,port,registry}.ts`, `server/src/adapters/*` | Server validation, auth, prompt, adapter registry, Anthropic adapter |
| `patches/expo-camera+57.0.3.patch` | Focus, lens, zoom and capture-quality changes to expo-camera (the iOS hunks matter most) |

Also read, because the area depends on them: `app/item/new.tsx` (how suggestions fill the Add form), `src/ui/components/SuggestionBanner.tsx`, `src/ui/components/ItemForm.tsx` (`applySuggestion`), `src/ui/add/addSheet.ts`, `src/ui/add/addDraft.ts`, `src/ui/routeResult.ts`, `src/ui/navigation.ts`, `src/ui/components/TabBar.tsx`, `src/repositories/items.ts`, `src/db/migrations.ts`, `src/services/config.ts`, `src/services/telemetry/index.ts`, `src/ui/item/itemDetails.ts` (`attemptName`).

---

## 1. Critical findings (read first)

**C1. Stored photo URIs are absolute container paths. The native app must rebase them.**
`storeItemPhoto` returns `destination.uri` (`src/services/capture/imageStore.ts:86`, `:114-115`), an absolute `file://` URL under `Paths.document/item-photos` (`imageStore.ts:40`). It is stored verbatim in `item_photos.uri` and `item_photos.thumb_uri` (`src/repositories/items.ts:266-276`). On iOS that path embeds the per-install data-container UUID (`file:///var/mobile/Containers/Data/Application/<UUID>/Documents/item-photos/<id>.webp`). Apple guidance is never to persist absolute container paths, because the container location can change across updates and reinstalls. The App Store update that replaces the Expo build is exactly such an event. Today the RN app only self-heals when backup is on: `rehydrateMissingPhotos` re-downloads any photo whose `uri` is unreadable and rewrites the row (`src/services/sync/photoSync.ts:131-165`).
**Native requirement:** resolve every stored URI through the one shared `PhotoPathResolver.resolve(_:)` specified in `02-device-storage-migration.md` §3.3 (summary in §9.7 here). It rebases by **file name** under the current `Documents/item-photos/` (or `Caches/household-photos/`), which also covers Android-restored paths. Optionally rewrite the rows (02 Q4). Every area that reads photo files (sync upload, household import, delete, display) must use the same resolver.
**Data-loss hazard (why the resolver is blocking, not optional):** the backup uploader treats an unreadable `uri` as a vanished file. It **deletes the `item_photos` row and its thumbnail file** (`src/services/sync/photoSync.ts:62-70`; test `src/services/sync/__tests__/photoSync.test.ts` "drops a row whose local file has vanished rather than retrying forever"). Suppose a native uploader reads stored URIs without the resolver after the container moved. Its first pass would then delete the photo row of every photo not yet uploaded, and those photos have no remote copy to rehydrate from. Rehydration only looks at already-synced rows, and only the 10 newest per pass (`photoSync.ts:136-147`). So the resolver, or the one-time row rewrite, must be in place before the first sync pass of a native launch. Coordinate this with the sync area.

**C2. Recognition labels WebP bytes as JPEG.**
The client always sends `mediaType: 'image/jpeg'` (`src/services/ai/recognition.ts:97`). The bytes it reads are always the stored `.webp`: the fast pipeline recognizes `stored.uri` (`src/services/capture/fastCapture.ts:71`), and the Add sheet recognizes `photo.uri` from the stored image (`app/item/new.tsx:249`, `:401-404`). The server honors any syntactically valid declared type (`server/src/contract.ts:99-103`) and passes it to Anthropic as `media_type` (`server/src/adapters/anthropicVision.ts:73-79`). The Anthropic Messages API is known to check base64 image bytes against the declared `media_type` and to answer 400 ("Image does not match the provided media type …") when they disagree. The adapter classifies that as `upstream` (`anthropicVision.ts:139`), which becomes HTTP 502 and then client `server_error`, for **every** photo. Treat this as a probable live production bug and confirm it against the deployed endpoint before porting. The server's fallback comment, "The app's capture pipeline always writes JPEG" (`server/src/contract.ts:102`), predates the switch to WebP.
**Recommendation (decision D1):** send the true type, sniffed from magic bytes (`RIFF....WEBP` → `image/webp`). The server already accepts `image/webp` (`anthropicVision.ts:21-26`), so this stays inside contract v1.

**C3. WebP encoding needs libwebp on iOS.**
Photos are WebP (`imageStore.ts:16-25`). Expo encodes them with `SDImageWebPCoder` (`node_modules/expo-image-manipulator/ios/ImageManipulatorUtils.swift:79-80`). ImageIO on iOS decodes WebP but does not encode it. Keep WebP anyway: the backup Worker accepts only `image/jpeg|webp|png` (`worker/src/index.ts:420-425`), the home server stores `photos/<id>.webp`, restore writes `<id>.webp` (`imageStore.ts:162`), and Android keeps writing WebP. Add libwebp through SPM (for example `SDWebImageWebPCoder`, or libwebp directly).

**C4. iOS photos are center-cropped to the preview's aspect ratio.**
expo-camera crops every still to the aspect of the on-screen preview (`node_modules/expo-camera/ios/Current/CameraPhotoCapture.swift:159-167`, `:187-190`). The preview is full-screen aspect-fill (`app/capture/index.tsx:405-414`, `CameraView.swift:189`). So a portrait shot on a 393×852 pt iPhone is stored as roughly 646×1400 px, not 1050×1400. This is WYSIWYG: the photo is exactly what the screen showed. **Decision D2:** keep the crop (behavior-identical), or switch to an uncropped 4:3 still like Camera.app.
Orientation edge cases of the same crop:
- Phone held landscape (the UI stays portrait): the crop is the same rectangle in sensor space, and the capture gets a landscape orientation. The stored photo is therefore about 1400×646.
- Phone flat (face up or face down) or orientation unknown: captured as portrait (`node_modules/expo-camera/ios/Common/ExpoCameraUtils.swift:66-79`). This matters because items are often shot flat on a table.
- iPad (`app.json` has `supportsTablet: true`, and the generated iPad Info.plist allows landscape): the preview size is swapped only when the interface orientation is `.portrait` (`CameraPhotoCapture.swift:164-166`). A landscape or upside-down UI crops to the unswapped preview aspect, and there the crop can also shorten the long edge. See Q16.

**C5. The patched quality setting may raise an exception.**
The patch sets `photoSettings.photoQualityPrioritization = .quality` (`patches/expo-camera+57.0.3.patch:249-250`). expo-camera never raises `photoOutput.maxPhotoQualityPrioritization` from its `.balanced` default (no match anywhere in `node_modules/expo-camera/ios`). AVFoundation documents that a per-capture prioritization above the output's maximum raises an `NSInvalidArgumentException`. Verify on device. The native app **must** set `photoOutput.maxPhotoQualityPrioritization = .quality` before the session starts.

**C6. The UI cannot replace an existing item's photo.**
`app/item/[id]/edit.tsx:291` shows the photo read-only: "photos of existing items cannot be replaced yet". The repository already supports it (§15). The Add sheet can retake or remove its photo before saving.

**C7. "Keep shooting" resets the expected count.**
Review → Keep shooting passes `since` but not `expected` (`app/capture/review.tsx:204-209`). The new camera instance starts `captured` at 0 (`app/capture/index.tsx:97`) and Done passes only the new shots as `expected` (`index.tsx:311-316`). The second review therefore under-counts photos still in flight. Pending rows still appear live. See open question Q4.

**C8. Household clock skew can hide session rows.**
The review selects rows with `createdAt >= since` (`src/services/capture/fastReview.ts:22-24`). `since` comes from the phone clock (`index.tsx:244`). In household mode `createdAt` comes from the home server, so clock skew can hide rows.

---

## 2. Constants

| Name | Value | Source |
|---|---|---|
| `MAX_IMAGE_DIMENSION` | 1400 px (longer edge) | `src/services/capture/imageScaling.ts:22` |
| `IMAGE_QUALITY` | 0.8 | `imageScaling.ts:23` |
| `THUMBNAIL_DIMENSION` | 320 px (longer edge) | `imageScaling.ts:32` |
| `THUMBNAIL_QUALITY` | 0.7 | `imageScaling.ts:33` |
| Image format and extension | WebP, `.webp` | `imageStore.ts:24-25` |
| Photo directory | `<Documents>/item-photos` | `imageStore.ts:28`, `:39-45` |
| Free-space check | `available > 2 × 1_000_000` bytes | `imageStore.ts:201-207` |
| `RECOGNITION_CONTRACT_VERSION` | 1 | `src/services/ai/contract.ts:9`, `server/src/contract.ts:10` |
| `MIN_CONFIDENCE` | 0.35 (strictly-less-than rejects) | `contract.ts:20`, `:95` |
| Client `MAX_TAGS` / `MAX_TEXT_LENGTH` | 8 / 80 | `contract.ts:37-38` |
| Client timeout | 15 000 ms (env `EXPO_PUBLIC_RECOGNITION_TIMEOUT_MS`) | `src/services/config.ts:68` |
| Server provider budget | 12 000 ms (env `RECOGNITION_TIMEOUT_MS`) | `server/api/recognize.ts:12` |
| Vercel `maxDuration` | 30 s | `server/vercel.json:5` |
| Server `MAX_IMAGE_BYTES` | 8 MiB decoded, pre-check base64 length > 8 MiB × 1.4 | `server/src/contract.ts:13`, `:81` |
| Server `MAX_HINT_LENGTH` | 80 | `server/src/contract.ts:34` |
| Server tag rules | trim, lowercase, length 1…40, dedupe, max 8 | `server/src/prompt.ts:90-96` |
| Anthropic effort / max_tokens | `low` / 4096 | `anthropicVision.ts:11`, `:17` |
| Review stall | 30 000 ms | `app/capture/review.tsx:51` |
| Focus square | 72 pt, shown 700 ms | `src/ui/components/TapToFocusLayer.tsx:7-8` |
| Shutter flash | 120 ms total, peak opacity 0.5 | `src/ui/motion.ts:19`, `CameraChrome.tsx:77-86` |
| Add long-press (Quick Snap) | 350 ms | `src/ui/components/TabBar.tsx:182` |
| Photo viewer | max zoom 4×, close drag 80 pt, drag start 10 pt | `app/item/[id]/photo.tsx:28`, `:31`, `:151` |
| Add draft TTL | 30 min | `src/ui/add/addDraft.ts:20` |
| Spinner delay (permission and viewer loading) | 180 ms | `src/ui/motion.ts:27`, `src/hooks/useDelayedFlag.ts:12` |
| Drop zone container id | `'drop-zone'` | `src/db/constants.ts:26` |

---

## 3. Entry points and navigation

| # | Trigger | Route and params | Effective mode | Source |
|---|---|---|---|---|
| 1 | Tab bar **Add** long-press (350 ms). Medium impact haptic. VoiceOver custom action `longpress` labelled `strings.tabs.quickSnapAction`, hint `strings.tabs.addHint` | push `/capture?containerId=drop-zone&mode=fast` | fast | `TabBar.tsx:165-189`, `src/ui/navigation.ts:52-54`, `src/ui/haptics.ts:33` |
| 2 | Home drop-zone card "Quick Snap" (`strings.home.dropZone.quickSnap`) | same as 1 | fast | `src/ui/home/DropZoneCard.tsx:75-82`, `app/(tabs)/index.tsx:622` |
| 3 | Drop zone tab header button (only when rows exist) and empty-state action | same as 1 | fast | `app/(tabs)/drop-zone.tsx:131-139`, `:174` |
| 4 | Container screen camera button and empty-state camera action | push `/capture?containerId=<id>` | single | `app/container/[id]/index.tsx:209-212` |
| 5 | Add sheet camera icon (`strings.add.addPhoto`) | push `/capture` `{containerId: place.id, mode:'single', request}`, awaiting a `PhotoResult` | single (request) | `app/item/new.tsx:385-405`, `src/ui/routeResult.ts:26-37` |
| 6 | Add sheet thumbnail → action sheet: **Retake** (`strings.add.retake`) or **Remove photo** (`strings.add.removePhoto`, destructive) | Retake runs `dropPhoto()` then #5 | single (request) | `new.tsx:407-421` |
| 7 | Add sheet "Snap several at once…" (`strings.add.snapSeveral`) | **replace** `/capture` `{containerId: place.id, mode:'fast'}`. The typed draft is kept | fast | `new.tsx:456-461` |
| 8 | Add sheet "Save and add another" with a photo | **replace** `/capture` `{containerId: target.id}` | single (no request) | `new.tsx:565-568` |
| 9 | Review "Keep shooting" / empty-state "Try again" | **replace** `/capture?containerId&mode=fast&since=<since>` / `/capture?containerId&mode=fast` | fast | `review.tsx:204-216` |

Exits from the camera:
- Single capture without `request`: **replace** with `/item/new?containerId&photoUri&photoThumbUri&photoWidth&photoHeight[&photoBytes]` (`index.tsx:199-210`). `photoBytes` is omitted when the size is unknown.
- "Type it instead": **replace** with `/item/new?containerId=<id>`, or go back in request mode (`index.tsx:158-167`).
- Fast with shots: **replace** with `/capture/review?containerId&since&expected` (`index.tsx:311-317`).

Presentation:
- Capture: `fullScreenModal`, no header (`app/_layout.tsx:92-95`, `:201`).
- Review: card push, title `strings.review.title`, back button hidden (`_layout.tsx:202-205`, `review.tsx:290`). Only `headerBackVisible: false` is set; `gestureEnabled` is not turned off. So the iOS edge-swipe back still works and pops to the origin **without** logging `fast_review_done` and without the Done toast. SwiftUI's `.navigationBarBackButtonHidden(true)` also disables the swipe, so a native default would differ. See Q13.
- Photo viewer: `fullScreenModal` with fade (`_layout.tsx:200`).

**Native recommendation:**
- Model capture as `CaptureRoute(containerId: String, mode: .single | .fast, since: Date?, delivery: ((StoredImage?) -> Void)?)` and present it with `.fullScreenCover`.
- Request mode returns the stored photo through a closure or `CheckedContinuation` instead of `routeResult` request ids.
- "Replace" transitions become: dismiss the cover, then push onto the origin `NavigationStack`. For example, Done → dismiss → push `ReviewRoute`. Keep shooting → pop the review → present the cover with `since`.

---

## 4. Capture screen (`app/capture/index.tsx`)

### 4.1 Inputs and initial mode
- Params: `containerId` (required; `'drop-zone'` or a container UUID), `mode?: 'single' | 'fast'`, `since?: string` (epoch ms, carried through Keep shooting), `request?: string` (`index.tsx:61-73`).
- Initial mode is `fast` only if `mode === 'fast'` **and** there is no `request`. Otherwise `single` (`index.tsx:90-92`).
- `sessionStart` starts as `Number(since)` or `null` (`index.tsx:123`).

### 4.2 State

| State | Meaning | Source |
|---|---|---|
| `permission` | camera permission (see §16) | `index.tsx:81` |
| `flash` | `'off'` (default) or `'on'` | `:82` |
| `processing` | single mode: stored photo is being processed | `:83` |
| `error` | message shown in the camera notice | `:84` |
| `mode` | `single` or `fast` | `:90` |
| `captured` | fast: shutter presses that produced a photo (decremented when that photo's pipeline fails) | `:97` |
| `completed` | fast: pipelines finished | `:98` |
| `recognized` | fast: pipelines that ended `recognized` | `:99` |
| `dropped` | fast: pipelines that rejected (row or photo not written) | `:100` |
| `shutterBusy` (ref) / `shooting` | fast: camera hardware busy (shutter dims to 0.5 opacity) | `:103-105`, `CameraChrome.tsx:232` |
| `lastShot` | fast: newest raw photo URI (last-shot tile and flash trigger) | `:107` |
| `takingRef` | single: prevents double capture | `:110` |
| `pickingRef` | library picker is open | `:113` |
| `closedRef` | camera is leaving or gone. Set once, never cleared while mounted | `:118`, `:145-150` |
| `sessionStart` | epoch ms of the first fast shutter press of this session | `:123`, `:244` |
| `into` | async query for the Into pill: container plus space, or `null` for the drop zone, a missing container, or a container whose space is missing | `:127-141` |

Derived values (`index.tsx:394-399`):
- `fast = mode == fast`
- `locked = fast && captured > 0`
- `status = fastStatus({captured, completed, recognized})`
- `typeInstead = request == nil && !locked`

### 4.3 Permission gate
When `!permission?.granted`, the screen renders `CameraPermission` with `purpose:'capture'`, `onManual = request ? nil : continueManually`, `onLibrary = pickFromLibrary`, `onCancel = close` (`index.tsx:377-392`). See §16.

### 4.4 Single mode
`takePhoto()` (`index.tsx:220-231`):
1. Guard: the camera view is mounted (`cameraRef.current != nil`), `!processing`, `!takingRef`. Set `takingRef = true`. The app does **not** wait for `onCameraReady`. A press before the session has added its photo output makes expo throw `CameraOutputNotReadyException` (`node_modules/expo-camera/ios/Current/CameraView.swift:311-316`), which shows as `strings.capture.noPhoto`. Native: enable the shutter only once the session is running.
2. Capture (`takePictureAsync({quality: 1, skipProcessing: false})`; on iOS `skipProcessing` is ignored, see §8.1).
3. If there is a URI: `await handleCaptured(uri, 'camera')`.
4. On a capture error: `error = strings.capture.noPhoto`. Finally: `takingRef = false`.

`handleCaptured(uri, source)` (`index.tsx:169-218`):
1. If `closedRef`, return (`:171`).
2. If `!hasRoomForPhoto()`: `report(strings.capture.noRoom)` and return (`:172-175`).
3. `processing = true`, `error = nil` (`:177-178`). The shutter shows a spinner and refuses presses (`CameraChrome.tsx:223-247`). The library button and mode picker are disabled (`index.tsx:507`, `:523`). The hint becomes `strings.capture.saving` (`:556-557`).
4. `stored = await storeItemPhoto(uri)` and log `photo_captured {source, byteSize}` (`:181-182`).
5. If `closedRef` became true while saving, delete both files and return (`:185-188`).
6. Set `closedRef = true` (`:189`).
7. If `request` and `deliverResult(request, stored)` returns true: go back and stop (`:194-197`). If nobody is waiting any more, fall through so the photo is never thrown away.
8. Replace with `/item/new?…` carrying the photo URI, thumbnail URI, width, height and byte size (if known) (`:201-210`).
9. On error: log `photo_capture_failed {source}`. If closed, return. Otherwise `processing = false` and `report(strings.capture.notProcessed)` (`:211-217`).

`report(message)`: when the camera is granted, set the in-camera notice. Otherwise (the permission screen is up) show an error toast (`index.tsx:153-156`).

### 4.5 Request mode (photo for the Add sheet)
- Forced `single` (`index.tsx:90-92`). The mode picker is hidden (`:484`), the trailing slot is an empty spacer (`:538-539`), there is no "Type it instead" anywhere (`:385`, `:399`).
- On unmount, `abandonResult(request)` resolves the opener with `undefined` (`index.tsx:144`, `routeResult.ts:57-63`).
- The Add sheet guards against opening two cameras with `cameraOpenRef` (`new.tsx:386-399`). On a result it builds `AddPhoto` (`photoFromStored`, `src/ui/add/addSheet.ts:55-63`), sets the suggestion to `running`, and starts recognition with the typed name as hint (`new.tsx:400-404`). See §11.

### 4.6 Fast mode (Quick Snap)
`takeFastPhoto()` (`index.tsx:241-299`):
1. Guard: the camera view is mounted and `!shutterBusy` (`:242`). Same "not ready" caveat as single mode. There is **no** `closedRef` check here.
2. `sessionStart ??= now`, stamped **before** the photo exists so every row this press creates sorts after it (`:244`).
3. If `!hasRoomForPhoto()`: `error = strings.capture.noRoom` (set directly, not via `report`) and return (`:245-248`).
4. `shutterBusy = true`, `shooting = true` (`:250-251`).
5. Capture. On error: `error = strings.capture.noPhoto`. Finally clear both busy flags (`:252-261`). The shutter is released only after the full capture call resolves, which on iOS includes expo's decode, crop and JPEG re-encode (§8.1).
6. If there is no URI, return (`:263`).
7. `captured += 1`, `error = nil`, light-impact haptic (`haptics.tap`, `src/ui/haptics.ts:31`), `lastShot = uri` (`:265-271`). This triggers the shutter flash and the last-shot tile.
8. Fire-and-forget `captureFastItem` with these deps (`:273-282`): `storePhoto = storeItemPhoto`, `createItem = repos.items.create`, `updateItem = repos.items.update`, `recognize = recognizeItem({imageUri})` (never hinted).
9. On resolve: `completed += 1`, log `photo_captured {source:'camera', mode:'fast'}`. If the outcome is `recognized`, `recognized += 1`; otherwise log `recognition_unusable {reason}`. Then `invalidate()` so lists refresh (`:283-293`).
10. On reject: log `fast_capture_failed {source:'camera'}`, `captured = max(0, captured − 1)`, `dropped += 1` (`:294-298`).

Concurrency: pipelines are unbounded and run in parallel. They **outlive the camera**: DB writes and `invalidate()` still happen after the screen unmounts, and only the React state updates are dropped (`index.tsx:233-240`). Native: own these tasks in an app-scoped `CaptureCoordinator`, not the view, and process images serially to bound memory (see §9.8).

Counter edge cases:
- `captured` falls back to 0 when every shot so far has failed (step 10). `locked` then clears: the mode picker and "Type it instead" come back, and ✕ and Done just go back without a review. The dropped notice stays.
- Because of the missing `closedRef` guard (step 1), a capture that resolves after Done or ✕ but before unmount still spawns a pipeline. Its row lands with `createdAt >= since`, so it shows in the review, but `expected` does not count it. Normally unmount instead rejects the capture with `CameraUnmountedException` (§8.1).

Mode switch (`index.tsx:485-510`):
- Segmented control with `single` (`strings.capture.modeSingle`) and `fast` (`strings.capture.modeFast`), labelled `strings.capture.modeLabel`.
- Disabled while `locked || processing`. When locked, its accessibility hint is `strings.capture.finishSetFirst`.
- Once a set has a shot, it can only be finished with Done.

### 4.7 Leaving
- **✕ `close()`** (`index.tsx:321-330`): if `closedRef`, return. If `leaveCamera(mode, captured) == 'review'`, call `finishFast()`. Otherwise set `closedRef = true` and go back.
- **Done `finishFast()`** (`index.tsx:301-318`): if `closedRef`, return. Set `closedRef = true` and call `invalidate()`. If `captured == 0`, go back. Otherwise replace with the review, passing `containerId`, `since = sessionStart ?? now`, and `expected = captured`.
- **`continueManually()`** (`index.tsx:158-167`): set `closedRef` once. In request mode, go back. Otherwise replace with `/item/new?containerId=…`.
- Android hardware back is mapped to ✕ (`index.tsx:334-346`). There is no iOS equivalent. Native: a `fullScreenCover` has no swipe dismissal, which matches.

### 4.8 Photo library import
`pickFromLibrary()` (`index.tsx:348-373`):
1. Guard: `!processing && !pickingRef`.
2. Open the picker with images only, `quality: 1`, single selection.
3. If the picker throws: `report(isPermissionError(e) ? strings.permissions.libraryDeniedBody : strings.capture.libraryFailed)`. Clear `pickingRef` in `finally`.
4. If cancelled, do nothing. Otherwise call `handleCaptured(asset.uri, 'library')`, the same pipeline as a camera photo.

Where it is offered: the single-mode gallery button (`strings.capture.library`, disabled while processing, `index.tsx:515-526`) and the permission screen's "Choose a photo instead" (§16). It is **not offered in fast mode** (the slot shows the last-shot tile).

From the permission screen there is **no processing indicator**. `CameraPermission` has no busy prop (`src/ui/components/CameraPermission.tsx:19-36`), so the rationale screen stays unchanged while `storeItemPhoto` runs, which can take seconds for a 48 MP HEIC. Only the `pickingRef` and `processing` guards refuse a second pick. Errors arrive as toasts (`report`). Native: show progress here. This is a UI improvement, not a behavior change.

On iOS, expo-image-picker uses `PHPickerViewController` because `allowsEditing` is false: selection limit 1, images filter, representation `.current` (the original HEIC or JPEG), the file copied to cache (`node_modules/expo-image-picker/ios/ImagePickerModule.swift:93-95`, `:150-161`). PHPicker runs out of process and needs **no permission**, so the `libraryDeniedBody` branch is effectively Android-only.

**Native:** use `PhotosPicker(selection:, matching: .images, preferredItemEncoding: .current)` and load through a `Transferable` file representation (avoid loading 48 MP into `Data`). Map any load failure to `strings.capture.libraryFailed`. No Photos permission prompt.

### 4.9 Notices and errors

| Cause | Copy | Surface | Source |
|---|---|---|---|
| No free space (single or library) | `strings.capture.noRoom` | notice, or toast on the permission screen | `index.tsx:172-175` |
| No free space (fast) | `strings.capture.noRoom` | notice | `:245-248` |
| Capture threw | `strings.capture.noPhoto` | notice | `:227`, `:257` |
| `storeItemPhoto` threw | `strings.capture.notProcessed` | notice or toast | `:216` |
| Camera failed to start (`onMountError`) | `strings.capture.didNotStart` | notice | `:413` |
| Library picker threw | `strings.capture.libraryFailed` (or `strings.permissions.libraryDeniedBody`) | notice or toast | `:360-364` |
| Fast pipeline rejected | `strings.capture.failedSome(dropped)` | second notice, polite | `:465-471` |

- The error notice is assertive. It carries the action "Type it instead" (`strings.capture.manual`) when `typeInstead` (`index.tsx:448-463`).
- `CameraNotice` announces on iOS through `announceForAccessibility` (`CameraChrome.tsx:146-149`). Native: `AccessibilityNotification.Announcement(message).post()`.
- The error clears when processing starts (`:178`) and after each successful fast shot (`:266`).

### 4.10 Information architecture (chrome)
The preview is full-bleed and black behind, with a light status bar (`index.tsx:403-414`).

Top row (`index.tsx:425-445`):
- Leading: Close (`strings.capture.close`).
- Center: **Into pill** (`CameraChrome.tsx:106-130`). For the drop zone it shows an inbox icon and `strings.capture.into`. For a container it shows the location line (space colour dot, space › container, label code). Nothing is shown until the container has loaded, or if the container or its space is missing (`CameraChrome.tsx:107-108`). Its accessibility label is `intoA11y(containerId, place)` (`captureFlow.ts:53-59`):
  - Drop zone, or no place → `strings.capture.intoDropZoneA11y`.
  - `containerName` truthy → `strings.capture.intoContainerA11y(containerName, spaceName, spelled)`.
  - Otherwise (a null or empty name) → `strings.capture.intoSpaceA11y(spaceName, spelled)`.
  - `spelled = spellCode(shortCode)`: split on `-`, trim each group, put a space between its characters, drop empty groups, and join the groups with `", "` (`src/ui/a11y.ts:23-29`). For example `CAB-J92R` → `C A B, J 9 2 R`.
- Trailing: **Flash** toggle. The icon shows the current state (on or off). It is "selected" when on, labelled `strings.capture.flash(isOn)`, and toggles between off and on (`index.tsx:437-444`).

Over the preview:
- **Reticle**: decorative corner guides, inset 22% from the top, 28% from the bottom and 10% from each side; 40 pt corners with 3 pt strokes in white at 85%. It is framing guidance only and does not crop (`CameraChrome.tsx:49-63`, `:320-360`).
- **Focus square** (§8.2).
- **Shutter flash**: on each fast shot, a white overlay fades 0 → 0.5 → 0 over 120 ms. Skipped under Reduce Motion (`CameraChrome.tsx:70-99`).

Bottom stack, top to bottom (`index.tsx:447-561`):
1. Error notice.
2. Dropped notice.
3. Fast status pill, shown only when `fast && captured > 0`. Check icon when `settled`. Live region (`:473-482`). The text comes from `fastStatus({captured, completed, recognized})` (`captureFlow.ts:26-41`):
   - `pending = captured − completed`, `unnamed = completed − recognized`.
   - `pending > 0` → `strings.capture.identifying(pending)`.
   - else `unnamed == 0` → `strings.capture.identified(recognized)`.
   - else `recognized == 0` → `strings.capture.savedUnnamed(unnamed)`.
   - else → `strings.capture.identifiedPartly(recognized, unnamed)`.
   - `settled = pending <= 0`.
   - A rejected pipeline decrements `captured` and does not increment `completed`, so it leaves `pending` without being counted as unnamed.
4. Mode picker (hidden in request mode).
5. Shutter row:
   - Leading: single → library button; fast → **last-shot tile**, 44 pt, showing the newest raw photo with the running count (`captured`) on a badge; a 44 pt spacer before the first shot. Decorative (`CameraChrome.tsx:254-276`). RN decodes the full-resolution q=1.0 temp JPEG into this tile. Native: show a downsampled image instead.
   - Center: **Shutter** (`strings.capture.takePhoto`). Busy spinner in single mode while processing, dimmed in fast mode while shooting (`CameraChrome.tsx:223-247`).
   - Trailing: single without request → "Type it instead" keyboard button (`strings.capture.manual`); request → empty spacer; fast → **Done · N** (`strings.capture.done`, accessibility label `strings.capture.doneA11y(count)`). Done is dimmed to 0.55 opacity before the first shot, when it just closes the camera (`CameraChrome.tsx:282-312`).
6. Hint caption: `strings.capture.fastHint` in fast mode, `strings.capture.saving` while processing, otherwise `strings.capture.singleHint` (`index.tsx:552-560`).

Native: stock SwiftUI with `.glassEffect` / glass button styles. Decorative layers get `.accessibilityHidden(true)` and `allowsHitTesting(false)` so preview taps reach the focus gesture.

### 4.11 State machine (summary)

```
[PermissionGate] --granted--> [Live(single|fast)]
[PermissionGate] --Choose photo--> handleCaptured(library) ... (same as single)
[PermissionGate] --Type it instead--> /item/new        --✕--> back

Live(single):
  shutter --> Capturing --uri--> Processing --stored--> (request? deliver+back : replace /item/new)
                         \--error--> Live + notice(noPhoto)
                                     Processing --error--> Live + notice(notProcessed)
  gallery --> Picking --asset--> Processing ...       ✕ --> back      keyboard --> /item/new

Live(fast, captured=0): shutter --> Shooting --uri--> Live(fast, captured=1, pipeline spawned)
                        ✕ or Done --> back
Live(fast, captured>0): mode locked; ✕ or Done --> replace /capture/review(since, expected=captured)
Any state --closedRef--> photos still processing are deleted (single) or keep landing (fast pipeline)
```

---

## 5. Fast capture pipeline (`src/services/capture/fastCapture.ts`)

Types:
- `StoredPhoto {uri, thumbUri, width, height, byteSize: Int?}` (`:4-10`).
- Deps `{storePhoto, createItem, updateItem, recognize}` (`:12-17`).
- Outcome: `recognized(itemId, name)` or `unrecognized(itemId, reason)` (`:19-21`).

`captureFastItem({containerId, photoUri, deps})` (`:49-105`):
1. `stored = await storePhoto(photoUri)` (`:54`). Errors propagate.
2. `item = await createItem({containerId, photo: {uri, thumbUri, width, height, byteSize?}})` with **no `name` key**. The row is unnamed (`name = ''`). A nil byte size is omitted (`:55-67`). Errors propagate. The repository writes the item and its photo row in one transaction (`src/repositories/items.ts:225-288`).
3. `result = await recognize(stored.uri)`. If `recognize` throws, treat it as `failed(server_error)` (`:69-76`).
4. If the result failed, return `unrecognized(item.id, reason)` and write nothing (`:78-82`).
5. `name = suggestion.name?.trim()`. If it is empty (defensive; the real parser never yields this), call `updateItem(id, {category, tags, expectedUpdatedAt: item.updatedAt})` and return `unrecognized(id, 'unrecognized')` (`:84-95`).
6. Otherwise call `updateItem(id, {name, category, tags, expectedUpdatedAt: item.updatedAt})` and return `recognized(id, name)` (`:97-104`).

Semantics:
- The row exists before recognition, so a crash loses only the name (`:29-48`).
- `updateItem` uses an optimistic lock. If the row changed in the meantime (named on another phone, say), `ConflictError` propagates. The camera then counts the shot as **dropped** (`index.tsx:294-298`) even though the row and photo exist. Native suggestion: catch the conflict in step 5/6 and return `unrecognized`. Flagged as deviation D3.
- No retry and no later re-recognition. Unnamed rows stay unnamed until a person names them (§12).
- If the row was deleted before recognition returned (say, from the review), the local `items.update` finds no row. It returns `null` without throwing (`src/repositories/items.ts:337-347`), and the pipeline still reports `recognized`.
- `expectedUpdatedAt` is `item.updatedAt` from `createItem`. The local repository always returns it (`items.ts:241-242`). If a dependency returns no `updatedAt`, the update runs without the optimistic lock (`items.ts:331-334`). The unit tests rely on this: their `createItem` returns only `{id}` (`fastCapture.test.ts:22-25`).
- In household mode, `createItem` first uploads the photo (`PUT /v1/photos/<newId>`, 60 s timeout) and then POSTs the item (`src/services/household/httpRepositories.ts:59-85`, `:248-268`). This is the household area's concern, but it makes the pipeline slower.

---

## 6. Review screen (`app/capture/review.tsx`)

The screen holds no session state of its own. It is a filtered read that re-runs whenever `invalidate()` is called (the source comment says "on every write"; §6.1 gives the precise triggers). That is what makes late recognition results appear live (`review.tsx:53-64`).

### 6.1 Inputs and query
- `containerId`, `since` (epoch ms string; `Number(since)`), `expected` (`Number(expected) || 0`) (`review.tsx:66-79`).
- `items = sessionItems(await listByContainer(containerId), since)` (`review.tsx:81-84`):
  - `listByContainer` is `ITEM_CONTEXT_SELECT … WHERE i.container_id = ? ORDER BY i.created_at DESC` (`items.ts:176-182`; projection `items.ts:72-91`, which takes the earliest photo per item for `photo_id`, `photo_uri` and `photo_thumb_uri`).
  - `sessionItems` keeps `createdAt >= since` and sorts **ascending** by `createdAt`. JS sort is stable, so ties keep the DESC input order (`fastReview.ts:22-24`).
- The read re-runs on mount, on focus, on pull-to-refresh, and whenever `invalidate()` is called while the screen is focused (`review.tsx:85`, `src/hooks/useInventoryQuery.ts:28-52`). Repository writes do **not** bump the revision by themselves; only explicit `invalidate()` calls do (`src/providers/DatabaseProvider.tsx:68`, `:108-121`). In this flow, `invalidate()` runs only:
  - when a fast pipeline **resolves**, that is after recognition and the name write (`index.tsx:292`);
  - in `finishFast` (`:304`);
  - after a delete on the review (`review.tsx:163`).
- Consequences:
  - A row appears in the review only once its whole pipeline has finished, already named or definitively unnamed. It does not appear when the row is inserted.
  - A pipeline that **rejects** triggers no refresh. Its row, if `createItem` succeeded, shows only on the next focus, pull-to-refresh or completion of another pipeline. Until then the stall timer can fire `maybeLost`.
- Session membership is purely `container_id == containerId && created_at >= since`. Any other row created in that container after `since` is shown and counted as saved: from the Add sheet, from another phone in household mode, or a late shot (§4.6).
- **Native (default, parity):** use the app-wide `InventoryQuery` + revision model (`09-app-shell-lifecycle-config.md` §5, `01-data.md` §1 decision 6 and §9.1), keyed `fast-review:<containerId>:<since>`, with the pipeline calling `invalidate()` exactly where RN does (above). This reproduces RN timing and works unchanged in household mode, where reads are HTTP. *(Consistency pass: the earlier recommendation here was GRDB `ValueObservation`, which contradicts the app-wide decision not to use DB observation.)*
- **Optional (only if Q14/D6 chooses live rows):** a local-mode GRDB `ValueObservation` over `… WHERE i.container_id = ? AND i.created_at >= ? ORDER BY i.created_at ASC` using the same projection. That is a **visible behavior change**: rows would appear at insert time as "Needs a name" (`strings.entities.unnamedItem`) and then be named in place, and each insert would restart the stall timer. Household mode would still need the revision model (or polling / the household change feed). If adopted, add a deterministic tiebreaker such as `, i.rowid ASC`: SQLite leaves the order of equal `created_at` values unspecified, and RN only preserves whatever order the DESC query returned.

### 6.2 Derived bookkeeping
- `landed`: every row id the set has shown, accumulated as each read arrives. It returns the same set when nothing is new (`review.tsx:105-111`, `withLanded` `captureFlow.ts:156-164`).
- `hidden`: rows deleted here are hidden at once until the next fresh read. Hiding is bound to the list instance it was made against (`review.tsx:88`, `:162`; `hideRow` / `visibleRows` `captureFlow.ts:197-210`).
- `list = visibleRows(loaded, hidden)`.
- `summary = summarizeSession(list, expectedStillShown(expected, landed.size, list.length))` (`review.tsx:113-117`):
  - `expectedStillShown(e, landed, shown) = max(0, e − max(0, landed − shown))` (`captureFlow.ts:173-175`).
  - `summarizeSession(items, expected)` (`fastReview.ts:26-37`): `saved = count`, `named = count where name.trim() != ""`, `unnamed = saved − named`, `pending = max(0, expected − saved)`.
- `label = containerLabel(loaded)`: `containerName ?? containerShortCode` of the first row of `loaded`, the list **before** hidden rows are removed, or nil for an empty list (`captureFlow.ts:106-112`). Only a NULL name falls back to the code; JS `??` would return an empty string as is.

### 6.3 Status, title and stall
- `signature = loaded.map("\(id):\(updatedAt)").joined("|")`, computed over `loaded` rather than the hidden-filtered `list` (`captureFlow.ts:182-184`, `review.tsx:123`).
- `waiting = pending > 0`. While waiting, a 30 s timer restarts whenever `signature` changes. When it fires, it records `quietSignature = signature` (`review.tsx:123-130`).
- `status = reviewStatus(summary, stalled: waiting && quietSignature == signature)` (`review.tsx:131`):
  - `pending > 0` → `stalled ? maybeLost : pending`, else `unnamed > 0 ? toName : allNamed` (`captureFlow.ts:80-83`).
- Status text (`captureFlow.ts:85-99`):
  - `pending` → `saved == 0 ? strings.review.savingFirst : strings.review.pending(pending)`
  - `maybeLost` → `strings.review.maybeLost`
  - `toName` → `strings.review.toName(unnamed)`
  - `allNamed` → `strings.review.allNamed`
- Title (`captureFlow.ts:120-130`):
  - `saved == 0 && status == pending` → `strings.review.savingTitle(pending)`
  - drop zone → `strings.review.savedToDropZone(saved)`
  - otherwise `label == nil ? nil : strings.review.savedTo(saved, label)`
- The header is shown only once data has loaded and `(list nonEmpty || status == pending)` (`review.tsx:219`). The status line uses an alert tone when `maybeLost` and is a polite live region (`:226-232`). A refresh-failed banner (`strings.errors.refreshFailed` with Try again) appears over stale data (`:236-244`), but only when the failure is neither `offline` nor `revoked`, which have their own connection banner (`needsRefreshBanner`, `src/ui/errors.ts:90-94`).

### 6.4 Empty and placeholder states (`review.tsx:250-272`)
- First read pending: a skeleton of `min(max(pending, 1), 4)` rows with 76 pt thumbs. If the first read failed: `ErrorState` with retry.
- `status == pending` and no rows: skeleton.
- Rows landed and then all left (`landed.size > 0`): `strings.review.emptied.title` / `.body`.
- Otherwise: `strings.review.nothing.title` / `.body` with action `strings.review.nothing.action`, which triggers Try again (§3 #9).

### 6.5 Rows and actions
- Row: the shared `ItemRow` with `line="detail"`, `tool="delete"` and a 76 pt thumb (`review.tsx:294-305`):
  - Title: the name, or `strings.entities.unnamedItem` when it is blank after trimming.
  - Second line: the category, with the quantity folded into it when it is not 1.
  - Delete button: labelled `strings.rows.deleteA11y(name)`, or `strings.rows.deletePhotoA11y` for an unnamed row.
  - Sources: `src/ui/components/ItemRow.tsx:51`, `:86-109`, `:241-269`. The row itself belongs to the shared-components area.
  - Tap → `/item/<id>?filing=1` for the drop zone, otherwise `/item/<id>` (`:136-140`).
- **Delete** (`review.tsx:142-172`):
  1. Single-flight guard (`deletingRef`).
  2. Confirm with title `strings.review.deleteTitle`, body `session ? strings.review.deleteBodyPaired : strings.review.deleteBodyLocal`, confirm label `strings.common.delete`.
  3. Call `repos.items.delete(id)`. If `deleted`, call `deleteStoredPhotos(orphanedPhotoUris)` and log `item_deleted`. If nothing was deleted, another phone got there first and the row still goes.
  4. Animate, hide the row, call `invalidate()`.
  5. On error: `describeError` → log `item_delete_failed {errorClass}`, error haptic, toast `strings.review.deleteFailed(kind == offline)`.
- Bottom bar: **Keep shooting** (`strings.review.keepShooting`, secondary) and **Done** (`strings.review.done`, primary) (`review.tsx:279-287`). Done, Keep shooting and Try again each fire once (`leavingRef`, `:92`).
- **Done** (`review.tsx:184-202`): log `fast_review_done {kept, unnamed}` (both keys are dropped by redaction, §17). Compute `report = reviewDoneToast(saved, containerId, label)`. Go back if possible, otherwise `openContainer(containerId)`. If `report` exists, show a toast; for the drop zone it carries the action **View** (`strings.common.view`, accessibility label `strings.review.viewDropZoneA11y`) → Drop zone tab.
  - `reviewDoneToast` (`captureFlow.ts:136-148`): `saved == 0` → nil. Drop zone → `strings.review.doneDropZone(saved)` with View. Container → `label == nil ? nil : strings.review.doneContainer(saved, label)`.

---

## 7. Drop zone hand-off
- Quick Snap from the tab bar, Home or the Drop zone tab always writes into `container_id = 'drop-zone'` (`navigation.ts:52-54`). Those rows are unnamed until recognized or named.
- The Drop zone tab lists `listUnsorted()`, newest first (`items.ts:185-191`). Owned by the drop-zone area.
- From the review, tapping a drop-zone row opens a **filing run** (`/item/<id>?filing=1`). The item screen shows `NameItInline` while the item is unnamed or the field is in use (`app/item/[id]/index.tsx:162-164`, `:337-350`). "File it…" first commits a typed but unsaved name, and moves nothing if that fails (`index.tsx:189`, `NameItInline.tsx:175-185`).
- Done's toast offers **View** → Drop zone tab (§6.5).

---

## 8. Camera configuration

### 8.1 Current iOS behavior (expo-camera 57.0.3 plus the patch)

| Aspect | Current behavior | Source |
|---|---|---|
| Lens | Back camera only, no switch UI. Default device is the first available of `.builtInTripleCamera`, `.builtInDualWideCamera`, `.builtInDualCamera`, `.builtInWideAngleCamera`, then iOS 17+ `systemPreferredCamera`. Virtual devices auto-switch to ultra-wide for close subjects ("macro" like Camera.app) | `index.tsx:408`; patch `:219-238`; `node_modules/expo-camera/ios/Common/DeviceDiscovery.swift:109-130` |
| Zoom | Fixed. The `zoom` prop defaults to 0, so `videoZoomFactor = minZoom × (max/min)^0 = minZoom`, where `minZoom` is the first `virtualDeviceSwitchOverVideoZoomFactors` value (the "1×" wide lens, e.g. 2.0 on a triple camera) or 1.0. No pinch-to-zoom | patch `:297-309`; `CameraSessionManager.swift:244-260` |
| Focus mode | `autofocus="off"` maps to `.continuousAutoFocus` on iOS (`'on'` would be one-shot `.autoFocus` and locks after a shot, issue #44). Applied right after the input is added. `isSmoothAutoFocusEnabled = true` when supported | `index.tsx:410-411`; `CameraEnums.swift:41-52`; patch `:258-265`, `:311-317`; `CameraSessionManager.swift:196-213` |
| Exposure | System default (continuous) until the first tap | n/a |
| Flash | `'off'` by default, toggled to `'on'`; mapped to `AVCapturePhotoSettings.flashMode` `.off` / `.on` if the output supports it. No auto, no torch | `index.tsx:82`, `:442`; `CameraEnums.swift:18-33`; `CameraPhotoCapture.swift:87-90` |
| Session preset | `.photo` (picture size default `Photo`), falling back to `.high` | `CameraView.swift:101`; `CameraRecordingOptions.swift:56-80`; `CameraSessionManager.swift:56-77`, `:444` |
| Codec | HEVC when available | `CameraPhotoCapture.swift:83-85` |
| Resolution | `settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions` (the output default; never raised) | `CameraPhotoCapture.swift:92-94` |
| Quality prioritization | `.quality` (patched from `.balanced`; see C5) | patch `:245-251`; `CameraPhotoCapture.swift:105` |
| Responsive capture / zero shutter lag | Disabled: "ZSL can fire before AF settles". Fast-capture prioritization not enabled. Auto-deferred delivery off | patch `:319-330`; `CameraSessionManager.swift:407-414` |
| Live Photo | Off | `CameraSessionManager.swift:434` |
| Shutter sound | System default | `Common/PictureOptions.swift` (`shutterSound = true`) |
| Preview | `AVCaptureVideoPreviewLayer`, `.resizeAspectFill`, full screen. Rotation through `AVCaptureDevice.RotationCoordinator` (iOS 17+) | `CameraView.swift:189`, `:377-417` |
| Capture orientation | `connection.videoOrientation` from `UIDevice.current.orientation`, because `responsiveWhenOrientationLocked` is false (`CameraView.swift:45`). Mapping: portrait → portrait, upside-down → upside-down, device landscapeLeft/Right → video landscapeRight/Left, and **faceUp, faceDown or unknown → portrait** (`Common/ExpoCameraUtils.swift:66-79`). The app UI is portrait-locked on iPhone (`app.json:6`; the prebuild-generated, git-ignored `ios/Inventory/Info.plist` lists Portrait and PortraitUpsideDown on iPhone and all four orientations on iPad). Native: `RotationCoordinator.videoRotationAngleForHorizonLevelCapture` keeps the last non-flat angle when the phone lies flat, which is a small deviation from "flat = portrait" | `CameraPhotoCapture.swift:73-76` |
| Crop | Center-crop to the preview aspect: `AVMakeRect(aspectRatio: previewSize (w/h swapped in portrait), insideRect: full sensor rect)` (C4) | `CameraPhotoCapture.swift:159-167`, `:187-190` |
| Intermediate file | `exif:false` → `UIImage.jpegData(compressionQuality: 1.0)` → `Caches/Camera/<uuid>.jpg`. Never deleted by the app | `CameraPhotoCapture.swift:240-246`, `:259-266` |
| Lifecycle | Session stops on background and restarts on foreground. On `mediaServicesWereReset` it restarts **and** fires `onMountError`, so `strings.capture.didNotStart` shows even though the camera recovered | `CameraView.swift:224-246`; `CameraSessionManager.swift:334-352` |
| Unmount mid-capture | The capture call rejects (`CameraUnmountedException`); swallowed by the `closedRef` logic | `CameraPhotoCapture.swift:281-284` |
| Concurrent capture | A second call while one is in flight throws `CameraNotReadyException`. App-level guards prevent it | `CameraPhotoCapture.swift:65-67`; `index.tsx:110`, `:103` |

### 8.2 Tap-to-focus (current)
- A full-screen transparent tap layer sits over the preview, under the chrome. Accessibility: a button labelled `strings.capture.tapToFocus` (`TapToFocusLayer.tsx:23-57`).
- On tap at view point `(x, y)`:
  1. Call `focusAsync({x, y})` (`index.tsx:415-419`).
  2. Convert with `previewLayer.captureDevicePointConverted(fromLayerPoint:)` and hop to the session queue (`CameraView.swift:201-206`, patch `:336-357`).
  3. `lockForConfiguration`.
  4. If the focus point of interest is supported: set it, then `focusMode = .continuousAutoFocus` (else `.autoFocus`).
  5. If the exposure point of interest is supported: set it, then `exposureMode = .continuousAutoExposure` (else `.autoExpose`) (`CameraSessionManager.swift:215-242`, patch `:270-295`).
  6. Errors are logged only.
- The point of interest persists until the next tap or remount. No subject-area-change reset. No AE/AF lock.
- Focus square: 72 pt, 2 pt border in `camera.accent`, corner radius 4, centered on the tap via `focusSpotOffset(x, y) = (x − 36, y − 36)`. Visible 700 ms. A new tap replaces it (`TapToFocusLayer.tsx:7-12`, `:28-34`, `:60-68`).
- The patch also adds a native `UITapGestureRecognizer` on the camera view (`cancelsTouchesInView = false`; `CameraView.swift:190-199`). It never fires in this app because the RN tap layer sits on top. Both paths call the same function.

### 8.3 Native implementation (AVFoundation)
- **`actor CameraService`** with a custom serial executor backed by a `DispatchSerialQueue` (Apple's AVCam pattern for iOS 18+). It owns `AVCaptureSession`, `AVCaptureDeviceInput` and `AVCapturePhotoOutput`. Only Sendable values (`CGPoint`, enums, `Data`) cross actors. Never touch session objects from the MainActor.
- Device: same preference list as 8.1. Set `videoZoomFactor` to the first switch-over factor (falling back to 1.0) under `lockForConfiguration`. Leave constituent switching automatic.
- Before `startRunning()`, inside `beginConfiguration` / `commitConfiguration`:
  - `sessionPreset = .photo`
  - add the photo output
  - `maxPhotoQualityPrioritization = .quality` (C5)
  - `isLivePhotoCaptureEnabled = false`
  - `isResponsiveCaptureEnabled = false` and `isAutoDeferredPhotoDeliveryEnabled = false` (decision D4: enable responsive and fast-capture prioritization for Quick Snap speed at the cost of AF settling)
  - continuous AF and AE
- Per capture:
  - `AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])` when available
  - `flashMode` if supported
  - `photoQualityPrioritization = .quality`
  - `maxPhotoDimensions = output.maxPhotoDimensions`
  - capture rotation from `RotationCoordinator.videoRotationAngleForHorizonLevelCapture`
- Delegate → `withCheckedThrowingContinuation`. Release the shutter guard on `didFinishProcessingPhoto`, hand `photo.fileDataRepresentation()` (HEIC `Data`) straight to the image pipeline, and **skip the q=1.0 JPEG intermediate**. If D2 keeps the crop, apply it in the image pipeline (§9.8).
- Preview: `UIViewRepresentable` whose `layerClass` is `AVCaptureVideoPreviewLayer`, `.resizeAspectFill`, with `RotationCoordinator.videoRotationAngleForHorizonLevelPreview`.
- Interruptions: observe `AVCaptureSession.wasInterruptedNotification` / `interruptionEndedNotification` (calls, Split View) and `runtimeErrorNotification`. On `mediaServicesWereReset`, restart **without** showing `didNotStart`. Show `didNotStart` only when configuration or start actually fails, or the device is unavailable.
- Start and stop the session with the screen (on appear and disappear) and with `scenePhase`.
- Optional system-camera parity: `AVCaptureEventInteraction` so the volume buttons and Camera Control fire the shutter (iOS 17.2+ / 18+).
- Simulator: there is no camera. expo-camera substitutes a generated image in the simulator (`CameraViewModule.swift:274-280`, `takePictureForSimulator`). Native: show a placeholder preview and keep the library import working, so the flows stay testable in the simulator.

### 8.4 "Focus like the system camera": decision D5
- **A (literal port):** continuous AF and AE at the tapped point, smooth AF on (current patch behavior).
- **B (recommended, AVCam / Camera.app style):**
  - On tap: set the focus and exposure points of interest, `focusMode = .autoFocus` (one-shot), `exposureMode = .continuousAutoExposure`, and `isSubjectAreaChangeMonitoringEnabled = true`.
  - On `AVCaptureDevice.subjectAreaDidChangeNotification`: reset both points to `(0.5, 0.5)` with `.continuousAutoFocus` and `.continuousAutoExposure`.
  - Do **not** enable smooth AF for stills. It is tuned for video and slows focus pulls.
  - Draw the focus square (accent `#FFD23F`, which is also Camera.app's yellow) for 700 ms.
  - Optional: long-press for AE/AF lock.
- VisionKit has no still-capture API. `DataScannerViewController` belongs to the Scan tab area. Nothing in VisionKit replaces `AVCapturePhotoOutput` here.

---

## 9. Image processing and storage (`src/services/capture/imageStore.ts`, `imageScaling.ts`)

### 9.1 `scaleToFit(width, height, maxEdge) -> (w, h)?` (`imageScaling.ts:50-64`)
1. `longest = max(w, h)`. If `longest <= maxEdge`, return nil: leave the image alone and never enlarge.
2. `scale = maxEdge / longest`. Return `(max(1, round(w × scale)), max(1, round(h × scale)))`. JS `Math.round` rounds .5 toward +∞; for positive numbers use `(x + 0.5).rounded(.down)`. `.toNearestOrAwayFromZero` is identical for positives.

### 9.2 `storeItemPhoto(sourceUri) -> StoredImage` (`imageStore.ts:100-134`)
`StoredImage {uri, thumbUri, width, height, byteSize: Int?}` (`:30-37`).
1. Decode the source **once**. Expo always adds `ImageFixOrientationTransformer`, so EXIF orientation is baked into the pixels (`imageStore.ts:104`, `node_modules/expo-image-manipulator/ios/ImageManipulatorModule.swift:27-28`; HEIC and EXIF are read through `UIImage(data:)`, `ImageManipulatorUtils.swift:37-41`).
2. `photoId = newId()`: an RFC 4122 v4 UUID, lowercase hex with dashes (`src/core/id.ts:41-54`, `src/core/bytes.ts:11-17`). Swift: `UUID().uuidString.lowercased()`, because `uuidString` is uppercase. The same applies to every id this area writes (`item_photos.id`, `items.id`).
3. Full image: `target = scaleToFit(src.w, src.h, 1400)`. If non-nil, resize to exactly `target` (both dimensions explicit, so rounding is ours). Encode WebP at quality 0.8 (`imageStore.ts:61-68`). Expo writes to `Caches/ImageManipulator/<UUID>.webp` (`ImageManipulatorUtils.swift:112-125`).
4. Thumbnail: the same function with 320 and 0.7, **from the same decoded source** (not from the full image).
5. `adopt` each file into `<Documents>/item-photos/` as `<photoId>.webp` and `<photoId>-thumb.webp`. Create the directory with intermediates. Delete an existing destination. Read the temp size, then move (`imageStore.ts:39-53`, `:76-87`).
6. Return `{uri: full destination URL string, thumbUri, width: full.width, height: full.height, byteSize: full size or nil}`. Width and height always equal the stored file's pixel dimensions.
7. Log `photo_stored {durationMs, byteSize}`.
8. Any error: log `photo_store_failed {durationMs, errorClass: error.name or 'unknown'}` and throw `"That photo could not be processed. Try again or continue without a photo."`. That message is never shown; callers map the failure to their own copy.

Properties to preserve:
- Every input is re-encoded to WebP, even small ones (no upscaling).
- No EXIF, GPS or other metadata is written (pixels only). Library imports therefore lose their location data, which is a privacy property to keep.
- `photoId` (the file name) **is not** `item_photos.id`. The repository generates its own id (`items.ts:269`). After a backup restore, files are named by `item_photos.id` (`photoSync.ts:157`). Never derive one from the other.
- The source temp file (camera JPEG or picker copy) is never deleted (the OS may purge `Caches`). Native: delete it as soon as it is stored.
- Expo renders with `opaque = false` (`ImageResizeTransformer.swift`). Native: render **opaque, 8-bit sRGB** before the WebP encode (libwebp ignores ICC on encode).

### 9.3 Restore, read, delete, free space
- `writeStoredPhoto(photoId, bytes)` (restore, used by the sync area) (`imageStore.ts:161-178`):
  1. Write the bytes **verbatim** to `item-photos/<photoId>.webp`, deleting any existing file first. They may actually be legacy JPEG bytes under a `.webp` name; decoders sniff the content.
  2. Decode and regenerate `<photoId>-thumb.webp` (320 / 0.7).
  3. Return `{uri, thumbUri, width: src.width, height: src.height, byteSize: file size or bytes.count}`.
  4. There is no try/catch, so errors propagate to the sync caller. If decoding fails, the full file has already been written, no thumbnail exists, and the caller does not update the row. The full image is never resized, so a legacy photo larger than 1400 px stays as it was.
- `readStoredPhoto(uri) -> Data?`: nil if the file is missing or on any error (`imageStore.ts:137-145`).
- `deleteStoredPhotos([uri?])`: best effort. Skips nil and empty values and ignores errors (`imageStore.ts:188-198`).
- `hasRoomForPhoto(estimated = 1_000_000)`: `availableDiskSpace > estimated × 2`. Returns true on exception (`imageStore.ts:201-207`). Expo reads `systemFreeSize` of the Documents volume (`node_modules/expo-file-system/ios/FileSystemModule.swift:29-35`). Note that in JS a nil value compares `null > n == false`, so it reports "no room". Behavior-identical native code would read `FileManager.attributesOfFileSystem(forPath: documents)[.systemFreeSize]`, return **false** when the value is missing, and return true only when the call throws. The spec's earlier suggestion was `URLResourceValues.volumeAvailableCapacityForImportantUsage` with the same `> 2_000_000` threshold, returning true when it cannot be read. That is two deliberate deviations: it counts purgeable space (so it reports more room), and it treats an unreadable value as room. Pick one knowingly; either is acceptable for a 2 MB guard.

### 9.4 Database rows written (schema must stay byte-compatible)
- `item_photos (id TEXT PRIMARY KEY NOT NULL, item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE, uri TEXT NOT NULL, width INTEGER, height INTEGER, byte_size INTEGER, created_at INTEGER NOT NULL)` plus `CREATE INDEX idx_item_photos_item ON item_photos(item_id)` (`src/db/migrations.ts:64-73`).
- Plus `remote_synced_at INTEGER` and a partial index on unsynced rows, and the `sync_deletions` tombstone trigger `AFTER DELETE … WHEN OLD.remote_synced_at IS NOT NULL` (`migrations.ts:146-180`).
- Plus `thumb_uri TEXT` (`migrations.ts:185-196`).
- Insert used by create (`items.ts:264-277`): `INSERT INTO item_photos (id, item_id, uri, thumb_uri, width, height, byte_size, created_at) VALUES (?,?,?,?,?,?,?,?)`. Values: `draft.photo.id ?? newId()` (the home server passes its R2 object id; the capture paths never pass one), the item id, the full URI, the thumbnail URI (`?? NULL`), width, height and byte size (each `?? NULL`), and `now` (epoch ms, the same `now` as `items.created_at`). The item row itself is inserted first in the same transaction. A Quick Snap row has `name = ''`, `category = NULL`, `quantity = 1`, `notes = NULL` and `search_text = ''` (`items.ts:226-262`; DB area). `remote_synced_at` stays NULL, so the backup uploader picks the row up (sync area).
- Only one photo per item in practice. Reads take the earliest row (`items.ts:72-80`).

### 9.5 URI format
Write the same format the RN app writes: `URL.absoluteString` of the file, `file:///…/Documents/item-photos/<uuid>.webp`. Backups and household dumps carry these strings, and other readers resolve them with §9.7.

### 9.6 Lists and the viewer
- Lists use `photoThumbUri ?? photoUri` (`Thumb.tsx:8-10`).
- The viewer uses `photoUri ?? photoThumbUri` (`app/item/[id]/photo.tsx:101`).
- Rows from before migration 5 have no thumbnail and fall back to the full image.

### 9.7 Photo path resolution (required by C1): use `PhotoPathResolver`

**Canonical spec and code: `02-device-storage-migration.md` §3.3 (`PhotoPathResolver`).** Do not implement a second resolver. Summary of its rules:
1. Parse with `URL(string:)`. If it is not a file URL, return nil: `r2:` and http URIs are household or remote and are resolved by the household photo cache (`src/services/household/photoCache.ts:11-41`).
2. If a file exists at `url.path`, return it (the common case).
3. Otherwise take the **last path component** and look at the **parent folder name**: `item-photos` → try `<current Documents>/item-photos/<name>`; `household-photos` → try `<current Caches>/household-photos/<name>`; anything else → nil. Return the candidate only if it exists.
4. Otherwise nil. The caller shows the placeholder or the photo-missing state, and the sync area may rehydrate the file.

Why not "rebase the suffix after the last `/Documents/`" (the earlier draft of this section): rows restored from an **Android** backup hold `file:///data/user/0/com.wystudio.inventory/files/item-photos/<name>.webp` (02 §3.2 shape 4), which contains no `/Documents/`. Rehydration writes those files into the iOS `item-photos/` under the same name, and only the parent-folder rule finds them.

Optional one-time row rewrite ("self-heal", open question 02 Q4): `UPDATE item_photos SET uri = ?, thumb_uri = ? WHERE id = ?` with `PhotoPathResolver.storedURI(forPhotoNamed:)` for rows that resolved only through rule 3. One transaction, same shape-1 format, no schema change.

### 9.8 Native implementation
1. **Decode and downsample with ImageIO:** `CGImageSourceCreateWithData` (from the HEIC capture data) or `CGImageSourceCreateWithURL` (picker file), with `kCGImageSourceShouldCache: false`. Then `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailFromImageAlways: true`, `kCGImageSourceCreateThumbnailWithTransform: true` (bakes orientation) and `kCGImageSourceThumbnailMaxPixelSize: 1400`. This avoids a full 12–48 MP RGBA decode. ImageIO's rounding can differ from `scaleToFit` by about 1 px. That is acceptable as long as the recorded width and height are read from the output image. For exact parity, compute `scaleToFit` and draw into a `CGContext` of that size.
2. **Crop (only if D2 keeps the RN behavior):** center-crop the downsampled image to the preview aspect. On every iPhone the preview is taller than 4:3, so the crop only shortens the short edge and downsample-then-crop equals crop-then-downsample.
3. **Thumbnail:** max pixel size 320, from the same source.
4. **Encode WebP with libwebp:** lossy, quality 80 / 70, default preset (`SDImageWebPCoder` with `.encodeCompressionQuality: 0.8 / 0.7` gives parity with Expo).
5. Write atomically to `<Documents>/item-photos/<uuid>.webp` and `-thumb.webp`. There is no need for a temp-and-move step. Keep the files in Documents so they are included in device backups, and do not set `isExcludedFromBackup`.
6. Run this inside a dedicated **serial** `actor ImageStore` so a Quick Snap burst cannot exhaust memory. expo-camera itself serializes still processing for that reason (`CameraPhotoCapture.swift:20-25`).

### 9.9 First native launch: leftover Expo files (in-place upgrade)
- The RN build leaves temporary files that no DB row references and that the app never deletes:
  - `Library/Caches/Camera/*.jpg` (expo-camera q=1.0 stills; `CameraPhotoCapture.swift:259-265`);
  - `Library/Caches/ImageManipulator/*.webp` (renders that were not adopted, for example after a failed `adopt`; `ImageManipulatorUtils.swift:118-128`);
  - `Library/Caches/ImagePicker/*` (picker copies; `node_modules/expo-image-picker/ios/MediaHandler.swift:494-495`).
- They are safe to delete on first native launch. Never touch `Documents/item-photos/` or `Library/Caches/household-photos/`. The latter is the household photo cache, owned by the household area.
- `Documents/item-photos/` also collects orphans, from two sources:
  - Photos of Add-sheet drafts lost when the app was killed, because the draft lives in memory only (`src/ui/add/addDraft.ts:4-13`).
  - Every photo captured in household mode. There, `items.create` uploads the photo and **copies** the local files into `Caches/household-photos/<serverPhotoId>[-thumb].webp` (`src/services/household/httpRepositories.ts:248-266`, `photoCache.ts:43-58`). The local shadow row stores the server's URI (`src/services/household/shadow.ts:200-219`), so the originals are referenced by nothing.
- A sweep that deletes files not referenced by any `item_photos.uri`/`thumb_uri` row would remove both kinds. It looks safe, but confirm with the household and sync areas first (Q15).

---

## 10. Recognition wire contract

### 10.1 Configuration (`src/services/config.ts:65-68`)
- Endpoint: `EXPO_PUBLIC_RECOGNITION_URL`, trimmed, empty → nil. Production is `https://server-wy-studio.vercel.app/api/recognize` (`eas.json:34`, production profile only; the development and preview profiles set no URL, so those builds are `not_configured` unless a local env provides one). Local development is `http://localhost:8787/api/recognize` (`server/dev-server.mjs:19`, `.env.example:15`). The git-ignored `.env.local` on this machine points at `vercel dev` on `:3000` instead.
- Key: `EXPO_PUBLIC_RECOGNITION_KEY`, trimmed, empty → nil. It is **public by design**: it ships in the bundle and only deters casual abuse (`server/src/auth.ts:3-12`). Its value is not in the repo; it lives in the EAS environment or `.env.local`.
- Timeout: `EXPO_PUBLIC_RECOGNITION_TIMEOUT_MS`, default 15 000.
- **Native:** build settings in an xcconfig → `Info.plist` keys (for example `RecognitionURL`, `RecognitionKey`, `RecognitionTimeoutMs`), read once into an immutable `AppConfig` (Sendable). Local `http` needs ATS `NSAllowsLocalNetworking`.

### 10.2 Request (`src/services/ai/recognition.ts:63-153`)
1. If the endpoint is nil: log `recognition_skipped {outcome:'not_configured'}` and return `failed(not_configured)` without any I/O (`:71-74`).
2. `hint = nameHint?.trim()`, empty → nil. `hinted = hint != nil` (`:76-78`).
3. Start the deadline timer **before** reading the file, so the budget covers the file read, base64, upload and response (`:81-83`).
4. `base64 = read(imageUri).base64()`: standard alphabet, padded, no line breaks (`:86`, `:33-38`).
5. `POST <endpoint>` (`:88-103`) with headers:
   - `Content-Type: application/json`
   - `X-Contract-Version: 1` (the server ignores it)
   - `x-inventory-key: <key>`, only when a key is configured
   - **never** `Authorization` or `x-api-key` (tested)

Body (JSON):
```json
{
  "contractVersion": 1,
  "image": { "data": "<base64>", "encoding": "base64", "mediaType": "image/jpeg" },
  "nameHint": "Angle grinder"
}
```

| Field | Type | Rule |
|---|---|---|
| `contractVersion` | number | always 1 |
| `image.data` | string | base64 of the stored file bytes (WebP in practice, C2) |
| `image.encoding` | string | always `"base64"` |
| `image.mediaType` | string | currently always `"image/jpeg"` (D1: send the real type) |
| `nameHint` | string | **omitted entirely** when absent or blank, never `null` or `""` (`:98-100`) |
| `adapter` | string | server-side A/B override; the app never sends it (`server/src/contract.ts:19`) |

Swift: `JSONEncoder` with `.withoutEscapingSlashes` (base64 contains `/`; escaping is valid but inflates the body), `encodeIfPresent` for `nameHint`. Key order does not matter.

### 10.3 Server behavior (unchanged backend; defines the responses)
`POST /api/recognize` (`server/api/recognize.ts:31-104`):
1. **Auth before reading the body** (`:36-40`, `server/src/auth.ts:19-31`). If `RECOGNITION_SHARED_SECRET` is unset, the endpoint is open. A missing header → 401 `{"error":"Missing credentials."}`. A wrong value → 401 `{"error":"Invalid credentials."}`. The comparison is constant-time and safe for different lengths (`auth.ts:39-51`).
2. Invalid JSON → 400 `{"error":"Body must be valid JSON."}` (`:42-47`).
3. `parseRequest` (`server/src/contract.ts:56-112`) returns 400 or 413 `{"error": msg}` in this order:
   - not an object
   - `contractVersion !== 1`
   - `image` not an object or `image.data` not a string
   - `encoding !== 'base64'`
   - base64 length > 8 MiB × 1.4 → **413**
   - decoded to 0 bytes
   - decoded > 8 MiB → **413**

   Then `mediaType` is lowercased if it is a string matching `^image\/[a-z0-9.+-]+$` **case-insensitively** (`/i`); otherwise it defaults to `image/jpeg`. The "not valid base64" 400 (`contract.ts:85-90`) is unreachable in practice, because Node's `Buffer.from(…, 'base64')` skips invalid characters instead of throwing. `nameHint` is cleaned: whitespace runs collapse to one space, the result is trimmed and cut to 80 characters, and empty or non-string becomes absent (`:44-48`).
4. Unknown `adapter` → 400. If the default adapter is misconfigured, `UnknownAdapterError` → 500 (`recognize.ts:55-58`, `:89-91`).
5. Provider call with a 12 s abort (`:60-69`). Adapter `claude-haiku` → model `claude-haiku-5-5` (default; env `RECOGNITION_ADAPTER`). `claude-sonnet` → `claude-sonnet-5` (`server/src/adapters/index.ts:15-37`). Messages API structured output with schema `{identified: bool, name: string|null, category: string|null, tags: string[], confidence: number}`, `effort: low`, `max_tokens: 4096`. System prompt `SYSTEM_PROMPT`; user turn `userPrompt(nameHint)` (`server/src/prompt.ts:10-72`; `anthropicVision.ts:51-115`).
   - Unsupported media type (not jpeg, png, gif or webp) → upstream error before any call (`anthropicVision.ts:52-58`).
   - `stop_reason == 'refusal'` → unrecognized (`:91-93`).
   - No parsed output → upstream (`:95-102`).
   - `!identified` or no name (and no hint) → unrecognized (`:107-109`).
   - Otherwise `toRawSuggestion(output, hint)` (`prompt.ts:81-100`): `name = clean(hint ?? model name)` (trim, cut at 80, empty → nil); `category = clean(...)`; tags trimmed, lowercased, kept if 1…40 characters, deduped in first-seen order, max 8; `confidence` clamped to [0, 1].
   - SDK abort or connection timeout → timeout. `RateLimitError` → rate_limited. Anything else → upstream (`anthropicVision.ts:125-140`).
6. Responses:

| HTTP | Body | Client result |
|---|---|---|
| 200 | `{"contractVersion":1,"suggestion":{"name":…,"category":…,"tags":[…],"confidence":…}}` (`contract.ts:115-125`) | parsed (§10.4) |
| 200 | `{"contractVersion":1,"status":"unrecognized"}` (`contract.ts:128-130`) | `failed(unrecognized)` |
| 429 | `{"error":"rate_limited"}` | `failed(rate_limited)` |
| 504 | `{"error":"timeout"}` | `failed(server_error)` (not `timeout`) |
| 502 | `{"error":"upstream"}` | `failed(server_error)` |
| 400 / 401 / 413 / 500 | `{"error": "…"}` | `failed(server_error)` |

`GET /api/adapters` returns `{contractVersion, adapters:[{id, label, default}]}` (`server/api/adapters.ts:12-23`). The app never calls it.

Payload note: Vercel function request bodies are limited to about 4.5 MB, below the server's 8 MiB check. Stored photos (≤1400 px WebP, typically a few hundred KB) are far under both limits.

### 10.4 Client response parsing: `parseRecognitionResponse(body)` (`src/services/ai/contract.ts:57-116`)
Order matters:
1. Body is not a JSON object → `malformed_response`.
2. `contractVersion` is not a number → `malformed_response`. It is not 1 → `unsupported_version`.
3. `status == "unrecognized"` → `unrecognized`.
4. `suggestion` is not an object → `malformed_response`.
5. `confidence = cleanNumber(raw.confidence)`, where a value that is not a finite number or is negative becomes nil. If nil or > 1 → `malformed_response` (checked **before** the name).
6. `name = cleanText(raw.name)`, where a non-string becomes nil and a string is trimmed then cut to 80 UTF-16 units, with empty → nil. A nil name → `unrecognized`.
7. `confidence < 0.35` → `low_confidence` (exactly 0.35 passes).
8. `tags`: if an array, map with `cleanText`, drop nils, keep the first 8. Otherwise `[]`.
9. `success {name, category: cleanText(raw.category), tags, confidence, contractVersion}`. A non-string category becomes nil and is not an error.

Native: parse untrusted JSON leniently with `JSONSerialization` or a permissive decoder. A strict `Codable` would turn `category: 42` into a failure instead of nil.
- `JSONSerialization` bridges JSON `true`/`false` to `NSNumber`, so `as? Double` succeeds on them. JS rejects `contractVersion: true` and `confidence: true` (`typeof` is `boolean`) as `malformed_response`. Exclude booleans explicitly (`CFGetTypeID(n) == CFBooleanGetTypeID()`), or decode into a `JSONValue` enum that tries `Bool` before `Double`.
- `contractVersion: 1.0` is the number 1 and is accepted.
- A top-level JSON array, or `suggestion` as an array, reaches `malformed_response` in JS through a missing field. Rejecting arrays as "not an object" gives the same result. JS `trim()` strips Unicode whitespace including U+FEFF; use `.whitespacesAndNewlines` plus U+FEFF. `slice(0, 80)` counts UTF-16 units; cut at 80 UTF-16 units and drop a trailing lone high surrogate. The result is **not** re-trimmed after cutting.

### 10.5 Failure classification (`recognition.ts:40-51`, `:105-149`)

| Condition | Reason |
|---|---|
| No endpoint | `not_configured` |
| Deadline abort (`AbortError`) | `timeout` |
| Transport error whose message matches `/network\|fetch failed\|internet\|unreachable/i`. On RN iOS every transport failure surfaces as "Network request failed" | `offline` |
| Any other thrown error, including a failed file read | `server_error` |
| HTTP 429 | `rate_limited` |
| Any other non-2xx | `server_error` |
| 2xx with a body that is not JSON | `malformed_response` |
| Otherwise | result of §10.4 |

Native mapping:
- Our deadline (`CancellationError` from a timeout race) and `URLError.timedOut` → `timeout`.
- `URLError` `.notConnectedToInternet`, `.networkConnectionLost`, `.cannotFindHost`, `.cannotConnectToHost`, `.dnsLookupFailed`, `.dataNotAllowed`, `.internationalRoamingOff`, `.secureConnectionFailed` and other transport codes → `offline`. This is behavior-identical to RN, where every transport failure reads "Network request failed".
- File read failure → `server_error`.
- Implement the wall-clock budget as a race between `URLSession.data(for:)` and `Task.sleep(for: timeout)` in a task group. `URLRequest.timeoutInterval` is an idle timeout, not a total one.
- `URLError.timedOut` → `timeout` deviates slightly from RN. There, a transport-level timeout surfaces as "Network request timed out" and the regex classifies it as `offline`. In practice this is unreachable, because RN's 60 s default is longer than the 15 s deadline. Keep `timeoutInterval` above the deadline so the deadline always wins.
- Config parsing: RN computes `Number(env ?? 15000)` without validation (`config.ts:68`). A non-numeric value gives `NaN`, the timer fires at once, and every request ends as `timeout`. Native: validate, and fall back to 15 000 ms.

The client **never throws**: every path returns a `RecognitionResult` (`recognition.ts:53-62`). There is no automatic retry or backoff. Retry is manual from the suggestion banner (§11).

```swift
enum RecognitionFailureReason: String, Sendable { case not_configured, offline, timeout, rate_limited, server_error, malformed_response, unsupported_version, low_confidence, unrecognized }
struct RecognitionSuggestion: Sendable, Equatable { var name: String?; var category: String?; var tags: [String]; var confidence: Double }
enum RecognitionResult: Sendable { case success(RecognitionSuggestion, contractVersion: Int); case failed(RecognitionFailureReason) }
```

### 10.6 Telemetry (privacy: no image, no suggestion text, no typed text)
- `recognition_skipped {outcome}`.
- `recognition_failed` (error) `{outcome, statusCode?, latencyMs, contractVersion, hinted}` for non-2xx (`:106-112`), bad JSON (`:121-126`) and thrown errors (`:143-148`).
- `recognition_completed {outcome: 'success' | reason, latencyMs, contractVersion, confidence | null, hinted}` (`:132-138`).

---

## 11. How suggestions populate forms

### 11.1 Add sheet (`app/item/new.tsx`; the sheet itself belongs to the Add area)
- Initial state (`src/ui/add/addSheet.ts:119-153`):
  - Params with `photoUri` → `photo = photoFromParams` (positive-integer parsing via `toPositiveInt`, `addSheet.ts:36-52`), `suggestion = running`, `recognize = true`.
  - A plain open restores a fresh draft. A draft cut off while `running` or `refreshing` restarts recognition if it has a photo, and becomes `idle` if it has none.
- On arrival, if `recognize` is set: `runRecognition(photo.uri, initialName.trim() || nil)` (`new.tsx:275-285`). The name field is not auto-focused when a photo is present (`:290`).
- `runRecognition(uri, nameHint?, overwrite = false)` (`new.tsx:247-273`):
  1. `recognitionRef = uri`.
  2. Await `recognizeItem`. If `recognitionRef != uri` by then, drop the answer (photo removed, retaken or cancelled).
  3. `failed(r)` → `suggestion = failed(r)`.
  4. Success → `values = applySuggestion(values, s, overwrite)` using the **latest** values. Then `suggestion = (overwrite && hint) ? refreshed(forName: hint) : applied(confidence, forName: s.name ?? "")`.
- `applySuggestion(current, s, overwrite)` (`src/ui/components/ItemForm.tsx:97-114`):
  - `name = current.name.isEmpty ? (s.name ?? "") : current.name`. The name is never replaced once the field holds anything, even whitespace, because `current.name ||` tests the raw string.
  - `overwrite`: `category = s.category ?? ""`, `tags = s.tags.joined(", ")`.
  - Otherwise: `category = current.category.isEmpty ? (s.category ?? "") : current.category`, `tags = current.tags.isEmpty ? joinedTags : current.tags`.
  - Quantity and notes are never touched.
- Staleness (derived on every render): `staleSuggestionName(state, typedName)` (`src/ui/components/SuggestionBanner.tsx:30-37`). Non-nil only when the state is `applied` or `refreshed`, the trimmed typed name is non-empty, and it differs from `forName`. When non-nil, the banner shows `stale(forName: typed)` instead of the stored state (`new.tsx:715`).
- Actions:
  - **Retry**: `suggestion = running`, then `runRecognition(uri, typedName || nil)` with no overwrite (`new.tsx:716-722`).
  - **Update the other details**: `suggestion = refreshing`, then `runRecognition(uri, staleName, overwrite: true)` (`new.tsx:723-729`).
- Removing, retaking or cancelling: `recognitionRef = nil`, delete both files, `suggestion = idle` (`new.tsx:374-379`, `:438-454`).
- The draft owns the photo until save. A replaced or stale draft deletes its photo files (`src/ui/add/addDraft.ts:38-60`).
- The banner shows only when a photo is present (`new.tsx:713`).
- `item_created` is logged with `{hasPhoto, suggestionAccepted: state ∈ {applied, refreshed}, hinted: state == refreshed}` (`new.tsx:538-542`).

### 11.2 SuggestionBanner states (`SuggestionBanner.tsx:5-19`, `:45-129`)

| State | Title | Message | Action | Live |
|---|---|---|---|---|
| `idle` | (hidden) | | | |
| `running` | | `strings.suggestions.running` | | yes |
| `refreshing` | | `strings.suggestions.refreshing` | | yes |
| `applied(confidence, forName)` | `strings.suggestions.applied` | `strings.suggestions.check` | | yes |
| `refreshed(forName)` | `strings.suggestions.refreshed(forName)` | `strings.suggestions.check` | | yes |
| `stale(forName)` (derived) | `strings.suggestions.stale(forName)` | `strings.suggestions.staleBody` | `strings.suggestions.update` (hint `strings.suggestions.updateHint`) | **off**, so it does not talk over typing |
| `failed(reason)` | `strings.suggestions.failed` | `strings.suggestions.failedBody[reason]` | `strings.suggestions.retry`, except when `reason == not_configured` | yes |

All are informational banners. The sparkle icon is used for AI states and the edit icon for failure. Native: an inline banner row, never a modal. Post VoiceOver announcements for the live states only, never for `stale`.

### 11.3 Quick Snap
The pipeline writes suggestions straight to the row (§5). There is no form and no confidence UI.

---

## 12. Naming an unnamed item inline (`src/ui/item/NameItInline.tsx`)
Shown on the item screen while the item has no name, or while the field is in use (focused or holding text), even after a name arrives (`app/item/[id]/index.tsx:159-164`).
- Props: `item {id, updatedAt}`, `incomingName` (the stored name, or `''`), `autoFocus` (filing run after the push transition), `onEngagedChange(Bool)`, `onNamed(String)` (`NameItInline.tsx:25-47`).
- `theirs = (meanwhile != nil && meanwhile.updatedAt > item.updatedAt) ? meanwhile.name : incomingName`. `offered = (theirs != "" && theirs != value.trim()) ? theirs : nil`. The notice is `meanwhile != nil ? strings.item.nameIt.namedMeanwhile(offered) : strings.item.nameIt.justNamed(offered)`, announced on change (`:95-106`).
- `engage`: reports `focused || text.trim() != ""`, but not after `finish` has run (`:109-111`).
- `save()` (`:129-170`):
  1. Empty name → error `strings.forms.itemNameRequired`.
  2. Single-flight guard.
  3. `lock = max(meanwhile?.updatedAt ?? 0, item.updatedAt)`, then `attemptName(items, {id, updatedAt: lock}, name)` (`src/ui/item/itemDetails.ts:181-210`).
  4. Outcomes:
     - `named` → log `item_updated`, `finish(name)`, invalidate.
     - `namedMeanwhile(name, updatedAt)` → warning haptic. Remember `meanwhile`. Keep the typed text and the keyboard.
     - `gone` → invalidate; the screen shows the gone state.
     - `failed` → log `item_name_failed {errorClass}`, error haptic, error `failedOffline` or `failed`.
- `attemptName`:
  1. `update(id, {name, expectedUpdatedAt})`. Nil means gone.
  2. On `ConflictError`, read the row again (`getById`). Nil → gone. If it now has a **different** non-empty name (`fresh.name && fresh.name != name`, untrimmed comparison against the trimmed typed name) → `namedMeanwhile(fresh.name, fresh.updatedAt)`, with nothing written. Otherwise update once more with `fresh.updatedAt`. That update returning nil → gone.
  3. Errors other than a conflict on the first update → `failed`, with no retry. **Any** error in step 2 → `failed`, including a second `ConflictError` and a failing re-read. There is at most one retry.
- `commit()` (used by "File it…") (`:175-185`): empty typed text → true. Typed text equal to `theirs` → `finish` and true. Otherwise `save()`.
- UI: heading `strings.item.nameIt.label` (header trait). The field has placeholder `strings.item.nameIt.placeholder`, accessibility label `strings.item.nameIt.a11y` (with the error appended when there is one), Return = Done, which submits without dismissing the keyboard. Buttons: **Save name** (`strings.item.nameIt.save`, secondary, loading while saving) and **Use “X”** (`strings.item.nameIt.useName(offered)`, which calls `finish` with no write).

Native: a `@FocusState` field with `.onSubmit`. Keep the component identity keyed by item id so a refetch never clears typed text.

---

## 13. Photo viewer (`app/item/[id]/photo.tsx`)
- Reads `items.getById(id)`. Picture URI = `photoUri ?? photoThumbUri` (`:71`, `:101`).
- States (`:108-168`):
  - Read error → `describeError(cause,'read','item')` title and body, with a retry icon button (`strings.common.tryAgain`).
  - Loading → spinner after 180 ms.
  - Item missing → `strings.errors.gone.item` / `strings.errors.gone.body`.
  - No URI, or the image failed to load → `strings.errors.photo.title` / `.body`.
  - Otherwise the image, aspect-fit, inside the safe area.
- Accessibility label: `strings.photo.a11y(name)`, or `strings.photo.a11yUnnamed` (`:106`).
- iOS: pinch zoom from 1× to 4×, centered content, bounce on zoom (`:146-167`).
- Swipe down to close (`:175-193`):
  - Starts only at zoom ≤ 1.01, with one touch, `dy > 10` and `dy > 1.5 × |dx|`.
  - The picture follows the drag downward.
  - On release, `dy > 80` closes; otherwise it settles back over 180 ms (instantly under Reduce Motion).
- Close button top-leading (`strings.photo.close`). Dark backdrop, light status bar (`:194-227`).
- Native: present with `.navigationTransition(.zoom(sourceID:in:))` from the item thumbnail, which gives interactive swipe-to-dismiss for free. Zoom with a `UIScrollView` wrapper or `MagnifyGesture` (1…4). Resolve the URI with §9.7.

## 14. Thumb (`src/ui/components/Thumb.tsx`)
- Sizes 40, 48, 56, 76 or 88 pt. Placeholder icon `photo` at 24 pt when size > 56, otherwise 20 (`:8-17`, `:33`).
- The image fills (cover) over the placeholder. A failed URI is remembered, so the placeholder stays, and a recycled row with a different URI tries again (`:28-29`, `:34-43`).
- Not pressable → hidden from accessibility (`:49-60`). Pressable → image-button role with the caller's label, and the hit area expanded to 44 pt (`:62-82`).
- Native: `AsyncImage` does not downsample. Use a small downsampling loader (ImageIO thumbnail at display size × scale) with an `NSCache`, fed by `PhotoPathResolver.resolve` (02 §3.3).

## 15. Replacing an item's photo
- **Not available in the UI** (`app/item/[id]/edit.tsx:291`). The Add sheet can retake or remove its photo before saving (§3 #6).
- Repository semantics if it is built later: `items.update(id, {photo: {...} | null, expectedUpdatedAt})` deletes **all** `item_photos` rows for the item (the tombstone trigger records synced ones) and inserts one new row with a fresh `newId()` and `created_at = now`. `photo: null` removes the photo (`items.ts:353-371`). The repository does **not** delete the old files; the caller must call `deleteStoredPhotos([oldUri, oldThumb])` after a successful write. Household mode would need a PATCH with photo support; check that area's API.

## 16. Permissions

### 16.1 Camera (`src/ui/components/CameraPermission.tsx`)

| AVAuthorizationStatus | Expo state | Screen | Source |
|---|---|---|---|
| (not yet read) | `permission == null` | black, spinner after 180 ms, close button styled for the camera | `CameraPermission.tsx:59`, `:74-81` |
| `.notDetermined` | `canAskAgain = true` | Rationale: title `strings.permissions.cameraRationaleTitle`; body `session ? strings.permissions.captureBodyPaired : strings.permissions.captureBodyLocal`; primary **Allow camera** (`strings.permissions.grant`) | `:83-93`, `:136-141` |
| `.denied` / `.restricted` | `canAskAgain = false` | Blocked: title `strings.permissions.cameraDeniedTitle`; body `strings.permissions.offBodyCapture`; primary **Open Settings** (`strings.permissions.openSettings`) | `:83-87`, `:131-135` |
| `.authorized` | granted | camera | `index.tsx:377` |

- Secondary actions (capture purpose): **Choose a photo instead** (`strings.permissions.choosePhotoInstead`), shown when `onLibrary` is set (always for capture). Quiet **Type it instead** (`strings.permissions.typeItInstead`), shown when `onManual` is set, which is never in request mode (`:152-170`).
- Close (`strings.camera.close`) is top-leading when `onCancel` is set (`:61-72`).
- Content scrolls so the alternatives stay reachable at the largest text sizes (`:103-116`).
- **Allow**: request access, then log `permission_result {permission:'camera', outcome:'granted' | 'denied'}` (`:95-101`). The screen owns the permission, so a grant swaps straight to the camera (`:21-26`).
- iOS mapping: expo maps `.denied` and `.restricted` to `denied` and `.notDetermined` to `undetermined`; `canAskAgain = status != denied` (`node_modules/expo-camera/ios/Common/CameraPermissionsRequester.swift:32-50`).
- Native:
  - `AVCaptureDevice.authorizationStatus(for: .video)` is synchronous, so the `null` loading state is an RN artifact. Keep only a black background during the transition.
  - Request with `await AVCaptureDevice.requestAccess(for: .video)`.
  - Open Settings with `UIApplication.openSettingsURLString`.
  - Re-read on `scenePhase == .active`. iOS also terminates the app when a privacy permission is revoked.
- The Scan purpose (`strings.permissions.scanBody`, `offBodyScan`, `typeCodeInstead`) belongs to the Scan area and shares this screen.

### 16.2 Photo library
PHPicker needs no permission (§4.8). Keep `NSPhotoLibraryUsageDescription` in the Info.plist (`app.json:17`), because removing an existing key is harmless but unnecessary churn.

### 16.3 Info.plist strings (keep verbatim)
The source of truth is `app.json`. `ios/` is generated by prebuild and git-ignored (`.gitignore:51`), so `ios/Inventory/Info.plist` is only the local generated copy. `app.json` also sets `supportsTablet: true`. The App Store update replaces an app that already supports iPad, so the native target has to keep iPad, and therefore has to handle the camera in iPad orientations (C4, Q16). This is the app-shell area's concern.
- `NSCameraUsageDescription`: "Inventory uses the camera so you can photograph items you are adding and scan QR labels on your containers." (`app.json:16`)
- `NSPhotoLibraryUsageDescription`: "Inventory can import a photo from your library to illustrate an item you are adding." (`app.json:17`)
- No microphone key (`app.json` expo-camera plugin `microphonePermission: false`). No photo-library-add key: photos are never saved to the camera roll, which the rationale copy promises.

## 17. Telemetry
Events pass through an allowlist redactor. Keys not on the list are **dropped** (`src/services/telemetry/index.ts:29-67`). Allowed keys: `durationMs latencyMs outcome errorClass contractVersion statusCode itemCount containerCount spaceCount resultCount termCount queryLength confidence source permission screen step schemaVersion byteSize attempt hasPhoto suggestionAccepted hinted`. No sink is wired; events print to the console in development only (`:69-91`).

| Event | Payload as sent → after redaction | Source |
|---|---|---|
| `photo_stored` | `{durationMs, byteSize}` | `imageStore.ts:121-124` |
| `photo_store_failed` (error) | `{durationMs, errorClass}` | `imageStore.ts:128-131` |
| `photo_captured` | single: `{source, byteSize}`; fast: `{source, mode}` → `{source}` | `index.tsx:182`, `:285` |
| `photo_capture_failed` (error) | `{source}` | `index.tsx:212` |
| `recognition_unusable` | `{reason}` → `{}` | `index.tsx:289` |
| `fast_capture_failed` (error) | `{source}` | `index.tsx:295` |
| `fast_review_done` | `{kept, unnamed}` → `{}` | `review.tsx:187` |
| `item_deleted` / `item_delete_failed` (error) | `{}` / `{errorClass}` | `review.tsx:159`, `:166` |
| `permission_result` | `{permission, outcome}` | `CameraPermission.tsx:97-100` |
| `recognition_skipped` / `recognition_failed` / `recognition_completed` | see §10.6 | `recognition.ts` |
| `item_created` | `{hasPhoto, suggestionAccepted, hinted}` | `new.tsx:538-542` |
| `item_updated`, `item_name_failed` (error) | `{}`, `{errorClass}` | `NameItInline.tsx:148`, `:163` |

Native: a `Telemetry` facade over `os.Logger` with the same allowlist (Sendable enum keys).

## 18. RN/Expo workarounds that native does not need

| RN mechanism | Why it exists | Native replacement |
|---|---|---|
| `TapToFocusLayer` overlay plus a patched `focus(x, y)` module method | RN views on top block native taps on the camera view (`TapToFocusLayer.tsx:14-22`) | A tap gesture on the preview view; call the camera actor directly |
| The `expo-camera` patch (device order, zoom baseline, ZSL off, smooth AF, quality) | Cannot configure AVFoundation from JS | Configure `AVCaptureDevice` / `AVCapturePhotoOutput` directly (§8.3) |
| expo-camera's crop and JPEG q=1.0 temp file in `Caches/Camera` | Generic library output | Use the `AVCapturePhoto` HEIC data in memory; crop only if D2 says so |
| ImageManipulator temp file then `move` into Documents (`imageStore.ts:70-87`) | `saveAsync` always writes to Caches | Atomic write to the destination |
| `routeResult` request ids (`src/ui/routeResult.ts`) | Values cannot travel through expo-router params | Closure or `CheckedContinuation` passed to the cover |
| Photo metadata in URL params (`photoUri`, `photoWidth` and so on; `index.tsx:201-210`, `addSheet.ts:36-52`) | Router params are strings | Pass a `StoredImage` struct |
| `useInventoryQuery` plus a manual `invalidate()` once a whole pipeline resolves (not after each step; §6.1) | No reactive DB in RN | **Not a workaround to remove:** keep the app-wide `InventoryQuery` + revision model (09 §5), which also serves paired HTTP reads. GRDB `ValueObservation` only if Q14 (D6) chooses live rows, local mode only |
| `closedRef`, `takingRef`, `pickingRef`, `shutterBusy` refs | React state is stale inside async closures | Plain properties on a `@MainActor @Observable` model (the guards are still needed) |
| Pipelines surviving unmount with no-op `setState` | React lifecycle | App-scoped `CaptureCoordinator` owning the tasks |
| `useCameraPermissions()` null loading state and `useDelayedFlag` spinner | Async permission read over the bridge | Synchronous `authorizationStatus` |
| `isPermissionError` regex on picker errors | Android picker permission | Not applicable with PHPicker |
| `/network\|fetch failed\|…/` message regex | whatwg-fetch only exposes messages | `URLError.Code` |
| `AbortController` plus `setTimeout` | fetch has no total timeout | Task-group race with `Task.sleep` |
| `BackHandler`, `android_ripple`, `fadeDuration`, `usesRipple` | Android | Drop |
| `AccessibilityInfo.announceForAccessibility` on iOS only (`CameraChrome.tsx:146-149`, `NameItInline.tsx:50-52`) | VoiceOver ignores polite live regions | `AccessibilityNotification.Announcement` |
| iOS-only `ScrollView` zoom plus responder swipe-down (`photo.tsx:146-193`) | No gesture library in the app | Zoom navigation transition plus `MagnifyGesture` |
| Lazy `import('expo-file-system')` (`recognition.ts:33-38`) | Keeps native modules out of Node tests | Inject a `readImage` closure for tests |
| SDWebImage WebP coder | Bundled by expo-image-manipulator | libwebp through SPM (C3) |

## 19. Tests to port (Swift Testing)

`src/services/ai/__tests__/recognition.test.ts`
- **parseRecognitionResponse**
  - "accepts and normalizes a well-formed suggestion": success; name `Cordless Drill`; tags `[dewalt, 18v]`.
  - "rejects %s as malformed", parameterized over: null body; string body; missing contractVersion; missing suggestion; non-numeric confidence (`'high'`); confidence 4. Each → `malformed_response`.
  - "rejects a contract version it does not understand": 999 → `unsupported_version`.
  - "treats an explicit unrecognized outcome as recoverable" → `unrecognized`.
  - "rejects a suggestion with no usable name": `'   '` → `unrecognized`.
  - "discards suggestions below the confidence floor": 0.34 → `low_confidence`.
  - "drops junk values…": `category: 42` → nil; tags `['ok', 17, null, '  ', 'fine']` → `['ok', 'fine']`.
  - "caps the number of tags": 40 tags → 8.
- **recognizeItem** (injected fetch, readImage and 50 ms timeout)
  - Success.
  - "never sends a provider credential": header names exclude `authorization` and `x-api-key`.
  - AbortError → `timeout`.
  - `Error('Network request failed')` → `offline`.
  - 429 → `rate_limited`; 500 → `server_error`.
  - JSON parse throws → `malformed_response`.
  - No hint → body has no `nameHint` key.
  - Hint `'  Angle grinder  '` → `nameHint == 'Angle grinder'`.
  - Blank hint → key absent.
  - Endpoint nil → `not_configured` and fetch is never called.
- **telemetry redaction**
  - Keeps only allowlisted keys (drops `itemName`, `notes`, `photoUri`, `qrToken`).
  - Drops non-primitive values under an allowed key.

`src/services/capture/__tests__/fastCapture.test.ts`
- Persists the item before recognition (order create → recognize).
- Stores the photo and attaches `{uri, width, height, byteSize}` to the created draft.
- Success → outcome `recognized(item-1, 'Cordless drill')` and one update `{name, category, tags}`.
- Failed (offline) → `unrecognized(offline)`, no update, and the draft has no `name` key.
- Parameterized `not_configured | timeout | rate_limited | low_confidence` → `unrecognized` with the item id.
- A recognizer that throws → `unrecognized`, no update.
- Blank suggested name → update `{category, tags}` only, outcome `unrecognized`.
- A store failure propagates (rejects `'No space left'`).

`src/services/capture/__tests__/fastReview.test.ts`
- `sessionItems` keeps `createdAt >= since`, oldest first, and includes `createdAt == since`.
- `summarizeSession` splits named and unnamed (whitespace counts as unnamed): `{3, 1, 2, 0}`.
- Pending equals `expected − saved`.
- Pending is never negative.

`src/services/capture/__tests__/imageScaling.test.ts`
- Portrait 3024×4032 → 1050×1400. Landscape → 1400×1050. Aspect ratio preserved.
- Fits → nil (800×600, 1400×1400).
- Never enlarges (320×240, 240×320, 1399×20, 1×1).
- Very thin 20000×3 → width 1400, height ≥ 1.
- Megapixels: the old width bound gave about 3.41 MP, the new one about 1.47 MP (< half).
- Thumbnail long edge is 320, `THUMBNAIL_DIMENSION >= 192`, and it is under 1/15 of the full image's pixels.

`src/ui/capture/__tests__/captureFlow.test.ts`
- **fastStatus**
  - `(3,1,1)` → "Identifying 2…", not settled.
  - `(3,3,3)` → "3 identified". `(3,3,1)` → "1 identified · 2 to name". `(2,2,0)` → "2 saved · name them later". `(1,1,0)` → "1 saved · name it later".
  - No "✓" in the text; settled is true.
- **leaveCamera**: `fast, 2` → review; `fast, 0`, `single, 0` and `single, 3` → back.
- **intoA11y**
  - Named container → "Photos go into Tool chest, in Garage, label C A B, J 9 2 R".
  - Unnamed container → the space form.
  - Drop zone or nil place → `intoDropZoneA11y`.
- **isPermissionError**: code `ERR_NO_PERMISSIONS` or a message containing "permission" → true; others, non-Error values and nil → false. iOS-irrelevant, port only if kept.
- **reviewStatus / reviewStatusText**
  - pending → "Saving 2 more…".
  - Stalled → maybeLost text.
  - toName → "2 still need a name" / "1 still needs a name"; allNamed → "All named". `reviewStatus(two, stalled: true)` is still `toName`: `stalled` is ignored when `pending == 0`.
  - Works on `summarizeSession` output.
- **Review title and toast**
  - `containerLabel` returns the name, then the code, then nil.
  - Title "4 saved to the drop zone" / "1 saved to Tool chest".
  - "Saving 2 photos…" / "Saving 1 photo…" with `savingFirst` text before the first row lands. "1 saved to the drop zone" once one has.
  - Container with a nil label → nil title and nil toast.
  - Toasts: "4 items are in the drop zone." with View; "1 item is in the drop zone."; "2 items added to Tool chest." without View; saved 0 → nil.
- **sessionSignature**: stable on re-read; changes when a row is named or added.
- **Hidden rows**: hide a and c → `[b]`. A fresh list ignores old hiding, and `hideRow` on a new source starts fresh. Nil → same list instance.
- **Landed**
  - `withLanded` accumulates and returns the identical set when nothing is new.
  - `expectedStillShown(4,4,3) == 3` with pending 0.
  - `(4,3,2) == 3` with pending 1.
  - `(0,2,0) == 0`.

Other test files:
- `src/ui/__tests__/routeResult.test.ts`: the semantics the native request-mode continuation must keep.
  - The opener gets a non-empty request id and resolves with the delivered value.
  - The value is delivered once: a second `deliverResult` returns false.
  - Abandoning resolves `undefined`, abandoning is idempotent, and a delivery after an abandon returns false. That false is what makes the camera fall through to `/item/new` (§4.4 step 7).
  - Concurrent requests stay apart.
  - A missing or unknown id → false, and abandoning `null` does not throw.
- `src/services/sync/__tests__/photoSync.test.ts` (sync area; listed because of C1): "drops a row whose local file has vanished rather than retrying forever", "pulls back files that a restore left behind, re-pointing the row", "leaves photos alone when the local file is present". Native ports of these must run against `PhotoLocation.resolve`.
- `src/db/__tests__/persistence.test.ts` (DB area): "creates an item with photo and tags atomically", "files an unnamed capture without demanding a name first", "still rejects an explicitly blank name on update". These are the repository guarantees Quick Snap relies on.
- `src/ui/components/__tests__/TapToFocusLayer.test.tsx`: `focusSpotOffset(100, 40) == (100−36, 40−36)`.
- `src/ui/components/__tests__/SuggestionBanner.test.tsx` (`staleSuggestionName`): nil when the title matches (trimmed); returns the typed title when it diverges; goes stale again after `refreshed`; nil for an empty or blank title; nil for idle, running, refreshing and failed.
- `src/ui/components/__tests__/ItemForm.test.tsx` (`applySuggestion`):
  - Fills an untouched form (tags `"dewalt, 18v"`).
  - Never takes back typed fields (but fills blank tags).
  - Overwrite replaces category and tags.
  - Overwrite keeps the corrected name.
  - Overwrite leaves quantity and notes.
  - Overwrite clears category and tags when the suggestion has none.
  - The `validateItemForm` tests in the same file belong to the forms area.
- `src/ui/add/__tests__/addSheet.test.ts`:
  - `toPositiveInt` (`'1400'` → 1400; `''`, `'0'`, `'-3'`, `'2.5'` and `'wide'` → nil).
  - `photoFromParams` (byte size `'x'` → nil).
  - `photoFromStored` drops a nil byte size.
  - `photoFiles` (`[]`, `[a,b]`, `[a,nil]`).
  - `initialAddState`: recognizes a camera photo on arrival (`running`, `recognize=true`); restarts recognition that was cut off and drops it without a photo; keeps an applied suggestion as it was.
  - Other tests in the file belong to the Add area.
- `src/ui/add/__tests__/addDraft.test.ts`: restore within 30 min, not after; a stale draft deletes both photo files; a replaced draft deletes its photo unless the new draft carries the same one; only the owner clears it, and clearing never deletes the photo.
- `src/ui/item/__tests__/itemDetails.test.ts` (`attemptName`):
  - Uses the lock it had.
  - Nil → gone.
  - Recognition naming it between load and save → `namedMeanwhile`; saving again over the returned stamp stores the typed name.
  - Meeting the same name → named.
  - Retries once on another change.
  - Non-conflict errors fail without retry.
- `server/test/contract.test.ts` (server stays in TypeScript; use these as **shared fixtures** for the Swift client tests):
  - Accepts a well-formed request (default mediaType `image/jpeg`).
  - Version 99 → 400.
  - Non-objects rejected.
  - Missing or `hex` encoding rejected.
  - Empty data rejected.
  - 20 MiB of base64 → 413.
  - `image/PNG` → `image/png`; `application/pdf` → `image/jpeg`.
  - No hint → nil.
  - Hint whitespace collapsed (newlines too) and cut to 80.
  - Junk hints (`''`, `'   '`, `'\n'`, 42, null, object) → absent and still ok.
  - `userPrompt()` equals `USER_PROMPT`; a hinted prompt contains the hint.
  - The hint overrides the model's name; the hint stands in for a missing name.
  - Adapter error → 429, 504 or 502.
  - Normalization: trim; blank category → nil; tags lowercased, deduped, over-long ones dropped; confidence clamped to 1.
  - Registry caches and rejects unknown ids; duplicate registration throws.
  - Auth is open without a secret; with a secret, a missing, wrong or short key → 401 and the right key → ok.

New tests to add natively (no RN equivalent):
- `PhotoPathResolver.resolve` rebasing (stale container UUID, Caches `household-photos` path, Android `…/files/item-photos/…` path, `r2:` URI → nil); the full list is 02 §11.2 test 6.
- The uploader keeps an unsynced row whose stored path names a stale container UUID but whose file exists under the current container (C1 hazard).
- `parseRecognitionResponse` rejects `contractVersion: true` and `confidence: true` as `malformed_response`, and accepts `contractVersion: 1.0`.
- The capture shutter is disabled until the session is running, so there is no `noPhoto` from an early press.
- Media-type sniffing (D1).
- Request JSON has no escaped slashes and no `nameHint` key when blank.
- `URLError` → reason mapping.
- Deadline covers the file read.
- `scaleToFit` rounding parity on `.5` cases.
- WebP round-trip dimensions equal the recorded width and height.
- Stored files carry no EXIF or GPS.

## 20. Open questions
- **Q1 (D1):** send the true `mediaType` (`image/webp`) instead of `image/jpeg`? Recommended. Contract-compatible.
- **Q2 (D2):** keep expo-camera's crop-to-preview (WYSIWYG, tall photos about 646×1400), or store uncropped 4:3 stills (1050×1400) like Camera.app?
- **Q3 (D5):** for "focus like the system camera", the literal patch (continuous AF at the point) or the AVCam style (one-shot AF at the point plus a subject-area-change reset)? Recommended: AVCam style.
- **Q4 (C7):** should Keep shooting carry a cumulative `expected` so the second review counts in-flight shots, or replicate the current reset?
- **Q5 (D4):** keep zero shutter lag disabled (quality, as patched), or enable responsive and fast-capture prioritization for Quick Snap bursts?
- **Q6 (D3):** count a recognition-update conflict as `unrecognized` instead of "could not be saved"?
- **Q7:** bound Quick Snap concurrency (serial image processing, at most N recognitions in flight)? RN is unbounded.
- **Q8:** add pinch zoom, volume-button or Camera Control shutter (system-camera parity)? The current app has none.
- **Q9:** implement "replace photo" on Edit details now, or keep it out of scope (C6)?
- **Q10 (C1):** rebase stale photo paths lazily at read time only, or also run a one-time row rewrite on first native launch? Same question as `02-device-storage-migration.md` Q4 (tracked there and in `00-index.md`); read-time resolution is mandatory either way.
- **Q11:** the recognition key for production builds is not in `eas.json`. Confirm where the native build gets it (xcconfig secret in CI).
- **Q12 (C8):** filter household-mode session rows by the server clock (for example `since` taken from the first created row) to avoid clock-skew misses?
- **Q13:** the review keeps the iOS swipe-back gesture today (§3), and swiping leaves without `fast_review_done` or the Done toast. Should native disable the swipe (SwiftUI's default once the back button is hidden), or treat a swipe as Done?
- **Q14 (D6):** the default port (revision model) shows review rows only when their pipeline finishes, exactly like RN (§6.1). Should native instead show rows at insert time (unnamed, then named in place) via local-mode observation? Parity is the default.
- **Q15:** purge the leftover `Caches/Camera`, `Caches/ImageManipulator` and `Caches/ImagePicker` files on first native launch (recommended), and also sweep unreferenced files in `Documents/item-photos/` (needs household and sync sign-off, §9.9)?
- **Q16:** on iPad, the RN crop swaps the preview size only for a `.portrait` UI (C4). Should native lock the capture screen to portrait on iPad too, or compute the crop from the actual capture rotation?
- **Q17 (C2):** confirm against production whether recognition currently fails for every photo because of the `image/jpeg` label on WebP bytes. If it does, D1 is a bug fix rather than an option, and the RN app needs the same one-line fix.

## 21. Dependencies on other areas
- **Database / repositories:** `items.create`, `items.update` (optimistic lock, `ConflictError`), `items.delete` (`orphanedPhotoUris`), `listByContainer`, `listUnsorted`, `getById`, the `ITEM_CONTEXT_SELECT` projection, the `item_photos` schema and tombstone trigger. Must be preserved byte-for-byte (`src/repositories/items.ts`, `src/db/migrations.ts`).
- **Photo sync / backup:** `readStoredPhoto`, `writeStoredPhoto` and `deleteStoredPhotos` are consumed by `src/services/sync/photoSync.ts`. It must use `PhotoPathResolver.resolve` (C1; 02 §3.3), and it must do so from its **first** native pass, because otherwise the upload pass deletes unsynced photo rows (`photoSync.ts:62-70`). Uploads use the Worker content types jpeg, webp and png (C3).
- **Other `deleteStoredPhotos` callers** (container, space and item delete flows: `app/container/[id]/edit.tsx`, `app/space/[id]/edit.tsx`, `app/item/[id]/index.tsx`) must resolve the stored URIs too. Otherwise files under a stale path are silently kept.
- **Shared infrastructure for counters and review:** `invalidate()` / revision semantics (`src/providers/DatabaseProvider.tsx`) are **kept** app-wide as `InventoryQuery` + `DatabaseModel.revision` (`09-app-shell-lifecycle-config.md` §5, `01-data.md` §9.1); they are not replaced by GRDB observation. D6/Q14 only decides whether the review screen additionally observes inserts in local mode.
- **Household:** in paired mode `items.create` uploads the photo (`PUT /v1/photos/<id>`) and caches it under `Caches/household-photos/<photoId>[-thumb].webp`. Display URIs may be `r2:…` until hydrated (`src/services/household/httpRepositories.ts:59-117`, `photoCache.ts`). Delete-confirm copy depends on whether a household session exists.
- **Add item sheet:** owns `app/item/new.tsx`, the draft (`addDraft.ts`) and its place logic. This area supplies the camera request, `StoredImage`, recognition and `applySuggestion`.
- **Item screen / filing run / drop zone tab:** host `NameItInline`, the `filing=1` run, the Drop zone list and its Quick Snap buttons, the Home drop-zone card, and the tab-bar long-press.
- **Scan tab:** shares `CameraPermission` (scan purpose) and the patched expo-camera (device choice and focus also affect QR scanning). A native scanner should use `DataScannerViewController` or AVFoundation metadata output separately.
- **Telemetry, haptics, toasts, confirm dialogs, error description (`describeError`):** shared infrastructure.
- **Config:** the `AppConfig` provider (recognition URL, key, timeout).
- **Privacy screen:** shows `MAX_IMAGE_DIMENSION` (`app/privacy.tsx:75`) and whether recognition is configured (`app/privacy.tsx:80`).

## Reviewer notes
An adversarial review re-read every source file in scope independently: the TypeScript, the patched `node_modules/expo-camera/ios/**`, `expo-image-manipulator` and `expo-image-picker` iOS sources, the server, and every related test. Most citations and constants checked out. The changes below were made in place.

**Corrections**
- §4.4 / §4.6 guard: "camera ready" actually means only that the camera view is mounted (`cameraRef.current`). The app never waits for `onCameraReady`, so an early press throws `CameraOutputNotReadyException` and shows `noPhoto`. `takeFastPhoto` has no `closedRef` guard.
- §4.2 `into`: it is also null when the container's space is missing (`index.tsx:131-132`).
- §6.1 refresh model: the review does **not** re-read after every write. Repository writes never bump the revision; only explicit `invalidate()` does, and the fast pipeline calls it only when the pipeline resolves. Rows therefore appear once recognition is done, and a rejected pipeline triggers no refresh. The native ValueObservation recommendation is now flagged as a visible behavior change (D6 / Q14). The §18 row is fixed to match.
- §6.2 `containerLabel`: it is `containerName ?? containerShortCode` over `loaded` (before hiding); only NULL falls back.
- §6.3: the signature is computed over `loaded`, not `list`. The refresh banner is suppressed for offline and revoked failures. The §6 intro no longer claims "re-runs on every write".
- §9.3 `hasRoomForPhoto`: the native suggestion is now labelled as two deviations (purgeable space; nil treated as room). The behavior-identical alternative is spelled out.
- §9.4 insert: the photo id is `draft.photo.id ?? newId()`, not always `newId()`. Added the `idx_item_photos_item` index and the exact column defaults of a Quick Snap row.
- §10.3: the mediaType regex is case-insensitive. The invalid-base64 400 is unreachable.
- §12 `attemptName`: a second conflict, or any error after the first conflict, → `failed`; a nil second update → gone.
- §8.1: zoom citation `:244-262` → `:244-260`. The capture-orientation row now gives the full mapping (flat/unknown → portrait) and notes that `ios/` is generated and git-ignored.
- C2: strengthened from "if the provider checks" to "Anthropic is known to reject a media-type mismatch; likely a live production bug", with the stale server comment cited (Q17).

**Additions**
- C1: the photo uploader **deletes** `item_photos` rows whose file is unreadable (`photoSync.ts:62-70`). Without the resolver at the first native sync pass, the in-place upgrade would lose every not-yet-uploaded photo. Also added to §21, with the other `deleteStoredPhotos` callers.
- C4: landscape shots (about 1400×646), the flat-phone behavior, and the iPad crop quirk (Q16). §16.3: iPad support must be kept on an in-place update.
- §4.10: the exact `fastStatus` decision rule and the `intoA11y` / `spellCode` rule (both were only implied through tests). Last-shot tile memory note.
- §4.6: counter edge cases (`captured` back to 0 unlocks the set; a late shot after Done lands uncounted in the review).
- §4.8: the permission-screen library import has no busy UI.
- §3: the review keeps the iOS swipe-back gesture, which skips `fast_review_done` and the toast (Q13).
- §5: a vanished row makes `update` return nil, and the pipeline still reports `recognized`; a missing `updatedAt` means an unlocked update.
- §6.1: session membership includes any row created in the container after `since`; tie-order note.
- §6.5: the review row's IA (title fallback, detail line, delete labels).
- §8.3: simulator note.
- §9.2: lowercase UUID in Swift.
- §9.3: `writeStoredPhoto` error and no-resize behavior.
- §9.9 (new): leftover Expo cache directories to purge on first native launch, and why an orphan sweep of `Documents/item-photos/` needs sign-off (household captures and lost drafts) (Q15).
- §10.1: the recognition URL exists only in the production profile; local `.env.local` uses `:3000`.
- §10.4: the `JSONSerialization` boolean-as-NSNumber pitfall.
- §10.5: the `URLError.timedOut` deviation and NaN timeout parsing.
- §19: added `routeResult.test.ts`, plus the cross-area `photoSync.test.ts` and `persistence.test.ts` cases. Noted that `reviewStatus` ignores `stalled` when nothing is pending. New native tests for the C1 hazard, boolean rejection and the shutter-before-ready guard.
- §20: Q13–Q17.

**Completeness / consistency pass (cross-spec critic)**
- C1 / §9.7 / §14 / §19 / §21: replaced the separate `PhotoLocation.resolve` (rebase the suffix after the last `/Documents/` or `/Library/Caches/`) with the shared `PhotoPathResolver` from `02-device-storage-migration.md` §3.3 (rebase by file name under the parent folder `item-photos` or `household-photos`). The old rule missed Android-restored rows (`…/files/item-photos/…`), which then would never display even after rehydration wrote the file. Two different resolvers in one app was itself a defect.
- §6.1 / §18 / §21 / Q14: the previous text recommended GRDB `ValueObservation` for the review and said the revision model is "replaced by GRDB observation app-wide". That contradicted 01 §1 (decision 6), 07 §0.3 and 09 §5, which keep the revision model because paired reads are HTTP. The default is now the shared `InventoryQuery` (exact RN timing); observation is an optional local-only change behind Q14.
- Q10 now points at 02 Q4 (one decision for row rewriting).
- Coverage check: `CameraChrome.tsx`, `TapToFocusLayer.tsx`, `captureFlow.ts`, `fastReview.ts`, `fastCapture.ts`, `imageScaling.ts`, `imageStore.ts`, `recognition.ts`, `contract.ts`, `Thumb.tsx`, `NameItInline.tsx`, `CameraPermission.tsx`, `app/capture/*` and `app/item/[id]/photo.tsx` are all specified here; every exported symbol is referenced.
