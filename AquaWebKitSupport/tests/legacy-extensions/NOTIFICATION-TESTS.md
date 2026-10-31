The `notifications.safariextension` fixture exercises Safari's notification provider from a global page, a popover, an extension bar, and `tab.html` in a browser tab. Install it with Extension Builder, and use Reload after editing its files.

Run `server.py`, then open `http://127.0.0.1:8843/notifications.html`. The page sends commands through the fixture's content script and records replies in `notificationReplies`. The injected content script reports the web page's own permission.

```javascript
notificationCommand({ target: 'global', op: 'state' });
notificationCommand({ target: 'global', op: 'request' });
notificationCommand({ target: 'global', op: 'show', id: 'global-click' });
notificationCommand({ target: 'global', op: 'close', id: 'global-click' });
notificationCommand({ target: 'content', op: 'state' });
```

`target: 'popover'` addresses the popover. Each visible bar has its own buttons. The fixture reports its current global URL to `/log`; open `tab.html` under that same extension URL root to exercise WK2. In that tab, `notificationProbe({ op: 'request' })` requests permission and `notificationProbe({ op: 'show', id: 'tab-click' })` posts a notification. Use a real button click or Safari's AppleScript `do JavaScript` for a permission request with a user gesture.

Click a Notification Center banner and check `/log` for its `show`, `click`, and `close` events. Post a second notification and explicitly close it to check programmatic cancellation. Reports include the context, permission, origin, and notification identifier.

WebCore requires transient user activation for `Notification.requestPermission()`. A request sent to the hidden global page through runtime messaging has no activation and resolves `denied`; its `Notification.permission` can still be `granted` and notification creation remains permitted.

`/usr/bin/python check-notification-origins.py` checks the installed C API's canonical extension hosts, HTTPS host/scheme casing, default ports, and distinct extension origins. It performs no network requests.

`notification-driver.html` is a DumpRenderTree fixture served by `server.py`. It grants its local origin through the mock provider, then checks show, simulated click, and programmatic close. Run it after installing the completed build, with the installed frameworks on dyld's search path:

```sh
DYLD_FRAMEWORK_PATH="/System/Library/Frameworks:/System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks:/System/Library/PrivateFrameworks" \
WebKitBuild/Release/bin/DumpRenderTree http://127.0.0.1:8843/notification-driver.html
```
