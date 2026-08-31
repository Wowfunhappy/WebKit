/*
 * Copyright (C) 1999 Lars Knoll (knoll@kde.org)
 *           (C) 1999 Antti Koivisto (koivisto@kde.org)
 *           (C) 2000 Simon Hausmann (hausmann@kde.org)
 *           (C) 2001 Dirk Mueller (mueller@kde.org)
 * Copyright (C) 2004, 2006, 2010 Apple Inc. All rights reserved.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */

#include "config.h"
#include "HTMLHeadElement.h"

#include "DocumentLoader.h" // MAVERICKS_BACKPORT: startIconLoading() below (#112)
#include "HTMLNames.h"
#include "Text.h"
#include <wtf/TZoneMallocInlines.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(HTMLHeadElement);

using namespace HTMLNames;

HTMLHeadElement::HTMLHeadElement(const QualifiedName& tagName, Document& document)
    : HTMLElement(tagName, document)
{
    ASSERT(hasTagName(headTag));
}

Ref<HTMLHeadElement> HTMLHeadElement::create(Document& document)
{
    return adoptRef(*new HTMLHeadElement(headTag, document));
}

Ref<HTMLHeadElement> HTMLHeadElement::create(const QualifiedName& tagName, Document& document)
{
    return adoptRef(*new HTMLHeadElement(tagName, document));
}

// MAVERICKS_BACKPORT: offer this document's icons as soon as its head is parsed (#112). A page states
// its icons in the head, so they are known within the first bytes of the HTML — but WebCore asks the
// client about them only at the load event, which needs every subresource and subframe of the page:
// measured on this host, 12 s on apple.com and never at all on cnn.com, whose load event does not fire.
// A favicon is the browser's own record of the site, kept in a history entry that outlives the visit,
// and on this port the UI process fetches it; a reader who follows a link before the page has finished
// settling must not lose it. Upstream's own comment beside its call names this earlier opportunity.
// Later calls (document parsed, then loaded) still offer icons the page adds afterwards, and each icon
// URL is offered exactly once per load.
void HTMLHeadElement::finishParsingChildren()
{
    HTMLElement::finishParsingChildren();

    // Only the document's own head, and only while the document itself is being parsed. Parsing a
    // fragment also builds and pops a head element belonging to this document — assigning to
    // documentElement's innerHTML does, as does createContextualFragment on <html> — and that head
    // never enters the tree, so it is not the one LinkIconCollector reads. Acting on it would let a
    // page's script decide when its icons are fetched and written to the icon database.
    if (document().head() != this || !document().parsing())
        return;

    if (RefPtr documentLoader = document().loader())
        documentLoader->startIconLoading();
}

}
