# Share Sheet — Implementation Plan

Implementation plan for the iOS share extension (a.k.a. the "quick-save sheet") of the link-saver app. Derived from `idea.md` (product concept) and `quick_save_spec.html` (UX/state spec). This document is the bridge between those two and the actual code.

## Overview

Two surfaces, one user moment:

1. **System share sheet** — the iOS-native sheet that appears when the user taps "Share" inside Instagram, Safari, etc. We don't render this; iOS does. Our work is making our icon appear in it, correctly, for the right content types.
2. **App-specific quick-save sheet** — our custom SwiftUI sheet that iOS presents *after* the user taps our icon in the system sheet. We fully own this UI.

The user perceives both as one fluid interaction. From tap to dismiss: target **≤ 1.5s**.

---

## §G — Goals

- G.1 Our icon appears in iOS share sheet for any app that shares a URL or plain text containing a URL
- G.2 Quick-save sheet renders custom SwiftUI UI within 120ms of extension launch
- G.3 POST `/v1/links` fires in parallel with sheet render — sheet never blocks on network
- G.4 Save is always durable: offline → App Group queue → drained by main app on next launch
- G.5 Sheet survives all 6 states defined in `quick_save_spec.html` §02 (loading, ready, note-expanded, partial, duplicate, offline)
- G.6 Extension obeys iOS limits — ≤ 120MB memory, ≤ 30s execution, no background work after `completeRequest`
- G.7 Main app does NOT need to be running for the extension to function (only for initial token mint + queue drain)
- G.8 Zero error dialogs — every failure degrades to an inline banner or queued retry

---

## §X — Xcode project layout

Single workspace, three targets, one shared framework module.

```
LinkSaver.xcodeproj
├── LinkSaver/                     [Target: main app]
│   ├── LinkSaverApp.swift
│   ├── Onboarding/
│   │   ├── WelcomeView.swift
│   │   ├── SignInView.swift
│   │   └── InstallExtensionView.swift
│   ├── Inbox/
│   ├── LinkDetail/
│   ├── Settings/
│   │   └── DevicesView.swift      [revoke ingest tokens]
│   └── Info.plist
│
├── ShareExtension/                [Target: app extension, NSExtensionPointIdentifier=com.apple.share-services]
│   ├── ShareViewController.swift  [UIViewController, principal class]
│   ├── ShareViewModel.swift       [@MainActor, ObservableObject]
│   ├── QuickSaveSheet.swift       [SwiftUI root view]
│   ├── Components/
│   │   ├── LinkCard.swift
│   │   ├── CategoryChipRow.swift
│   │   ├── NoteField.swift
│   │   ├── ReminderToggle.swift
│   │   └── SheetActions.swift
│   └── Info.plist                 [NSExtensionPrincipalClass = ShareViewController, NSExtensionActivationRule]
│
└── Shared/                        [Embedded framework, linked by both targets]
    ├── APIClient.swift
    ├── KeychainStore.swift        [App Group access group]
    ├── OfflineQueue.swift         [App Group UserDefaults]
    ├── Models/
    │   ├── IngestRequest.swift
    │   ├── IngestResponse.swift
    │   ├── Category.swift
    │   └── QueuedSave.swift
    └── Constants.swift            [App Group ID, API base URL]
```

### App Group + entitlements

- **App Group ID:** `group.com.yourapp.shared`
- Both `LinkSaver` and `ShareExtension` targets entitled to this group
- Keychain access group: `$(AppIdentifierPrefix)com.yourapp.shared` on both targets
- Network entitlement on ShareExtension (default for extensions)

---

## §I — Info.plist configuration

### ShareExtension/Info.plist

```xml
<key>NSExtension</key>
<dict>
    <key>NSExtensionAttributes</key>
    <dict>
        <key>NSExtensionActivationRule</key>
        <dict>
            <key>NSExtensionActivationSupportsWebURLWithMaxCount</key>
            <integer>1</integer>
            <key>NSExtensionActivationSupportsText</key>
            <true/>
        </dict>
    </dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.share-services</string>
    <key>NSExtensionPrincipalClass</key>
    <string>$(PRODUCT_MODULE_NAME).ShareViewController</string>
</dict>
```

**Why these activation rules:**
- `SupportsWebURLWithMaxCount = 1` — we activate for any share containing a URL, single-link only (multi-link explicitly cut in §09 of the spec)
- `SupportsText = true` — fallback for apps that share a URL as plain text rather than a typed URL attachment

Notably **not** declaring image/file support. v1 is URLs only.

