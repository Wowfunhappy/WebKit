# SDK-aligned behaviors

WebKit changes some behaviors only for apps built against a new enough macOS SDK, so that an app keeps
the behavior it was written and tested against. Each such change is an *SDK-aligned behavior*, an entry
in `SDKAlignedBehavior` in `Source/WTF/wtf/cocoa/RuntimeApplicationChecksCocoa.h`. That header is the
authoritative list of names.

## Which behaviors an app gets

WebKit decides once per app, the first time anything asks:

1. **The SDK the app was linked against.** The linker stamps an SDK version into the main executable
   (`LC_VERSION_MIN_MACOSX`, or `LC_BUILD_VERSION`, set with `-platform_version macos <minimum> <sdk>`).
   Each behavior is on only when that version is at least the release that introduced it. An app linked
   against the 10.9 SDK gets none of them. The gates are in
   `Source/WTF/wtf/cocoa/RuntimeApplicationChecksCocoa.mm` and
   `AquaWebKitSupport/polyfill/headers/WebKitAdditions/RuntimeApplicationChecksCocoaAdditions.cpp`.
2. **Safari** (bundle identifier `com.apple.Safari`) gets every behavior, as upstream gives it.
3. **The app's Info.plist** can then turn individual behaviors on or off (below). Safari does not read it.

WebKit 2 web content, networking and GPU processes take the app's set when they launch.

## Turning behaviors on or off in Info.plist

Add `AquaWebKitSDKAlignedBehaviors` to the app's Info.plist: a dictionary from behavior name to a
Boolean. `true` turns the behavior on, `false` turns it off; behaviors not listed keep the value from
the SDK check.

```xml
<key>AquaWebKitSDKAlignedBehaviors</key>
<dict>
    <key>DefaultsToPassiveWheelListenersOnDocument</key>
    <true/>
    <key>KeepEditableSelectionOnMouseFocus</key>
    <false/>
</dict>
```

- Names are the enum names exactly, including case.
- An unknown name, an entry whose value is not a Boolean, or a key whose value is not a dictionary is
  reported on standard error (`AquaWebKitSDKAlignedBehaviors: …`) and ignored.
- The key is read from the app's main bundle when WebKit first asks, which can be before
  `applicationDidFinishLaunching:`. Nothing needs to be called.
- Upstream adds, renames and removes behaviors. After a WebKit update, check standard error for names
  that no longer exist.

Some behaviors change what WebKit expects of the app rather than how pages behave. For example,
`EnableUserScriptAndUserStyleInterning` shares one copy of each user script and user style sheet's
source, and with it on, WebKit crashes deliberately if the app creates a user script off the main
thread. Upstream leaves it off for every app except Safari, whatever the SDK. Behaviors named
`CrashWhen…` likewise turn misuse into a crash.

## Behaviors this port adds

These keep the behavior that 10.9's own apps depend on. Each is on for Safari and for apps linked
against the SDK in its "On from" column or later.

| Behavior | On from | When on | When off | App that needs it off |
| --- | --- | --- | --- | --- |
| `BlockOrUpgradeMixedContent` | 10.11 | Mixed content in a secure document is upgraded or blocked. | Mixed content loads. | NetNewsWire, whose https articles load `rsstylesheet:` and `rsfavicon:` subresources |
| `BoxPackAccountsForBoxDirection` | 27.0 | `-webkit-box-pack: start`/`end` follow `box-direction`, and overflowing children are packed. | The writing direction alone picks the pack side, and only positive free space moves children. | Messages, whose balloons right-align with `box-pack: end` under `box-direction: reverse` |
| `EmbedAttributeChangeReconstructsRenderers` | 26.1 | Any attribute change on `<embed>` reconstructs its renderers. | The plug-in view survives attribute changes; presentational attributes update style and geometry. | Dashboard's Web Clip plug-in, which rewrites its `<embed>`'s style and width on every layout |
| `KeepEditableSelectionOnMouseFocus` | 27.0 | When a click moves focus inside a contentEditable document, the selection is kept. | The selection is kept only when the pressed node cannot start a selection. | Notes and Mail, whose attachment plug-ins take a click without placing a caret |

## Other switches

`+[WKProcessPool _setLinkedOnOrAfterEverything]` (private, `WKProcessPoolPrivate.h`) turns on every
behavior for a `WKWebView` app. It has to be called before the first web content process launches.
WebKit 1 has no equivalent call.
