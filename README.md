# ShipKit for iOS

Remote settings, feature flags, version enforcement, update reminders, in-app feedback with a reply inbox, feature ratings, a feature request board and push campaigns (questions, feedback requests, messages), for iOS 16+.

- Zero dependencies, Swift 6 strict concurrency.
- Never blocks launch: reads come from memory (disk cache, then bundled defaults, then your call-site default) and the network refresh runs in the background.
- Never asks for reviews or feedback on its own. Feedback and rating UI only appears where you put it, or on shake if you opt in.
- Never asks for notification permission on its own. Only `ShipKit.requestPushPermission()` does.

## Installation

Swift Package Manager:

```
https://github.com/shipkit-cloud/shipkit-ios.git
```

In Xcode: **File > Add Package Dependencies…**, paste the URL, and add the `ShipKit` library to your app target. In `Package.swift`:

```swift
.package(url: "https://github.com/shipkit-cloud/shipkit-ios.git", from: "1.2.0")
// ...
.product(name: "ShipKit", package: "shipkit-ios")
```

## Configure

Call `configure` once, as early as possible:

```swift
import ShipKit
import SwiftUI

@main
struct MyApp: App {
    init() {
        ShipKit.configure(with: "skc_prod_...") { o in
            o.signingKey = "BASE64_ED25519_PUBLIC_KEY"       // needed for tamper-proof version rules
            o.defaults = ["max_upload_mb": 25]                // fallback values
            o.defaultsResource = "ShipKitDefaults"            // and/or ShipKitDefaults.json / .plist in the main bundle
            o.refresh = .onForeground(minInterval: 900)       // or .manual
            o.lockFlagsOnLaunch = false                       // true: values stay fixed for the session
            o.telemetry = .on                                 // daily ping + flag exposure counts; .off disables
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .shipKitGate()
        }
    }
}
```