### LinkSaver/Info.plist

Standard app config plus:
- `LSApplicationQueriesSchemes` for deep links back into source apps (Instagram, YouTube, etc.)
- `UIBackgroundModes` includes `fetch` for `BGAppRefreshTask` (queue drain)

---

## §C — Code modules

### ShareViewController.swift

Entry point. Inherits `UIViewController`, not `SLComposeServiceViewController` — full UI control.

Responsibilities:
1. Read `NSExtensionItem` from `extensionContext`, extract URL via `NSItemProvider` (try `public.url`, fall back to `public.plain-text` regex)
2. Read ingest token from Keychain (App Group)
3. If no URL → dismiss with `invalidURL` reason
4. If no token → mount `NotLinkedView` (deep links to main app)
5. Otherwise mount `QuickSaveSheet` via `UIHostingController`, set `preferredContentSize` to ~440pt height
6. Call `viewModel.beginSave()` to fire POST immediately (parallel to UI mount)

### ShareViewModel.swift

`@MainActor final class ShareViewModel: ObservableObject` — single source of truth for sheet state.

State machine (matches `quick_save_spec.html` §03):

```swift
enum SheetState {
    case idle
    case fetching
    case ready(LinkResponse)
    case partial(LinkResponse)
    case duplicate(LinkResponse)
    case offline(URL)
    case authExpired
    case saved
}
```

Published properties: `state`, `selectedCategoryId`, `noteText`, `reminderDate`.

Methods:
- `beginSave()` — async POST `/v1/links`, transitions state from idle → fetching → ready/partial/duplicate/offline/authExpired
- `commitSave()` — called when user taps Save. If state has a server `id`, fire-and-forget PATCH for any edits; otherwise enqueue offline. Always calls `completeRequest`.
- `cancel()` — calls `completeRequest`. Does NOT issue DELETE — see §07 of spec, Cancel never destroys data once POST is out.

### QuickSaveSheet.swift

SwiftUI root view. Renders different subviews based on `viewModel.state`. Layout is **identical across states** — only content differs — so nothing jumps when state changes.

Structure:
```
VStack {
    SheetHandle()
    SheetTitle("Save to Inbox")
    LinkCard(state)              // skeleton or full
    CategoryChipRow(...)
    if state == .duplicate { ReasonLine("already in your inbox") }
    if state == .ready { ReasonLine("✦ auto-categorised · 92%") }
    NoteField(...)               // collapsed by default
    ReminderToggle(...)          // collapsed by default
    SheetActions(...)
}
```

### APIClient.swift (Shared)

Single client, used by both extension and main app.

```swift
final class APIClient {
    static let shared = APIClient()
    let baseURL: URL
    let session: URLSession    // .ephemeral config — not .shared

    func ingest(_ req: IngestRequest, token: String) async throws -> IngestResponse
    func patchLink(id: String, edits: LinkEdits, token: String) async throws
    func mintIngestToken(authJWT: String) async throws -> String
    func revokeIngestToken(id: String, authJWT: String) async throws
}
```

**Critical:** use `URLSession(configuration: .ephemeral)`, never `URLSession.shared` in the extension context. `.shared` behaves unpredictably across extension launches.

Timeouts: 8s hard ceiling on ingest. After 8s, throw `timeout` → ViewModel enters `.partial` if server already responded with 202, or `.offline` and enqueues if no response yet.

### KeychainStore.swift (Shared)

Wrapper over `kSecClassGenericPassword` with `kSecAttrAccessGroup = $(AppIdentifierPrefix)com.yourapp.shared`. Only stores the ingest token. Main app writes once on first login; extension reads on every launch.

API: `ingestToken() -> String?`, `setIngestToken(_:)`, `clearIngestToken()`.

### OfflineQueue.swift (Shared)

`UserDefaults(suiteName: "group.com.yourapp.shared")` backed. Stores `[QueuedSave]` under `offline_queue_v1`.

API:
- `enqueue(_ save: QueuedSave)` — extension calls this on offline / 5xx / timeout
- `peek() -> [QueuedSave]` — main app reads on launch
- `drain(api:token:) async` — main app calls. Iterates, posts each. On success removes; on failure keeps. Idempotency key in QueuedSave means re-drains are safe.

Drain triggers (main app only):
- `application(_:didFinishLaunching:)`
- `BGAppRefreshTask` registered for ~6h interval
- `NWPathMonitor` reachability change from unsatisfied → satisfied

---

## §S — State wiring

