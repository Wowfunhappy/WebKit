/*
 * Copyright (C) 2010-2025 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

// MAVERICKS_BACKPORT: the revived legacy WK2 icon database's WebProcessPool half (#49, #112). Upstream
// deleted the icon database along with the C SPI Safari 7 drives it through; this is the port's
// implementation, kept out of WebProcessPool.cpp so that file carries only the call sites.

#include "config.h"
#include "WebProcessPool.h"

#include "APIData.h"
#include "APIIconLoadingClient.h"
#include "APIPageConfiguration.h"
#include "WebIconDatabase.h"
#include "WebPageProxy.h"
#include <WebCore/LinkIcon.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/URL.h>

namespace WebKit {

using namespace WebCore;

// MAVERICKS_BACKPORT: hand a favicon's bytes to the revived WebIconDatabase (#49).
//
// The store refuses bytes it cannot decode, which for a favicon that downloaded fine means they are in
// a format ImageIO cannot read. On 10.9 that is above all SVG: CGImageSourceCopyTypeIdentifiers lists
// the classic raster formats and camera raw, no SVG at all, so a page whose only declared favicon is an
// SVG — news.ycombinator.com's y18.svg, and increasingly common elsewhere — would have no site icon
// whatsoever. WebKit renders SVG perfectly well, and upstream already converts image data the platform
// cannot use into an .ico for exactly this reason: the web process rasterizes (SVGImage when the bytes
// are not a bitmap) and the UI process packs the frames into an .ico, which this OS's ImageIO does read.
// 16 and 32 are the only sizes Safari 7 ever asks for (IconController's smallIconSize and
// mediumIconSize).
//
// Two questions to the store come first, because both make that round trip pointless. If the page
// already has an icon this OS decoded on its own, the store will refuse a rasterized one, so rendering
// it would be waste on every load of every site that declares an SVG alongside a bitmap favicon
// (github.com declares both) — and waste that can never amortize, since a refused result is never
// stored to be found next time. And every page of an SVG-favicon site declares the same icon URL, so
// once these bytes have been rendered the store can answer from what it holds.
static void storeIconDataForPageURL(WebIconDatabase& iconDatabase, const WeakPtr<WebPageProxy>& weakPage, const String& pageURL, const String& initialRequestPageURL, const String& iconURL, Ref<API::Data>&& iconData, WebIconDatabase::Persistence persistence, WebIconDatabase::IconOrigin fetchedOrigin)
{
    // MAVERICKS_BACKPORT: bytes landing move the page's claim, so the URL its load started from
    // follows; see WebProcessPool::carryIconToInitialRequestURL (#112).
    auto carryToInitialRequestURL = [&iconDatabase, &pageURL, &initialRequestPageURL, persistence] {
        iconDatabase.carryIconForPageURL(pageURL, initialRequestPageURL, persistence);
    };

    // A guessed icon stays at Guessed rank whether its bytes decoded natively or had to be rasterized —
    // the rank records that nobody declared it, not how it was read.
    if (iconDatabase.setIconDataForPageURL(pageURL, iconURL, iconData.copyRef(), fetchedOrigin, persistence)) {
        carryToInitialRequestURL();
        return;
    }

    if (iconDatabase.hasNativelyDecodedIconForPageURL(pageURL))
        return;
    // The same cap as the fetch's own reuse: a guess claims whatever bytes it falls back on at
    // Guessed rank, however they were once decoded.
    if (iconDatabase.reuseStoredIconForPageURL(pageURL, iconURL, persistence, fetchedOrigin == WebIconDatabase::IconOrigin::Guessed ? std::optional { WebIconDatabase::IconOrigin::Guessed } : std::nullopt)) {
        carryToInitialRequestURL();
        return;
    }
    RefPtr page = weakPage.get();
    if (!page)
        return;

    auto rasterizedOrigin = fetchedOrigin == WebIconDatabase::IconOrigin::Guessed ? WebIconDatabase::IconOrigin::Guessed : WebIconDatabase::IconOrigin::Rasterized;
    auto generation = iconDatabase.generation();
    page->createIconDataFromImageData(WebCore::SharedBuffer::create(iconData->span()), { 16, 32 }, [iconDatabase = Ref { iconDatabase }, pageURL, initialRequestPageURL, iconURL, generation, persistence, rasterizedOrigin](RefPtr<WebCore::SharedBuffer>&& rasterizedIcon) {
        if (iconDatabase->generation() != generation)
            return;
        // Nothing here could read these bytes and the web process could not draw them either, so they
        // are no icon at all and this icon URL is not worth fetching again.
        if (!rasterizedIcon) {
            iconDatabase->noteUnusableIconURL(iconURL);
            return;
        }
        if (iconDatabase->setIconDataForPageURL(pageURL, iconURL, API::Data::create(rasterizedIcon->span()), rasterizedOrigin, persistence))
            iconDatabase->carryIconForPageURL(pageURL, initialRequestPageURL, persistence);
    });
}

// MAVERICKS_BACKPORT: fetch a favicon this client has taken responsibility for (#112).
//
// The store answers first, and usually can: every page of a site declares the same icon URL, so no
// request is made for a site whose icon is already held, nor for one already known to serve no icon.
//
// The fetch goes out while the page is still current and through the network process, so nothing about
// the page's own loading can cancel it — which is the whole point of doing it here. What it gives up
// against the document-owned load it replaces is that load's response handling: an icon URL answering
// with a non-2xx status returns its error page as bytes here (upstream's own UI-process image load,
// LoadAndDecodeImage, has the same reply and the same gap), so an error page is rejected by failing to
// decode rather than by its status, and this remembers the URL so that costs one fetch per site. The
// one check that cannot be left to decoding is carried over below.
static void fetchIconForPage(WebIconDatabase& iconDatabase, WebPageProxy& page, const String& pageURL, const String& iconURL, WebIconDatabase::Persistence persistence, WebIconDatabase::IconOrigin fetchedOrigin = WebIconDatabase::IconOrigin::NativelyDecoded)
{
    if (pageURL.isEmpty() || iconURL.isEmpty())
        return;

    // MAVERICKS_BACKPORT: the page's claim moves here when the icon it declares displaces the
    // commit-time guess, and the URL its load started from follows; see
    // WebProcessPool::carryIconToInitialRequestURL (#112).
    auto initialRequestPageURL = page.committedInitialRequestURL().string();
    auto carryToInitialRequestURL = [&iconDatabase, &pageURL, &initialRequestPageURL, persistence] {
        iconDatabase.carryIconForPageURL(pageURL, initialRequestPageURL, persistence);
    };

    // Age is judged before the reuse, which counts as a use and re-stamps the icon. A stale stored
    // icon still answers for the page right away — the refetch below replaces it when it lands.
    // A guess claims whatever bytes it reuses at Guessed rank, however they were once decoded.
    auto mappingRank = fetchedOrigin == WebIconDatabase::IconOrigin::Guessed ? std::optional { WebIconDatabase::IconOrigin::Guessed } : std::nullopt;
    bool needsRefresh = iconDatabase.iconNeedsRefresh(iconURL);
    // A successful reuse has moved the page's claim to this icon URL, so the second URL follows it
    // whatever the exits below decide.
    if (iconDatabase.reuseStoredIconForPageURL(pageURL, iconURL, persistence, mappingRank)) {
        carryToInitialRequestURL();
        if (!needsRefresh)
            return;
    }
    if (iconDatabase.hasNativelyDecodedIconForPageURL(pageURL) && !needsRefresh)
        return;
    if (iconDatabase.isUnusableIconURL(iconURL))
        return;

    // The page points at its icon URL from here on, whether or not the fetch below ever lands — the
    // pre-deletion IconDatabase committed the mapping before loading, "just in case", and that is
    // what lets a history entry heal when any later visit stores this URL's bytes (#112).
    iconDatabase.notePendingIconURLForPageURL(pageURL, iconURL, persistence, fetchedOrigin);
    carryToInitialRequestURL();

    // Bytes past this are not a site icon but a decoder waiting to be handed something enormous; the
    // network process stops the load there rather than buffering it for us.
    constexpr size_t maximumIconBytes = 8 * MB;

    auto generation = iconDatabase.generation();
    page.loadImageData(WebCore::ResourceRequest { URL { iconURL } }, maximumIconBytes, [iconDatabase = Ref { iconDatabase }, weakPage = WeakPtr { page }, pageURL, initialRequestPageURL, iconURL, generation, persistence, fetchedOrigin](RefPtr<WebCore::SharedBuffer>&& iconData) {
        if (iconDatabase->generation() != generation)
            return;
        // Nothing came back at all: a network error, or a load the network process refused. Say nothing
        // about the icon URL itself — the next page of the site may well get it.
        if (!iconData || iconData->isEmpty())
            return;

        // MAVERICKS_BACKPORT: upstream's IconLoader::notifyFinished refuses a PDF outright, and this OS's
        // ImageIO decodes PDF, so decoding alone would admit an icon upstream declines.
        static constexpr std::array<uint8_t, 4> pdfMagicNumber { '%', 'P', 'D', 'F' };
        if (iconData->startsWith(pdfMagicNumber)) {
            iconDatabase->noteUnusableIconURL(iconURL);
            return;
        }

        storeIconDataForPageURL(iconDatabase.get(), weakPage, pageURL, initialRequestPageURL, iconURL, API::Data::create(iconData->span()), persistence, fetchedOrigin);
    });
}

// MAVERICKS_BACKPORT: per-page icon-loading client for Safari 7's C-API pages. When WebCore finds a
// favicon it asks for a load decision; this client declines the load and fetches the icon itself, then
// hands the bytes to the revived WebIconDatabase, which notifies Safari via the legacy C client (#49).
class PageIconLoadingClient final : public API::IconLoadingClient {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(PageIconLoadingClient);
public:
    PageIconLoadingClient(WebPageProxy& page, WebIconDatabase& iconDatabase)
        : m_page(page)
        , m_iconDatabase(&iconDatabase)
    {
    }

    void getLoadDecisionForIcon(const WebCore::LinkIcon& icon, CompletionHandler<void(CompletionHandler<void(API::Data*)>&&)>&& completionHandler) override
    {
        // MAVERICKS_BACKPORT: never let WebCore load the icon (#112). It loads a declared icon as a
        // subresource of the page's own document, so leaving the page cancels it — and the load only
        // starts once parsing has finished, so an ordinary click gets there first. That loss is
        // permanent for the page: the store is written only while a page is loading, so its history
        // entry, which outlives the visit, keeps the generic globe with nothing to ever correct it.
        //
        // A favicon is the browser's record of a site rather than content the page is waiting for, so
        // this client owns the fetch, as browsers that keep favicons out of the page's loader do —
        // measured here, Firefox accepts an icon five seconds after the user has left the page.
        // Declining means WebCore starts no load of its own, so the icon is still fetched exactly once.
        completionHandler(nullptr);

        if (!icon.url.protocolIsInHTTPFamily())
            return;

        // MAVERICKS_BACKPORT: take site favicons only (github #76). This is client policy, not the
        // fix for the icon-clobbering that made favicons revert to the generic globe — the store itself
        // now refuses bytes it cannot decode, so deleting this filter cannot bring that back. Safari 7
        // asks this store for the small site icon (IconController's 16x16/32x32 requests), and an
        // apple-touch-icon is 180x180 home-screen artwork; upstream likewise leaves the choice to the
        // client, its own default client declining every icon.
        if (icon.type != WebCore::LinkIconType::Favicon)
            return;

        RefPtr page = m_page.get();
        RefPtr iconDatabase = m_iconDatabase;
        if (!page || !iconDatabase)
            return;

        // The icon belongs to the document that just finished parsing, which is the COMMITTED one — not
        // pageLoadState's activeURL, which is already the URL of a navigation under way when there is
        // one, and would file this icon under the page being navigated to.
        //
        // A private-browsing page runs on an ephemeral session; its icons must not reach the on-disk
        // database, whose page URLs alone are a browsing record.
        auto persistence = page->sessionID().isEphemeral() ? WebIconDatabase::Persistence::SessionOnly : WebIconDatabase::Persistence::Persistent;
        fetchIconForPage(*iconDatabase, *page, page->pageLoadState().url(), icon.url.string(), persistence);
    }

private:
    WeakPtr<WebPageProxy> m_page;
    RefPtr<WebIconDatabase> m_iconDatabase;
};


// MAVERICKS_BACKPORT: WebProcessPool::createWebPage attaches this; the class itself stays in this file.
std::unique_ptr<API::IconLoadingClient> createPageIconLoadingClient(WebPageProxy& page, WebIconDatabase& iconDatabase)
{
    return makeUnique<PageIconLoadingClient>(page, iconDatabase);
}

// MAVERICKS_BACKPORT: lazily create the revived per-pool icon database Safari 7 asks for (#49).
WebIconDatabase& WebProcessPool::iconDatabase()
{
    if (!m_iconDatabase)
        m_iconDatabase = WebIconDatabase::create();
    return *m_iconDatabase;
}

// MAVERICKS_BACKPORT: Safari 7 enables favicons by setting the icon-database path; treat a
// non-empty path as "enabled" and materialize the database so createWebPage attaches a real
// icon-loading client (#49). The path itself — ~/Library/Safari/WebpageIcons.db, the same file the
// pre-deletion icon database kept — backs the store on disk so History keeps its icons across
// relaunches (#112).
void WebProcessPool::setIconDatabasePath(const String& path)
{
    m_iconDatabaseEnabled = !path.isEmpty();
    if (m_iconDatabaseEnabled)
        iconDatabase().setDatabasePath(path);
}

// MAVERICKS_BACKPORT: fetch the origin's /favicon.ico the moment a main-frame load commits (#112).
// A page states its icons in its head, but a reader can leave before the head has even arrived — the
// commit is the earliest moment the page URL exists, and this fetch survives the departure like every
// fetch here does. The guess is stored at Guessed rank, so an icon the page actually declares, offered
// when its head parses, displaces it; for the many sites whose icon IS /favicon.ico, the store then
// reuses these same bytes. A revisit of a page whose real icon is already held skips this entirely
// (the natively-decoded check below), and a site whose /favicon.ico serves no icon costs one fetch per
// session (the unusable-URL note).
void WebProcessPool::fetchGuessedIconForPage(WebPageProxy& page, const URL& url)
{
    if (!m_iconDatabaseEnabled || !m_iconDatabase)
        return;

    if (!url.protocolIsInHTTPFamily())
        return;

    // The same string the offer path keys by — pageLoadState's committed URL is this URL's string
    // once the commit's transaction closes.
    auto pageURL = url.string();

    // A page whose icon is already held needs nothing from a guess. Only a guessed icon due for its
    // refresh is refetched here — a declared icon's refresh belongs to the offer that declared it.
    Ref iconDatabase = *m_iconDatabase;
    if (auto currentOrigin = iconDatabase->storedIconOriginForPageURL(pageURL)) {
        bool staleGuess = *currentOrigin == WebIconDatabase::IconOrigin::Guessed && iconDatabase->iconNeedsRefresh(iconDatabase->iconURLForPageURL(pageURL));
        if (!staleGuess)
            return;
    }

    auto persistence = page.sessionID().isEphemeral() ? WebIconDatabase::Persistence::SessionOnly : WebIconDatabase::Persistence::Persistent;
    fetchIconForPage(iconDatabase, page, pageURL, URL { url, "/favicon.ico"_s }.string(), persistence, WebIconDatabase::IconOrigin::Guessed);
}

// MAVERICKS_BACKPORT: an icon belongs to the URL its load STARTED from as well as to the committed
// one, as the pre-deletion IconController::commitToDatabase kept it — a load that began at
// http://example.com/ and redirected to https://example.com/ is reachable under both. Safari reads
// that second URL: -[AcceptedSiteDataCell drawWithFrame:inView:], which draws each site in
// Preferences -> Privacy -> Details..., has only a domain and asks this store for "http://%@/" and then
// "http://www.%@/", never the redirected https form (#112).
//
// Every commit passes through here, because the URL a load started from belongs to the load rather than
// to the page: a site already holding its icon still arrives this time from a URL nothing has recorded.
void WebProcessPool::carryIconToInitialRequestURL(WebPageProxy& page, const URL& url)
{
    if (!m_iconDatabaseEnabled || !m_iconDatabase)
        return;

    auto persistence = page.sessionID().isEphemeral() ? WebIconDatabase::Persistence::SessionOnly : WebIconDatabase::Persistence::Persistent;
    Ref { *m_iconDatabase }->carryIconForPageURL(url.string(), page.committedInitialRequestURL().string(), persistence);
}

// MAVERICKS_BACKPORT: carry a document's icon claim across a same-document navigation (#112). A
// pushState-driven site navigates without ever committing a load — github.com's every click — so the
// new URL's history entry has no other way to an icon: the declared-icon offer and the /favicon.ico
// guess both hang off loads. The document itself is unchanged, and so is its icon; the store's
// precedence rule still applies on the receiving URL, so a claim a real visit once recorded there at
// higher rank stands.
void WebProcessPool::carryIconForSameDocumentNavigation(WebPageProxy& page, const String& fromPageURL, const URL& toURL)
{
    if (!m_iconDatabaseEnabled || !m_iconDatabase)
        return;

    if (!toURL.protocolIsInHTTPFamily())
        return;

    auto persistence = page.sessionID().isEphemeral() ? WebIconDatabase::Persistence::SessionOnly : WebIconDatabase::Persistence::Persistent;
    Ref iconDatabase = *m_iconDatabase;
    iconDatabase->carryIconForPageURL(fromPageURL, toURL.string(), persistence);
}

} // namespace WebKit