| Option | Default | Notes |
|---|---|---|
| `apiURL` | `https://api.shipkit.cloud` | Set it only for staging or local backends. |
| `signingKey` | `nil` | Base64 of the raw 32-byte Ed25519 public key from the dashboard. Set it: without it version rules can be changed in transit. See [Signed snapshots](#signed-snapshots). |
| `versionCheckMaxAge` | `nil` | Longest time the app may go without a successful check before it shows a "connect to continue" screen. See [Offline behaviour](#offline-behaviour). |
| `debugTools` | `.automatic` | On in debug builds, off in release builds. `.enabled` turns the developer tools on in every build. |
| `defaults` / `defaultsResource` | empty | Used before the first snapshot and for missing keys. |
| `refresh` | `.onForeground(minInterval: 900)` | Always refreshes on launch. |
| `lockFlagsOnLaunch` | `false` | Fresh values apply on next launch. |
| `telemetry` | `.on` | At most one ping per day, plus one exposure per flag/variant per session. |
| `push` | automatic | `environment`, `foregroundPresentation` and `openURL`. See [Push notifications](#push-notifications). |

**Overrides for development and tests**

These only work while `debugTools` is on, which by default means debug builds. A release build ignores them unless you set `o.debugTools = .enabled`, which you should only do for internal builds.

- Environment variable `SHIPKIT_API_URL` (or launch argument `-ShipKitAPIURL <url>`) replaces the API URL, for example `http://localhost:8787`. For plain-HTTP local backends add `NSAppTransportSecurity > NSAllowsLocalNetworking = YES` to your Info.plist.
- Launch argument `-ShipKitSimulateVersion 1.0.0`, or the UserDefaults key `ShipKitSimulatedAppVersion`, sends a different marketing version to the backend. `ShipKit.DebugView()` sets the key for you.

## Identify users (optional)

```swift
ShipKit.identify(userID: "u_123", email: "ana@example.com", name: "Ana",
                 paymentMonthly: 9.99, attributes: ["plan": "pro"])
```

The identity is saved, sent to `POST /v1/identify` and included in every request context, so targeting rules and feedback threads follow the user.

`paymentMonthly` is taken at the app's word, up to a ceiling you set per project (Settings → General in the dashboard, 100 by default). Your client key ships inside the app, so someone determined can send their own value. If revenue per feature request matters to your decisions, switch the project to backend-only revenue and set amounts from your server with the management API; values sent by the app are then ignored.

## Settings and flags

Reads are synchronous and safe from any thread:

```swift
let maxUpload = ShipKit.setting("max_upload_mb", default: 25)          // Int
let ratio = ShipKit.setting("discount", default: 0.0)                  // Double
let banner = ShipKit.setting("promo_banner", default: "")              // String
let limits = ShipKit.setting("limits", default: ShipKitValue.null)     // raw JSON
let config = ShipKit.setting("paywall", default: PaywallConfig.fallback) // any Decodable

if ShipKit.isEnabled("new_onboarding") { ... }
switch ShipKit.variant("paywall_layout", default: "control") { ... }
```

If the stored value can't be converted to the requested type, you get the default.

In SwiftUI, property wrappers re-render the view when a new snapshot arrives:

```swift
struct Home: View {
    @ShipKitSetting("promo_banner", default: "") var banner
    @ShipKitFlag("new_onboarding") var newOnboarding
    @ShipKitVariant("paywall_layout", default: "A") var layout
}
```

Other calls:

```swift
await ShipKit.refresh()                      // fetch now, then retry queued feedback
let status = await ShipKit.versionStatus()   // .ok, .updateRecommended, .updateRequired, .blocked, .maintenance
let unread = await ShipKit.unreadCount()
ShipKit.installID                            // anonymous install ID, handy for support
```

## Version gate

`.shipKitGate()` on your root view handles everything:

- **required / blocked**: a full-screen update screen that can't be dismissed, with a button to `storeURL`.
- **maintenance**: a full-screen maintenance screen showing `maintenance.message` and `until`, with a retry button.
- **recommended**: a dismissible sheet with the server's title, message and personal notes ("The issue you reported is fixed in 2.5.0"). It follows the server's reminder cadence. The first reminder for a version shows right away. After that, `everyLaunches` and `everyDays` must both have passed, `maxPerVersion` caps the total, and `allowSkip` adds "Skip this version".
- **What's New**: shown once, on the version it describes.

At most one sheet is shown per launch.

The gate fails open. With no network and no cache it never blocks. A cached `required`, `blocked` or `maintenance` stays enforced offline. If the app was updated since the cached snapshot was fetched, the status is worked out again locally from `min` and `recommended`, so an old block never outlives the update.

You can use the screens directly:

```swift
ShipKit.UpdateRequiredView(info)
ShipKit.UpdateReminderSheet(info)
ShipKit.MaintenanceView(info)
ShipKit.WhatsNewView(version: "2.4.0", items: ["Dark mode", "Faster sync"])
```

## Feedback

Place these wherever they fit (inside a `NavigationStack` for the links):

```swift
Section("Support") {
    ShipKit.FeedbackLink()          // pushes the feedback form
    ShipKit.FeedbackInboxLink()     // conversations, with unread badge
    ShipKit.RequestBoardLink()      // feature request board
}

ShipKit.FeedbackButton()            // presents the form in a sheet
ShipKit.FeedbackView(category: .idea)
ShipKit.FeedbackInboxView()
ShipKit.RequestBoardView()
ShipKit.RatingRow(feature: "new_editor")   // static thumbs up / down, shows the existing score
```

The feedback form has a category (bug, idea, question, praise), an optional 1–5 star rating, the message, an optional email and screenshots. Screenshots come from the photo library or from the screen the user came from. Users can black out regions before sending. The form lists exactly which device context is attached. Feedback sent while offline is saved to disk and sent on the next successful refresh.

The inbox lists threads with status, "Fixed in" badges and unread counts, and opens a chat-style conversation with replies. The request board has tabs for Open, Planned, In Progress and Done, plus voting, comments and a form for new requests. New requests are reviewed before other users see them.

Shake to report is off by default. To turn it on:

```swift
ShipKit.config.feedback.shakeToReport = true   // requires .shipKitGate() on the root view
```

### Customisation

```swift
ShipKit.theme.primaryColor = .indigo
ShipKit.theme.cornerRadius = 16
ShipKit.config.feedback.attachScreenshot = false
ShipKit.config.feedback.showsRating = false
ShipKit.config.strings["feedback.title"] = "Contact us"   // any key from Localizable.strings
```

Built-in strings are localized in English, German, Spanish, French, Italian, Japanese, Korean, Dutch, Polish, Brazilian Portuguese and Simplified Chinese.

## Push notifications

ShipKit can deliver questions, feedback requests and messages that you write in the dashboard. Push is opt-in twice: your app decides when to ask iOS for permission (ShipKit never calls `requestAuthorization` or `registerForRemoteNotifications` by itself), and every install can switch developer questions off from your settings screen.

### 1. Enable the capability

In Xcode, add **Push Notifications** under *Signing & Capabilities* (this adds the `aps-environment` entitlement), and upload your APNs key in the dashboard.

ShipKit reports the token's APNs environment as `sandbox` in debug builds and `production` otherwise. If you ship a release build signed with development provisioning, set it explicitly:

```swift
ShipKit.configure(with: "skc_prod_...") { o in
    o.push.environment = .sandbox              // nil (default) = automatic
    o.push.foregroundPresentation = [.banner, .sound, .list]
    o.push.openURL = { url in router.open(url) } // message links; default is UIApplication.shared.open
}
```

### 2. Forward the device token

SwiftUI apps add an app delegate:

```swift
@main
struct MyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    init() { ShipKit.configure(with: "skc_prod_...") }
    var body: some Scene { WindowGroup { ContentView().shipKitGate() } }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = ShipKit.notificationDelegate  // see "Handling" below
        application.registerForRemoteNotifications()   // never prompts; keeps the token fresh once allowed
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        ShipKit.setPushToken(deviceToken)
    }
}
```

`setPushToken` sends the token (lowercase hex), its environment, the current authorization status and the request context to `POST /v1/push/token`. The token is cached and re-sent on every launch, and again whenever the authorization status changes (checked each time the app returns to the foreground), so turning notifications on or off in the Settings app is picked up without any code. Call `try await ShipKit.clearPushToken()` on sign-out to stop pushes to this device.

### 3. Ask for permission when it makes sense

```swift
Button("Turn on notifications") {
    Task { let granted = await ShipKit.requestPushPermission() }
}
```

`requestPushPermission()` asks for alert, sound and badge permission, registers for remote notifications and reports the new status. Call it after the user has seen why notifications are useful, not on first launch.

### 4. Let people opt out

App Review guideline 4.5.4 requires an in-app way to opt out of promotional notifications. Drop the toggle into your settings `Form`:

```swift
Form {
    ShipKitPushAsksToggle()   // "Questions from the developer", with a short footer
}
```

When it's off, the install gets no question, feedback or message campaigns. The toggle reads the cached value, syncs it with `GET /v1/push/preferences` when shown and writes with `PUT /v1/push/preferences`. Without the view:

```swift
ShipKit.pushAsksEnabled                 // cached, updated on each token registration
try await ShipKit.setPushAsks(false)
```

### 5. Handling

**No notification delegate of your own:** assign the ready-made one in `didFinishLaunching` (as above). It shows ShipKit pushes as banners while the app is open and handles taps and action buttons. Other notifications keep the system default.

**You already have a delegate:** forward to ShipKit and keep handling the rest. `handleNotificationResponse` returns `false` for notifications that aren't ShipKit's:

```swift
extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if let options = ShipKit.notificationPresentationOptions(for: notification) { return completionHandler(options) }
        completionHandler([.banner, .sound])   // your own notifications
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if ShipKit.handleNotificationResponse(response, completionHandler: completionHandler) { return }
        // your own notifications, then:
        completionHandler()
    }
}
```

Use the completion-handler forms shown. With the `async` forms of these delegate methods iOS runs the completion off the main thread, and UIKit terminates the app when someone answers from a notification while it is open. ShipKit calls `completionHandler` on the main thread for its own pushes. If your compiler complains about `UNNotificationResponse` not being Sendable, use `@preconcurrency import UserNotifications`.

What a ShipKit push does:

| Push | Tap | Action buttons |
|---|---|---|
| message | Records the open and opens `url` (through `o.push.openURL` if set). | — |
| feedback | Opens the feedback form with the developer's prompt above it. | — |
| question, yes/no | Opens the question sheet. | Yes / No |
| question, 1–5 | Opens the question sheet with stars. | ★☆☆☆☆ … ★★★★★ |
| question, choice | Opens the question sheet with the options. | — |
| question, text | Opens the question sheet with a text field. | Reply (inline text) |

Action buttons send the answer in the background without opening any UI. Answers that fail because the device is offline are retried on the next launch. Dismissing a notification is recorded as well. The question sheet offers an optional comment for yes/no, scale and choice questions. If the push arrived without the full question (payload size limit), the sheet fetches it from the server.

When a tap launches the app, the sheet is queued and shown as soon as `.shipKitGate()` is on screen, before any update reminder. Without the gate, ShipKit presents it over the top-most view controller once a window is ready.

ShipKit registers four categories (`SHIPKIT_YESNO`, `SHIPKIT_SCALE`, `SHIPKIT_TEXT`, `SHIPKIT_OPEN`) when it's configured. They're merged with your own, never replacing them. If you call `setNotificationCategories` yourself after configuring ShipKit, include `ShipKit.notificationCategories`.

### Testing on the simulator

`Example/push-samples/` has one `.apns` file per push kind and question type. Drag one onto the simulator running the demo, or:

```
xcrun simctl push booted dev.shipkit.demo Example/push-samples/question-scale.apns
```

The sample delivery IDs don't exist on a real backend, so sending an answer from them fails. Campaigns from the dashboard carry real IDs.

## Signed snapshots

When `signingKey` is set, every snapshot response, `200` and `304 Not Modified` alike, must carry a valid `X-ShipKit-Signature-V2`. Copy the public key (base64 of the raw 32 bytes) from the dashboard.

The header is a base64 Ed25519 signature, checked with CryptoKit, over this string:

```
shipkit-snapshot-v2\n<install ID>\n<SHA-256 hex of the request body>\n<SHA-256 hex of the response body>
```

Because the request is part of what is signed, and every request carries a fresh `nonce`, the SDK only accepts an answer to the exact request it just sent. That rules out:

- editing the response (for example turning `required` into `ok`),
- editing the request so the server evaluates another app version, user or attribute,
- replaying a response captured earlier or on another device,
- answering `304` to everything to freeze the cache.

A response that fails the check is dropped and the last verified snapshot stays in effect. The cached snapshot is stored with its request and signature and checked again on every launch, so an edited cache is dropped too.

Without `signingKey` none of this applies and the SDK trusts whatever arrives over TLS.

### Offline behaviour

By default the SDK never holds the app when it can't reach ShipKit: it runs on the last verified snapshot, or on bundled defaults when there is none. A block that is already cached stays in force offline, but a new rule can't arrive, so someone who cuts the app off from the network keeps the old answer.

If a required update must not be avoidable that way, set a limit:

```swift
o.versionCheckMaxAge = 7 * 86_400   // seven days
```

Once that long has passed without a successful check (counted from first launch on a new install), `VersionStatus` becomes `.checkRequired` and `.shipKitGate()` shows `ShipKit.CheckRequiredView`, a "connect to continue" screen with a retry button. It lifts on the next successful check. Pick a window your offline users can live with.

Version rules are enforced by code on the user's device. They hold against proxies and edited files; someone who modifies the app binary can still remove them, so don't make them the only guard for anything critical.

## Debug screen

`ShipKit.DebugView()` lists every setting and flag with its source. You can override values locally (the overrides persist), simulate an app version, trigger a refresh, clear the cache and reset reminder and What's New state.

It follows `debugTools`. In a release build it shows "Debug tools are disabled in this build", and version simulation, stored overrides and the API URL override are ignored, so shipping the screen by accident gives nobody a way past your version rules. Set `o.debugTools = .enabled` to use it in an internal or TestFlight build.

## Testing

```swift
@MainActor
func testPaywallB() {
    ShipKit.configureForTesting(snapshot: ShipKitSnapshot(
        settings: ["max_upload_mb": 50],
        flags: ["paywall_layout": "B"],
        version: VersionInfo(status: .ok)
    ))
    XCTAssertEqual(ShipKit.variant("paywall_layout"), "B")
}
```

`configureForTesting` performs no networking and writes nothing to disk. You can also build a snapshot from JSON with `ShipKitSnapshot(jsonData:)`.

Run the SDK tests from this folder:

```
xcodebuild test -scheme ShipKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Privacy

- No tracking and no advertising identifiers. The SDK ships a `PrivacyInfo.xcprivacy` that declares no tracking and the UserDefaults API reason `CA92.1`. It lists every data type ShipKit can collect: device ID (the install UUID), product interaction (pings, flag exposures, ratings), customer support content, photos (screenshots the user attaches), plus email, user ID, name and purchase info, which are only sent if you call `identify` or the user types them in. The manifest marks them all as linked to the user, because they are once you call `identify` or the user leaves an email. What you answer in App Store Connect depends on the features you use: see [App Store privacy labels](https://shipkit.cloud/docs/#privacy-labels), or run `npx @shipkit-cloud/cli privacy` in your project folder.
- The install ID is a random UUID stored in the Keychain, so it stays the same across reinstalls. It isn't derived from any hardware identifier.
- Request context: app version and build, OS version, device model identifier, locale, language and region, plus whatever you passed to `identify`.
- Snapshots are cached in `Application Support/ShipKit/`, which is excluded from backups.
- Telemetry can be turned off with `o.telemetry = .off`.
- The APNs device token is only sent if your app calls `setPushToken`, together with the notification authorization status. Answers to push questions are sent with the request context, like feedback.

## Demo app

`Example/` contains a SwiftUI demo. Generate the project with XcodeGen and run it:

```
cd Example
xcodegen generate
open ShipKitDemo.xcodeproj
```

It reads `SHIPKIT_CLIENT_KEY` (or `-ShipKitClientKey`), `SHIPKIT_API_URL` (default `http://localhost:8787`) and `SHIPKIT_SIGNING_KEY` from the scheme. The `-ShipKitSimulateVersion 1.0.0` argument is in the scheme but disabled. Enable it to see the update screens.

The demo has the push entitlement, forwards the token from its app delegate, uses `ShipKit.notificationDelegate`, and has an "Enable notifications" button and `ShipKitPushAsksToggle` in its Settings tab. Use the files in `push-samples/` to try each push type.