| State | Set by | UI changes | Allowed user actions |
|---|---|---|---|
| `idle` | viewDidLoad before `beginSave` | Skeleton card, chips disabled, button reads "Saving…" | Cancel |
| `fetching` | `beginSave` start | Same skeleton, chips disabled | Cancel, Save (commits URL only) |
| `ready` | 201 response | Full card, AI chip pre-selected with ✦, reason line shows confidence | Save, Cancel, change chip, expand note, toggle reminder |
| `partial` | 202 response | URL-as-title, "Other" pre-selected, reason "we'll fetch a preview after saving" | Save, Cancel, change chip |
| `duplicate` | 200 with `existing: true` | "saved N days ago" header, primary becomes "Update note" | Done, update note, view in app |
| `offline` | URLError network unreachable | Error banner, URL-as-title, "Save offline" primary | Save offline, Cancel |
| `authExpired` | 401 response | Banner "Open the app to re-link", no chips | Open app, Cancel |
| `saved` | After `commitSave` 2xx | Brief checkmark anim 300ms | None — dismissing |

**Save button is enabled from `fetching` onward.** Tap during fetching → ViewModel uses whatever local state it has + the in-flight POST result when it lands. Never block on network for commit.

---

## §A — API contract (summary)

Full payloads in `quick_save_spec.html` §04. Concise version for code:

| Endpoint | Method | Auth | Purpose |
|---|---|---|---|
| `/v1/links` | POST | `X-API-Key: <ingest_token>` | Create or dedupe link |
| `/v1/links/{id}` | PATCH | `X-API-Key` | Edit category / note / reminder after save |
| `/v1/links/{id}` | GET | `X-API-Key` | Poll if status=pending |
| `/v1/ingest-tokens` | POST | `Authorization: Bearer <JWT>` | Mint per-device token (main app) |
| `/v1/ingest-tokens/{id}` | DELETE | `Authorization: Bearer <JWT>` | Revoke (main app, Devices screen) |

Required headers on POST `/v1/links`:
- `X-API-Key` — per-device ingest token
- `X-Idempotency-Key` — v4 UUID generated per save attempt (not per URL)
- `X-Client` — `ios-share-ext/0.1.0` for telemetry

Response codes: 201 (new+enriched), 200 (duplicate), 202 (new+pending), 400, 401, 429, 5xx.

---

## §T — Timing budget

Hard target: tap to perceived save **≤ 1500ms**. Per `quick_save_spec.html` §05:

| Phase | Budget | Cumulative |
|---|---|---|
| Extension process spawn + viewDidLoad | 0–120ms | 120ms |
| Fire POST + render skeleton sheet (parallel) | 120ms | 120ms |
| TLS + request body | 60ms | 180ms |
| API validate + canonicalize + dedupe check | 40ms | 220ms |
| Inline metadata fetch (oEmbed / OG) | ≤ 480ms | 700ms |
| Classifier call (Haiku / 4o-mini) | ≤ 200ms | 900ms |
| Persist + serialize response | 200ms | 1100ms |
| Response back to extension | 100ms | 1200ms |
| Skeleton → full card update | 200ms | 1400ms |

**Server-side bail rule:** if inline metadata fetch will exceed 600ms, API returns `202` immediately. Worker continues server-side. Extension never blocks past 1100ms total.

**Client-side bail rule:** if no response by 8s, treat as offline — enqueue and show offline banner. Sheet remains usable; user can still Save.

---

## §U — Auth handoff sequence

How the extension gets a valid ingest token:

1. User installs app, opens it, taps Apple Sign-In
2. Main app receives Apple ID JWT → POST `/v1/auth/exchange` → backend issues app JWT
3. Main app POST `/v1/ingest-tokens` with JWT → backend returns per-device ingest token
4. Main app writes token to Keychain with access group `$(AppIdentifierPrefix)com.yourapp.shared`
5. Extension reads from same Keychain access group on every launch
6. If user revokes from Settings → Devices, backend invalidates token; extension's next POST gets 401 → `authExpired` state

**One token per device.** If user installs on iPhone + iPad, each gets its own token via the same mint flow.

---

## §F — Failure modes & UI mapping

From `quick_save_spec.html` §07. Implementation rules:

- **No alert dialogs.** Ever. All failures become inline banners or state transitions.
- **No URL ever destroyed.** Cancel after POST → leaves link in DB. User removes from inbox later if unwanted.
- **Idempotency-Key + `(user_id, canonical_url)` unique constraint** = two layers of dedupe. Safe to retry from queue drain without producing duplicates.
- **Token expiry surfaces in extension but is fixed in main app.** Extension can't re-auth — just directs to app via deep link.

