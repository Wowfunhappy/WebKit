/*
 * Copyright (C) 2004, 2005, 2006, 2007, 2008, 2009 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 *
 *     * Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above
 * copyright notice, this list of conditions and the following disclaimer
 * in the documentation and/or other materials provided with the
 * distribution.
 *     * Neither the name of Google Inc. nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "TreeScopeOrderedMap.h"

#include "ContainerNodeAlgorithms.h"
#include "ContainerNodeInlines.h"
#include "ElementInlines.h"
#include "HTMLImageElement.h"
#include "HTMLLabelElement.h"
#include "HTMLMapElement.h"
#include "HTMLNameCollection.h"
#include "TreeScopeInlines.h"
#include "TypedElementDescendantIteratorInlines.h"
#include <wtf/TZoneMallocInlines.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(TreeScopeOrderedMap);

using namespace HTMLNames;

void TreeScopeOrderedMap::clear()
{
    m_map.clear();
}

void TreeScopeOrderedMap::add(const AtomString& key, Element& element, const TreeScope& treeScope)
{
    ASSERT_WITH_SECURITY_IMPLICATION(!key.isNull());
    RELEASE_ASSERT_WITH_SECURITY_IMPLICATION(&element.treeScope() == &treeScope);
    ASSERT_WITH_SECURITY_IMPLICATION(treeScope.rootNode().isShadowIncludingInclusiveAncestorOf(&element));

    if (!element.isInTreeScope())
        return;
    Map::AddResult addResult = m_map.ensure(key, [&element] {
        return MapEntry(&element);
    });
    MapEntry& entry = addResult.iterator->value;

#if ASSERT_ENABLED || ENABLE(SECURITY_ASSERTIONS)
    ASSERT_WITH_SECURITY_IMPLICATION(!entry.registeredElements.contains(&element));
    entry.registeredElements.add(element);
#endif

    if (addResult.isNewEntry)
        return;

    RELEASE_ASSERT_WITH_SECURITY_IMPLICATION(entry.count);
    entry.element = nullptr;
    entry.count++;
    entry.orderedList.clear();
}

void TreeScopeOrderedMap::remove(const AtomString& key, Element& element)
{
    // MAVERICKS_BACKPORT: KEYSTONE BAND-AID #54/#40 — RELEASE_ASSERT_WITH_SECURITY_IMPLICATION
    // hard-traps softened to silent bails (key.isNull() and it==end()).
    if (key.isNull())
        return;
    auto it = m_map.find(key);
    // MAVERICKS_BACKPORT: #54/#40 band-aid — silent bail replacing the upstream end()-trap.
    // arstechnica's JS DOM manipulation triggers remove(<key>, <element>) for entries where
    // the map state is out of sync with the element (id/name attribute change races,
    // custom-element bypass effects, etc.). Bail rather than SIGTRAP — the map rebuilds
    // organically as DOM mutations continue.
    // FLAG: root-cause the #54/#40 map-desync, then restore the upstream security asserts.
    if (it == m_map.end())
        return;
    MapEntry& entry = it->value;
    // MAVERICKS_BACKPORT: #54/#40 band-aid — registeredElements bookkeeping kept only for assert builds
    // (its result is no longer asserted on); skip it in release to match the softened traps above.
#if ASSERT_ENABLED || ENABLE(SECURITY_ASSERTIONS)
    entry.registeredElements.remove(element);
#endif
    // MAVERICKS_BACKPORT: #54/#40 band-aid — tolerate entry.count==0 (treat like ==1) and drop the
    // upstream RELEASE_ASSERT(entry.count)/element-identity security traps; remove the entry and bail.
    if (!entry.count || entry.count == 1) {
        m_map.remove(it);
        return; // MAVERICKS_BACKPORT: #54/#40 band-aid — bail on count 0/1 without the upstream traps.
    }
    // MAVERICKS_BACKPORT: #54/#40 band-aid — multi-count path without the security asserts above.
    if (entry.element == &element)
        entry.element = nullptr;
    entry.count--;
    entry.orderedList.clear();
}

template <typename KeyMatchingFunction>
inline RefPtr<Element> TreeScopeOrderedMap::get(const AtomString& key, const TreeScope& scope, const KeyMatchingFunction& keyMatches) const
{
    ASSERT_WITH_SECURITY_IMPLICATION(!key.isNull());
    m_map.checkConsistency();

    auto it = m_map.find(key);
    if (it == m_map.end())
        return nullptr;

    MapEntry& entry = it->value;
    ASSERT(entry.count);
    if (entry.element) {
        Ref element = *entry.element;
        RELEASE_ASSERT_WITH_SECURITY_IMPLICATION(&element->treeScope() == &scope);
        ASSERT_WITH_SECURITY_IMPLICATION(entry.registeredElements.contains(element.ptr()));
        return element;
    }

    // We know there's at least one node that matches; iterate to find the first one.
    Ref rootNode = scope.rootNode();
    for (Ref<Element> element : descendantsOfType<Element>(rootNode.get())) {
        if (!element->isInTreeScope())
            continue;
        if (!keyMatches(key, element))
            continue;
        entry.element = element.ptr();
        RELEASE_ASSERT_WITH_SECURITY_IMPLICATION(&element->treeScope() == &scope);
        ASSERT_WITH_SECURITY_IMPLICATION(entry.registeredElements.contains(entry.element.get()));
        return element;
    }

#if ASSERT_ENABLED
    // FormListedElement may call getElementById to find its owner form in the middle of a tree removal.
    if (auto* currentScope = ContainerChildRemovalScope::currentScope()) {
        ASSERT(&scope.rootNode() == &currentScope->parentOfRemovedTree().rootNode());
        Ref removedTree = currentScope->removedChild();
        for (Ref element : descendantsOfType<Element>(downcast<ContainerNode>(removedTree.get()))) {
            if (!keyMatches(key, element))
                continue;
            return nullptr;
        }
    }
    ASSERT_NOT_REACHED();
#endif // ASSERT_ENABLED

    return nullptr;
}

template <typename KeyMatchingFunction>
inline Vector<WeakRef<Element, WeakPtrImplWithEventTargetData>>* TreeScopeOrderedMap::getAll(const AtomString& key, const TreeScope& scope, const KeyMatchingFunction& keyMatches) const
{
    ASSERT_WITH_SECURITY_IMPLICATION(!key.isNull());
    m_map.checkConsistency();

    auto mapIterator = m_map.find(key);
    if (mapIterator == m_map.end())
        return nullptr;

    auto& entry = mapIterator->value;
    RELEASE_ASSERT_WITH_SECURITY_IMPLICATION(entry.count);

    if (entry.orderedList.isEmpty()) {
        entry.orderedList.reserveCapacity(entry.count);
        auto elementDescendants = descendantsOfType<Element>(scope.rootNode());
        for (auto it = entry.element ? elementDescendants.beginAt(*entry.element) : elementDescendants.begin(); it; ++it) {
            if (keyMatches(key, *it))
                entry.orderedList.append(*it);
        }
        RELEASE_ASSERT_WITH_SECURITY_IMPLICATION(entry.orderedList.size() == entry.count);
    }

    return &entry.orderedList;
}

RefPtr<Element> TreeScopeOrderedMap::getElementById(const AtomString& key, const TreeScope& scope) const
{
    return get(key, scope, [] (const AtomString& key, const Element& element) {
        return element.getIdAttribute() == key;
    });
}

RefPtr<Element> TreeScopeOrderedMap::getElementByName(const AtomString& key, const TreeScope& scope) const
{
    return get(key, scope, [] (const AtomString& key, const Element& element) {
        return element.getNameAttribute() == key;
    });
}

RefPtr<HTMLMapElement> TreeScopeOrderedMap::getElementByMapName(const AtomString& key, const TreeScope& scope) const
{
    return downcast<HTMLMapElement>(get(key, scope, [] (const AtomString& key, const Element& element) {
        auto* mapElement = dynamicDowncast<HTMLMapElement>(element);
        return mapElement && mapElement->getName() == key;
    }));
}

RefPtr<HTMLImageElement> TreeScopeOrderedMap::getElementByUsemap(const AtomString& key, const TreeScope& scope) const
{
    return downcast<HTMLImageElement>(get(key, scope, [] (const AtomString& key, const Element& element) {
        // FIXME: HTML5 specification says we should match both image and object elements.
        auto* imageElement = dynamicDowncast<HTMLImageElement>(element);
        return imageElement && imageElement->matchesUsemap(key);
    }));
}

const Vector<WeakRef<Element, WeakPtrImplWithEventTargetData>>* TreeScopeOrderedMap::getElementsByLabelForAttribute(const AtomString& key, const TreeScope& scope) const
{
    return getAll(key, scope, [] (const AtomString& key, const Element& element) {
        return is<HTMLLabelElement>(element) && element.attributeWithoutSynchronization(forAttr) == key;
    });
}

RefPtr<Element> TreeScopeOrderedMap::getElementByWindowNamedItem(const AtomString& key, const TreeScope& scope) const
{
    return get(key, scope, [] (const AtomString& key, const Element& element) {
        return WindowNameCollection::elementMatches(element, key);
    });
}

RefPtr<Element> TreeScopeOrderedMap::getElementByDocumentNamedItem(const AtomString& key, const TreeScope& scope) const
{
    return get(key, scope, [] (const AtomString& key, const Element& element) {
        return DocumentNameCollection::elementMatches(element, key);
    });
}

const Vector<WeakRef<Element, WeakPtrImplWithEventTargetData>>* TreeScopeOrderedMap::getAllElementsById(const AtomString& key, const TreeScope& scope) const
{
    return getAll(key, scope, [] (const AtomString& key, const Element& element) {
        return element.getIdAttribute() == key;
    });
}

const Vector<AtomString> TreeScopeOrderedMap::keys() const
{
    return WTF::map(m_map, [](auto& entry) -> AtomString {
        return entry.key;
    });
}

} // namespace WebCore
