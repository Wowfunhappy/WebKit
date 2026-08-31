# Privacy preference pages

Drive the three privacy behaviours Safari 7 has no modern surface for. Serve this directory (or any
parent of it) over http and open the pages from loopback:

    cd MavericksSupport/tests && python3 -m http.server 8899

| Page | Checks | Scored | Needs |
|---|---|---|---|
| `fingerprinting.html` | `screen.*` under Advanced Tracking and Fingerprinting Protection: protected reads `availLeft`/`availTop` 0 and a screen the size of the content area | title + banner | Safari ▸ Privacy ▸ "Ask websites not to track me" toggled between runs |
| `storage-access-top.html` | `document.requestStorageAccess()` in a cross-site frame raises WebKit's consent sheet on the window and the answer decides the promise | manual, title | first-party interaction on the embedded origin (below) |
| `first-party-interaction.html` | records the ITP first-party user interaction the embedded origin needs before it may ask for storage access | title | a click |
| `httpsfirst-srv.py` | an http main-frame navigation is rewritten to https before it leaves the process, and falls back to http when that fails | server stdout | `sudo python3 httpsfirst-srv.py 443` and `sudo python3 httpsfirst-srv.py 80`, then http://wktest.example/ |
| `sso-quirk-host.m` | the organization variant of the consent sheet — disclosure triangle and related-websites table — which no site can reach without WebPrivacy.framework's quirk list | manual, visual | see below |

## HTTPS-by-default

`wktest.example` resolves to 127.0.0.1 through `/etc/hosts`. Run the probe on both 443 and 80 and
open `http://wktest.example/`: 443 logs a `TLS … ClientHello` (the upgrade), the handshake fails, 80
logs the plain `GET` (the automatic fallback), and the page renders. A run that logs nothing on 80 is
the fallback failing, which makes every http-only site unreachable.

## Storage access

1. `http://localhost:8899/privacy-preferences/first-party-interaction.html` and click, so ITP records
   a first-party interaction for `localhost`.
2. `http://127.0.0.1:8899/privacy-preferences/storage-access-top.html` and click the button in the
   frame. The frame is loaded from the other loopback name at the same path.

Both names are loopback, so both are secure contexts (the Storage Access API refuses anything else),
and they are different sites, so the frame is third-party. WebKit records the answer, so a second run
is granted without asking; clear it with

    sqlite3 ~/Library/WebKit/com.apple.Safari/WebsiteData/ResourceLoadStatistics/observations.db \
        "delete from StorageAccessUnderTopFrameDomains;"

with Safari quit.

## The organization (SSO) sheet

    clang -fobjc-arc -framework Cocoa -o sso-quirk-host sso-quirk-host.m
    ./sso-quirk-host          # then click the button in the frame

Safari cannot host this: it carries entitlements, so dyld prunes `DYLD_INSERT_LIBRARIES` and the
quirk cannot be planted from outside. Four things have to line up, and the host does all four:

- The store must be a **test store** (`WKWebsiteDataStoreSetStatisticsIsRunningTest`). Without it
  `ResourceLoadStatisticsStore::shouldSkip` drops the literal domain `localhost` from every
  skip-guarded setter, and prevalence silently never takes.
- Every ITP setter runs **after a first load has completed**. The statistics store does not exist
  before that and a setter issued earlier is discarded with no error.
- The embedded domain must be **prevalent**, or the request is answered from the cookie policy
  instead of being put to the user. Gate on `_getIsPrevalentDomain:` reading back 1; the setter's
  completion handler fires either way.
- The web view needs a **UI delegate**. Without one the page keeps the base `API::UIClient`, whose
  storage-access default grants without asking anyone.