---

## §P — Build phases

### Phase A — Walking skeleton (1 day)
- Xcode project + 3 targets + App Group + Keychain access group configured
- ShareViewController extracts URL from `NSExtensionItem`, prints to console, dismisses
- Hardcoded API base URL pointing to local FastAPI (idea.md §12 Phase 1)
- POST `/v1/links` with hardcoded token, log response

**Done when:** Share a URL from Safari → see it appear in backend logs.

### Phase B — SwiftUI sheet, ready & partial states (2 days)
- `QuickSaveSheet` SwiftUI view with skeleton, ready, partial layouts
- `ShareViewModel` with state machine
- Wire `beginSave` to `APIClient.ingest`
- Category chip row, basic chip selection (no AI mark yet)
- Save button commits, calls `completeRequest`

**Done when:** Share a URL → see skeleton → see real metadata in ~1s → tap Save → sheet dismisses → link in DB.

### Phase C — Duplicate, offline, authExpired (1 day)
- Handle 200 (`existing: true`), 401, network errors
- Error banner component
- Reason line component

**Done when:** Sharing same URL twice shows duplicate state. Airplane mode shows offline banner. Invalid token shows re-link CTA.

### Phase D — Offline queue (1 day)
- `OfflineQueue` in Shared module
- Extension enqueues on offline/5xx/timeout
- Main app drains on launch (the rest of drain triggers come in Phase F)

**Done when:** Save while offline → toggle network on → open main app → link appears in DB.

### Phase E — Note, reminder, AI mark (1 day)
- Note inline expansion (no modal)
- Reminder toggle with date inference from note text ("saturday" → next Saturday 10am)
- ✦ mark on AI-suggested chip, confidence in reason line
- Category override fires PATCH fire-and-forget after save

**Done when:** All 6 states from `quick_save_spec.html` §02 are reachable and pixel-faithful to the mockups.

### Phase F — Production hygiene (1 day)
- `BGAppRefreshTask` registration + drain
- `NWPathMonitor` reachability drain trigger
- Telemetry (per `quick_save_spec.html` §08 — time-to-ready, save rate by state, override rate, cancel rate by state)
- Haptic on save (`UIImpactFeedbackGenerator(.light)`)

**Done when:** App survives airplane-mode → online transition with queue auto-draining in background.

### Phase G — Real auth (handoff from Phase 2 of backend plan)
- Apple Sign-In in main app
- Token mint flow
- Devices screen with revoke

**Done when:** New user flow works end-to-end without any hardcoded tokens.

---

## §N — Explicit non-goals (v1)

Mirroring `quick_save_spec.html` §09:

- No multi-link save
- No tag input on the sheet (tags live in Link Detail in main app)
- No in-sheet preview of linked content
- No category creation from sheet (the `+` chip deep-links to main app)
- No customizing field order or hiding fields
- No haptics on Cancel or chip selection (only on Save)
- No Android (separate plan when we get there)
- No image/file shares — URLs only

---

## §R — Risks & mitigations

| Risk | Mitigation |
|---|---|
| LinkedIn (and others) block metadata scrape | Spec already plans for `partial` state. Server returns 202, worker retries server-side with rotating user agents. UX is unaffected. |
| Extension OOM (>120MB) on memory-heavy hosts | Never load full images in extension. Thumbnail comes back as URL only; rendered post-dismiss in main app. |
| Extension killed by host before save completes | Idempotency key + `(user_id, canonical_url)` makes retry safe. Queue drain in main app recovers. |
| Connection reuse assumption (HTTP/2 keep-alive) doesn't hold across extension launches | Budget for fresh TLS handshake every save (~60–100ms). Don't optimize this. |
| Apple rejects extension at review | Activation rules narrow (`SupportsWebURLWithMaxCount=1`). No background-mode abuse. Privacy disclosure for outbound metadata enrichment in App Privacy. |

---

## §D — Definition of done (v1)

- All 6 sheet states from spec are reachable on a real device
- p95 time-to-ready ≤ 1500ms on LTE, ≤ 800ms on WiFi
- Sharing the same URL twice produces exactly one DB row
- Airplane-mode save → online → drain produces exactly one DB row
- Token revocation from Settings → Devices invalidates extension's next save with `authExpired` UI
- Telemetry dashboard shows time-to-ready, save rate by state, override rate
- Zero error alert dialogs reachable through any code path
