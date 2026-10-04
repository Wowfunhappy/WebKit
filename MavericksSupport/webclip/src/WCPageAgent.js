// Web Clip page agent. Runs in an isolated content world of the clip's WKWebView and does
// everything the Web Clip plug-in does with the DOM: signing the clip and finding its element from a
// ClipSignature, collecting the nodes the Snapper snaps to, and collecting the plug-in elements
// reported as Dashboard control regions, and scrolling the page.
//
// All rects are in document coordinates as {x, y, width, height}. An element's box is
// WebKit's absolute bounding box: the union of its fragment rects, each widened to whole
// pixels, and a zero rect for an element without boxes.

(function () {
    'use strict';

    const f32 = Math.fround;
    const kBoxedDOMElementTagNameKey = 'BoxedDOMElementTagName';
    const kBoxedDOMElementIDNameKey = 'BoxedDOMElementIDName';
    const kBoxedDOMElementClassNameKey = 'BoxedDOMElementClassName';
    const kClipSignatureElementKey = 'ClipSignatureElement';
    const kClipSignatureParentElementKey = 'ClipSignatureParentElement';
    const kClipSignatureChildrenKey = 'ClipSignatureChildren';
    const kClipSignatureSiblingsKey = 'ClipSignatureSiblings';
    const kClipSignatureBorderOffsetTopKey = 'ClipSignatureBorderOffsetTop';
    const kClipSignatureBorderOffsetBottomKey = 'ClipSignatureBorderOffsetBottom';
    const kClipSignatureBorderOffsetLeftKey = 'ClipSignatureBorderOffsetLeft';
    const kClipSignatureBorderOffsetRightKey = 'ClipSignatureBorderOffsetRight';
    const kClipSignatureOriginalBorderRectKey = 'ClipSignatureOriginalBorderRect';
    // The score the signed element earns against its own signature.
    const kClipSignatureScoreKey = 'ClipSignatureScore';
    // How far the boxes the signed element lies in were scrolled, together, when it was signed.
    const kClipSignatureScrollOffsetXKey = 'ClipSignatureScrollOffsetX';
    const kClipSignatureScrollOffsetYKey = 'ClipSignatureScrollOffsetY';

    const kSnapTags = ['DIV', 'IMG', 'TABLE', 'P', 'OBJECT', 'INPUT'];
    const kDraggableTags = ['OBJECT', 'EMBED', 'APPLET'];

    function makeRect(x, y, width, height)
    {
        return { x, y, width, height };
    }

    const kZeroRect = Object.freeze(makeRect(0, 0, 0, 0));

    function isZeroRect(rect)
    {
        return rect.x === 0 && rect.y === 0 && rect.width === 0 && rect.height === 0;
    }

    // NSRectFromString: four strtod() scans in the C locale. Before each scan, anything that
    // is not a digit, '+', '-' or '.' is skipped; a failed scan leaves the position unchanged.

    function isDigitCode(code)
    {
        return code >= 0x30 && code <= 0x39;
    }

    function isHexDigitCode(code)
    {
        return isDigitCode(code) || (code >= 0x41 && code <= 0x46) || (code >= 0x61 && code <= 0x66);
    }

    function hexDigitValue(code)
    {
        if (isDigitCode(code))
            return code - 0x30;
        return (code | 0x20) - 0x61 + 10;
    }

    function hexFloatValue(mantissa, exponent2)
    {
        if (!mantissa)
            return 0;
        const bitLength = mantissa.toString(2).length;
        const leadingExponent = bitLength - 1 + exponent2;
        if (leadingExponent > 1023)
            return Infinity;
        const precision = leadingExponent >= -1022 ? 53 : 53 - (-1022 - leadingExponent);
        const shift = bitLength - precision;
        if (shift > 0) {
            const bigShift = BigInt(shift);
            let kept = mantissa >> bigShift;
            const remainder = mantissa - (kept << bigShift);
            const half = 1n << (bigShift - 1n);
            if (remainder > half || (remainder === half && (kept & 1n)))
                kept += 1n;
            mantissa = kept;
            exponent2 += shift;
        }
        let value = Number(mantissa);
        // Scale in steps so no intermediate power of two over- or underflows.
        while (exponent2 > 0) {
            const step = Math.min(exponent2, 1000);
            value *= 2 ** step;
            exponent2 -= step;
        }
        while (exponent2 < 0) {
            const step = Math.max(exponent2, -1000);
            value *= 2 ** step;
            exponent2 -= step;
        }
        return value;
    }

    function matchWordAt(text, index, word)
    {
        return text.substr(index, word.length).toLowerCase() === word;
    }

    function strtod(text, start)
    {
        let index = start;
        let negative = false;
        const signCode = text.charCodeAt(index);
        if (signCode === 0x2b || signCode === 0x2d) {
            negative = signCode === 0x2d;
            index++;
        }
        const signed = value => (negative ? -value : value);

        if (text.charCodeAt(index) === 0x30 && (text.charCodeAt(index + 1) | 0x20) === 0x78) {
            let cursor = index + 2;
            let mantissa = 0n;
            let digitCount = 0;
            let fractionDigits = 0;
            while (isHexDigitCode(text.charCodeAt(cursor))) {
                mantissa = mantissa * 16n + BigInt(hexDigitValue(text.charCodeAt(cursor)));
                digitCount++;
                cursor++;
            }
            if (text.charCodeAt(cursor) === 0x2e) {
                cursor++;
                while (isHexDigitCode(text.charCodeAt(cursor))) {
                    mantissa = mantissa * 16n + BigInt(hexDigitValue(text.charCodeAt(cursor)));
                    digitCount++;
                    fractionDigits++;
                    cursor++;
                }
            }
            if (digitCount) {
                let binaryExponent = 0;
                if ((text.charCodeAt(cursor) | 0x20) === 0x70) {
                    let exponentCursor = cursor + 1;
                    let exponentNegative = false;
                    const exponentSign = text.charCodeAt(exponentCursor);
                    if (exponentSign === 0x2b || exponentSign === 0x2d) {
                        exponentNegative = exponentSign === 0x2d;
                        exponentCursor++;
                    }
                    if (isDigitCode(text.charCodeAt(exponentCursor))) {
                        let exponentValue = 0;
                        while (isDigitCode(text.charCodeAt(exponentCursor))) {
                            exponentValue = Math.min(exponentValue * 10 + text.charCodeAt(exponentCursor) - 0x30, 1e9);
                            exponentCursor++;
                        }
                        binaryExponent = exponentNegative ? -exponentValue : exponentValue;
                        cursor = exponentCursor;
                    }
                }
                return { value: signed(hexFloatValue(mantissa, binaryExponent - 4 * fractionDigits)), end: cursor };
            }
            // "0x" without hex digits scans as "0".
            return { value: signed(0), end: index + 1 };
        }

        if (matchWordAt(text, index, 'inf')) {
            const end = matchWordAt(text, index, 'infinity') ? index + 8 : index + 3;
            return { value: signed(Infinity), end };
        }
        if (matchWordAt(text, index, 'nan')) {
            let end = index + 3;
            if (text.charCodeAt(end) === 0x28) {
                const close = text.indexOf(')', end);
                if (close >= 0)
                    end = close + 1;
            }
            return { value: NaN, end };
        }

        let cursor = index;
        let digitCount = 0;
        while (isDigitCode(text.charCodeAt(cursor))) {
            cursor++;
            digitCount++;
        }
        if (text.charCodeAt(cursor) === 0x2e) {
            cursor++;
            while (isDigitCode(text.charCodeAt(cursor))) {
                cursor++;
                digitCount++;
            }
        }
        if (!digitCount)
            return { value: 0, end: start };
        if ((text.charCodeAt(cursor) | 0x20) === 0x65) {
            let exponentCursor = cursor + 1;
            const exponentSign = text.charCodeAt(exponentCursor);
            if (exponentSign === 0x2b || exponentSign === 0x2d)
                exponentCursor++;
            if (isDigitCode(text.charCodeAt(exponentCursor))) {
                while (isDigitCode(text.charCodeAt(exponentCursor)))
                    exponentCursor++;
                cursor = exponentCursor;
            }
        }
        return { value: signed(Number(text.slice(index, cursor))), end: cursor };
    }

    function rectFromString(string)
    {
        const values = [0, 0, 0, 0];
        const nul = string.indexOf('\0');
        const text = nul < 0 ? string : string.slice(0, nul);
        let position = 0;
        for (let i = 0; i < 4; ++i) {
            let cursor = position;
            let code = cursor < text.length ? text.charCodeAt(cursor) : 0;
            if (code && !isDigitCode(code)) {
                while (!(code === 0x2b || code === 0x2d || code === 0x2e)) {
                    cursor++;
                    code = cursor < text.length ? text.charCodeAt(cursor) : 0;
                    if (!code || isDigitCode(code))
                        break;
                }
            }
            const scanned = strtod(text, cursor);
            values[i] = scanned.value;
            position = scanned.end;
        }
        return makeRect(values[0], values[1], values[2], values[3]);
    }

    // -[NSNumber floatValue] on property-list numbers.

    function isPropertyListNumber(value)
    {
        return typeof value === 'number' || typeof value === 'boolean';
    }

    function floatValue(value)
    {
        return f32(Number(value));
    }

    function isDictionary(value)
    {
        return value !== null && typeof value === 'object' && !Array.isArray(value);
    }

    // NSString -isEqualToString: with a receiver or argument that may be nil.
    function stringsEqual(a, b)
    {
        return a !== null && b !== null && a === b;
    }

    // DOM access.

    function isElementNode(node)
    {
        return node.nodeType === 1;
    }

    function isHTMLElement(node)
    {
        return !!node && node instanceof HTMLElement;
    }

    function enclosingIntRect(clientRect, scrollX, scrollY)
    {
        const x = Math.floor(clientRect.left + scrollX);
        const y = Math.floor(clientRect.top + scrollY);
        return makeRect(x, y, Math.ceil(clientRect.right + scrollX) - x, Math.ceil(clientRect.bottom + scrollY) - y);
    }

    function isEmptyIntRect(rect)
    {
        return rect.width <= 0 || rect.height <= 0;
    }

    function createMeasurer()
    {
        const scrollX = window.scrollX;
        const scrollY = window.scrollY;
        const cache = new Map();
        return function boundingBox(element) {
            let box = cache.get(element);
            if (box)
                return box;
            const fragments = element.getClientRects();
            if (!fragments.length)
                box = kZeroRect;
            else {
                box = enclosingIntRect(fragments[0], scrollX, scrollY);
                for (let i = 1; i < fragments.length; ++i) {
                    const fragment = enclosingIntRect(fragments[i], scrollX, scrollY);
                    if (isEmptyIntRect(fragment))
                        continue;
                    if (isEmptyIntRect(box)) {
                        box = fragment;
                        continue;
                    }
                    const minX = Math.min(box.x, fragment.x);
                    const minY = Math.min(box.y, fragment.y);
                    const maxX = Math.max(box.x + box.width, fragment.x + fragment.width);
                    const maxY = Math.max(box.y + box.height, fragment.y + fragment.height);
                    box = makeRect(minX, minY, maxX - minX, maxY - minY);
                }
            }
            cache.set(element, box);
            return box;
        };
    }

    // Visits root and its descendants in document order, the order of a recursion over
    // -childNodes.
    function forEachNode(root, visit)
    {
        let node = root;
        while (node) {
            visit(node);
            if (node.firstChild) {
                node = node.firstChild;
                continue;
            }
            while (node !== root && !node.nextSibling)
                node = node.parentNode;
            if (node === root)
                return;
            node = node.nextSibling;
        }
    }

    function childElements(element)
    {
        const elements = [];
        for (let child = element.firstChild; child; child = child.nextSibling) {
            if (isHTMLElement(child))
                elements.push(child);
        }
        return elements;
    }

    function siblingElements(element)
    {
        const elements = [];
        for (let sibling = element.previousSibling; sibling; sibling = sibling.previousSibling) {
            if (isHTMLElement(sibling))
                elements.push(sibling);
        }
        for (let sibling = element.nextSibling; sibling; sibling = sibling.nextSibling) {
            if (isHTMLElement(sibling))
                elements.push(sibling);
        }
        return elements;
    }

    // DOMNode(DOMNodeExtras).

    function sizeIsReasonable(box)
    {
        const area = box.width * box.height;
        if (2500 > area)
            return false;
        if (900 > box.width)
            return true;
        return 900 > box.height;
    }

    // BoxedDOMElement.

    function boxedElementFromDOMElement(element)
    {
        return {
            tagName: element.tagName,
            idName: element.getAttribute('id') ?? '',
            className: element.getAttribute('class') ?? '',
        };
    }

    function boxedElementFromDictionary(dictionary)
    {
        const boxed = { tagName: null, idName: null, className: null };
        const idName = dictionary[kBoxedDOMElementIDNameKey];
        if (typeof idName === 'string')
            boxed.idName = idName;
        const className = dictionary[kBoxedDOMElementClassNameKey];
        if (typeof className === 'string')
            boxed.className = className;
        const tagName = dictionary[kBoxedDOMElementTagNameKey];
        if (typeof tagName === 'string')
            boxed.tagName = tagName;
        return boxed;
    }

    // ClipSignature.

    function adjustRectByBorderOffset(rect, offset)
    {
        return makeRect(
            rect.x - offset.left,
            rect.y - offset.top,
            rect.width + f32(offset.right + offset.left),
            rect.height + f32(offset.bottom + offset.top));
    }

    function signatureFromDictionary(dictionary)
    {
        const signature = {
            boxedElement: null,
            boxedParent: null,
            boxedChildren: null,
            boxedSiblings: null,
            borderOffset: { top: 0, bottom: 0, left: 0, right: 0 },
            originalBorderRect: kZeroRect,
            scrollOffset: { x: 0, y: 0 },
            // For a signature Safari made, how far Safari had scrolled the boxes, outermost first.
            boxScrolls: null,
        };
        const element = dictionary[kClipSignatureElementKey];
        if (isDictionary(element))
            signature.boxedElement = boxedElementFromDictionary(element);
        const parent = dictionary[kClipSignatureParentElementKey];
        if (isDictionary(parent))
            signature.boxedParent = boxedElementFromDictionary(parent);
        const children = dictionary[kClipSignatureChildrenKey];
        if (Array.isArray(children))
            signature.boxedChildren = children.filter(isDictionary).map(boxedElementFromDictionary);
        const siblings = dictionary[kClipSignatureSiblingsKey];
        if (Array.isArray(siblings))
            signature.boxedSiblings = siblings.filter(isDictionary).map(boxedElementFromDictionary);
        const top = dictionary[kClipSignatureBorderOffsetTopKey];
        if (isPropertyListNumber(top))
            signature.borderOffset.top = floatValue(top);
        const bottom = dictionary[kClipSignatureBorderOffsetBottomKey];
        if (isPropertyListNumber(bottom))
            signature.borderOffset.bottom = floatValue(bottom);
        const left = dictionary[kClipSignatureBorderOffsetLeftKey];
        if (isPropertyListNumber(left))
            signature.borderOffset.left = floatValue(left);
        const right = dictionary[kClipSignatureBorderOffsetRightKey];
        if (isPropertyListNumber(right))
            signature.borderOffset.right = floatValue(right);
        const originalBorderRect = dictionary[kClipSignatureOriginalBorderRectKey];
        if (typeof originalBorderRect === 'string')
            signature.originalBorderRect = rectFromString(originalBorderRect);
        const scrollOffsetX = dictionary[kClipSignatureScrollOffsetXKey];
        if (isPropertyListNumber(scrollOffsetX))
            signature.scrollOffset.x = floatValue(scrollOffsetX);
        const scrollOffsetY = dictionary[kClipSignatureScrollOffsetYKey];
        if (isPropertyListNumber(scrollOffsetY))
            signature.scrollOffset.y = floatValue(scrollOffsetY);
        return signature;
    }

    // DOMBorderFinder.

    function scoreOfBoxedElement(boxed, otherBoxed)
    {
        if (!stringsEqual(boxed.tagName, otherBoxed.tagName))
            return 0;
        const idNamesMatch = stringsEqual(boxed.idName, otherBoxed.idName);
        const classNamesMatch = stringsEqual(boxed.className, otherBoxed.className);
        return ((idNamesMatch ? 2 : 0) | (classNamesMatch ? 1 : 0)) + 1;
    }

    function scoreOfBoxedElements(boxedElements, otherBoxedElements)
    {
        const count = boxedElements ? boxedElements.length : 0;
        const otherCount = otherBoxedElements ? otherBoxedElements.length : 0;
        let score = count === otherCount ? 1 : 0;
        for (let i = 0; i < count; ++i) {
            for (let j = 0; j < otherCount; ++j) {
                const elementScore = scoreOfBoxedElement(otherBoxedElements[j], boxedElements[i]);
                if (elementScore) {
                    score = (score + elementScore) >>> 0;
                    break;
                }
            }
        }
        return score;
    }

    function scoreRectAgainstRect(rect, otherRect)
    {
        const area = f32(rect.width * rect.height);
        const otherArea = f32(otherRect.width * otherRect.height);
        const largerArea = otherArea > area ? otherArea : area;
        const smallerArea = area < otherArea ? area : otherArea;
        const areaRatio = f32(smallerArea / largerArea);
        const areaScore = areaRatio >= 0.9 && !(1.1 < areaRatio) ? 1 : 0;

        const largerX = otherRect.x > rect.x ? otherRect.x : rect.x;
        const smallerX = rect.x < otherRect.x ? rect.x : otherRect.x;
        const xRatio = f32(smallerX / largerX);
        if (!(xRatio >= 0.9) || !(1.1 >= xRatio))
            return areaScore;

        const largerY = otherRect.y > rect.y ? otherRect.y : rect.y;
        const smallerY = rect.y < otherRect.y ? rect.y : otherRect.y;
        const yRatio = f32(smallerY / largerY);
        const positionScore = yRatio >= 0.9 && !(1.1 < yRatio) ? 1 : 0;
        return areaScore + positionScore;
    }

    // -siblingElements scored against the signature's siblings without building the list: each
    // signature sibling scores against the first sibling with its tag name, in -siblingElements
    // order, and the list's length is the parent's HTML child count less the element itself.
    function scoreOfSiblingElements(finder, boxedSiblings, element)
    {
        const count = boxedSiblings ? boxedSiblings.length : 0;
        let score = count === finder.htmlChildCount(element.parentNode) - 1 ? 1 : 0;
        for (let i = 0; i < count; ++i) {
            const tagName = boxedSiblings[i].tagName;
            if (tagName === null)
                continue;
            let sibling = element.previousSibling;
            while (sibling && !(isHTMLElement(sibling) && sibling.tagName === tagName))
                sibling = sibling.previousSibling;
            if (!sibling) {
                sibling = element.nextSibling;
                while (sibling && !(isHTMLElement(sibling) && sibling.tagName === tagName))
                    sibling = sibling.nextSibling;
            }
            if (sibling)
                score = (score + scoreOfBoxedElement(finder.boxedElement(sibling), boxedSiblings[i])) >>> 0;
        }
        return score;
    }

    function createBorderFinder()
    {
        const boxedElements = new Map();
        const htmlChildCounts = new Map();
        return {
            foundBorderElements: [],
            highestScore: 0,
            boundingBox: createMeasurer(),
            scrollingAncestors: createScrollingAncestorsMeasurer(),
            boxedElement(element) {
                let boxed = boxedElements.get(element);
                if (!boxed) {
                    boxed = boxedElementFromDOMElement(element);
                    boxedElements.set(element, boxed);
                }
                return boxed;
            },
            htmlChildCount(parent) {
                let count = htmlChildCounts.get(parent);
                if (count === undefined) {
                    count = childElements(parent).length;
                    htmlChildCounts.set(parent, count);
                }
                return count;
            },
        };
    }

    function setScoreForElement(finder, element, score)
    {
        if (finder.highestScore < score) {
            finder.highestScore = score;
            finder.foundBorderElements = [element];
        } else if (finder.highestScore === score)
            finder.foundBorderElements.push(element);
    }

    // The score scoreOfBoxedElement gives an element of the signed element's kind: its tag, id and class.
    const kSameKindScore = 4;

    function scoreNodeAgainstSignature(finder, node, signature, sameKind)
    {
        if (!isHTMLElement(node))
            return;
        const signatureElement = signature.boxedElement;
        if (!signatureElement || !stringsEqual(node.tagName, signatureElement.tagName))
            return;
        if (sameKind && scoreOfBoxedElement(finder.boxedElement(node), signatureElement) !== kSameKindScore)
            return;
        if (!sizeIsReasonable(finder.boundingBox(node)))
            return;
        const childrenScore = scoreOfBoxedElements(signature.boxedChildren, childElements(node).map(finder.boxedElement));
        const siblingsScore = scoreOfSiblingElements(finder, signature.boxedSiblings, node);
        let score = (siblingsScore + childrenScore) >>> 0;
        score = (scoreOfBoxedElement(finder.boxedElement(node), signatureElement) + score) >>> 0;
        const adjustedRect = adjustRectByBorderOffset(finder.boundingBox(node), signature.borderOffset);
        score = (score + scoreRectAgainstRect(signedPlace(node, adjustedRect, signature, finder.scrollingAncestors), signature.originalBorderRect)) >>> 0;
        setScoreForElement(finder, node, score);
    }

    function findBorderElementForSignature(finder, signature, sameKind)
    {
        forEachNode(document, node => scoreNodeAgainstSignature(finder, node, signature, sameKind));
    }

    // -[DOMBorderFinder borderRectForSignature:] for every element that earns the best score: their rects,
    // adjusted by the signature's border offset, and the score. Alike elements, the parts a page repeats,
    // can share the best score; the likeliest of them is the one whose parent best matches the signed
    // element's parent, and of those, the one nearest where the signed element was. With sameKind, only
    // elements of the signed element's kind are scored.
    function bestMatches(signature, sameKind)
    {
        const finder = createBorderFinder();
        findBorderElementForSignature(finder, signature, sameKind);
        const elements = finder.foundBorderElements;
        const rectOf = element => adjustRectByBorderOffset(finder.boundingBox(element), signature.borderOffset);
        const parentScore = element => signature.boxedParent && isHTMLElement(element.parentNode) ? scoreOfBoxedElement(finder.boxedElement(element.parentNode), signature.boxedParent) : 0;
        const original = signature.originalBorderRect;
        const distance = candidate => Math.hypot(candidate.place.x - original.x, candidate.place.y - original.y);
        let likeliest = null;
        for (const element of elements) {
            const rect = rectOf(element);
            const candidate = { element, rect, place: signedPlace(element, rect, signature, finder.scrollingAncestors), parentScore: parentScore(element) };
            if (!likeliest || candidate.parentScore > likeliest.parentScore || (candidate.parentScore === likeliest.parentScore && distance(candidate) < distance(likeliest)))
                likeliest = candidate;
        }
        return {
            elements,
            rects: elements.map(rectOf),
            likeliest: likeliest ? likeliest.rect : null,
            likeliestElement: likeliest ? likeliest.element : null,
            score: finder.highestScore,
        };
    }

    // The boxes an element scrolls within, nearest first, for a pass over a document that does not change
    // during it: each box is looked at once however many elements it holds.
    function createScrollingAncestorsMeasurer()
    {
        const boxesHolding = new Map();
        function boxesAt(ancestor)
        {
            if (!ancestor || ancestor === document.body || ancestor === document.documentElement)
                return [];
            let boxes = boxesHolding.get(ancestor);
            if (!boxes) {
                const outer = boxesAt(ancestor.parentElement);
                boxes = ancestor.scrollHeight > ancestor.clientHeight && /^(auto|scroll)$/.test(getComputedStyle(ancestor).overflowY) ? [ancestor, ...outer] : outer;
                boxesHolding.set(ancestor, boxes);
            }
            return boxes;
        }
        return element => boxesAt(element.parentElement);
    }

    function scrollingAncestors(element)
    {
        return createScrollingAncestorsMeasurer()(element);
    }

    // Pages scroll their content in boxes of their own as well as in the document, and a page loads with
    // those boxes at their start. An element's rect lands at the clip's place in the viewport once the
    // document scrolls as far as it can toward it and the boxes the element lies in scroll the rest:
    // the rect it then has, and those boxes' scroll offsets.
    function revealPlan(element, rect, viewportOrigin)
    {
        if (!viewportOrigin || !element)
            return { element, rect, scrolls: [] };
        const scrollingElement = document.scrollingElement || document.documentElement;
        const maximumScrollY = Math.max(0, scrollingElement.scrollHeight - window.innerHeight);
        const documentScrollY = Math.min(Math.max(0, rect.y - viewportOrigin.y), maximumScrollY);
        let remaining = rect.y - documentScrollY - viewportOrigin.y;
        let y = rect.y;
        const scrolls = [];
        for (const scroller of scrollingAncestors(element)) {
            if (!remaining)
                break;
            const scrollTop = Math.min(Math.max(0, scroller.scrollTop + remaining), scroller.scrollHeight - scroller.clientHeight);
            const moved = scrollTop - scroller.scrollTop;
            if (!moved)
                continue;
            scrolls.push({ scroller, scrollTop });
            remaining -= moved;
            y -= moved;
        }
        return { element, rect: makeRect(rect.x, y, rect.width, rect.height), scrolls };
    }

    // How far the boxes an element scrolls within are scrolled, together.
    function scrollOffsets(element, ancestorsOf = createScrollingAncestorsMeasurer())
    {
        let x = 0;
        let y = 0;
        for (const scroller of ancestorsOf(element)) {
            x += scroller.scrollLeft;
            y += scroller.scrollTop;
        }
        return { x, y };
    }

    // The element's rect with the boxes it scrolls within scrolled as far as Safari had them, given
    // outermost first, and those boxes' scroll offsets.
    function safariScrollPlan(element, rect, boxScrolls, ancestorsOf = createScrollingAncestorsMeasurer())
    {
        const scrollers = ancestorsOf(element).slice().reverse();
        const scrolls = [];
        let y = rect.y;
        scrollers.forEach((scroller, index) => {
            if (index >= boxScrolls.length)
                return;
            const scrollTop = Math.min(Math.max(0, boxScrolls[index]), scroller.scrollHeight - scroller.clientHeight);
            scrolls.push({ scroller, scrollTop });
            y -= scrollTop - scroller.scrollTop;
        });
        return { element, rect: makeRect(rect.x, y, rect.width, rect.height), scrolls };
    }

    // Where the element's rect lies with the boxes it scrolls within scrolled as they were when the
    // signature's element was signed: as Safari had them for a signature Safari made, and by the signed
    // offset for the clip's own.
    function signedPlace(element, rect, signature, ancestorsOf = createScrollingAncestorsMeasurer())
    {
        if (signature.boxScrolls)
            return safariScrollPlan(element, rect, signature.boxScrolls, ancestorsOf).rect;
        const scroll = scrollOffsets(element, ancestorsOf);
        return makeRect(rect.x + scroll.x - signature.scrollOffset.x, rect.y + scroll.y - signature.scrollOffset.y, rect.width, rect.height);
    }

    // Whether the element lies where the signature's element did.
    function liesAtSignedPlace(element, rect, signature)
    {
        const place = signedPlace(element, rect, signature);
        const original = signature.originalBorderRect;
        return Math.abs(place.x - original.x) < 0.5 && Math.abs(place.y - original.y) < 0.5;
    }

    // The element placement put at the clip's place, as it then lay, which the follower starts from: by
    // the time it starts, the page may have scrolled the boxes the element lies in again.
    let lastPlacement = null;

    function applyReveal(plan)
    {
        for (const { scroller, scrollTop } of plan.scrolls)
            scroller.scrollTop = scrollTop;
        lastPlacement = plan.element ? { element: plan.element, rect: plan.rect, offset: layoutOffset(plan.element), scroll: scrollOffsets(plan.element), signature: signatureForElement(plan.element, plan.rect) } : null;
        return plan.rect;
    }

    function hasOrigin(rect, origin)
    {
        return rect.x === origin.x && rect.y === origin.y;
    }

    function publicRect(rect)
    {
        return isZeroRect(rect) ? null : makeRect(rect.x, rect.y, rect.width, rect.height);
    }

    // DOMNode -matchesRect:betterThanNode:. A node matches a rect better than the current candidate
    // when a larger share of its box lies in the rect, or the same share of a larger box: the element
    // a rect was drawn around lies wholly in it and is the largest that does. With no candidate yet,
    // any node with part of its box in the rect matches.
    function matchesRectBetterThan(finder, node, rect, other)
    {
        const box = finder.boundingBox(node);
        const intersection = intersectRects(rect, box);
        if (isZeroRect(intersection))
            return false;
        const area = f32(box.width * box.height);
        const ratio = f32((intersection.width * intersection.height) / area);
        if (!(ratio > 0))
            return false;
        if (!other)
            return true;
        const otherBox = finder.boundingBox(other);
        const otherArea = f32(otherBox.width * otherBox.height);
        const otherIntersection = intersectRects(rect, otherBox);
        const otherRatio = f32((otherIntersection.width * otherIntersection.height) / otherArea);
        return ratio > otherRatio || (ratio === otherRatio && area >= otherArea);
    }

    // NSIntersectionRect.
    function intersectRects(a, b)
    {
        const left = Math.max(a.x, b.x);
        const top = Math.max(a.y, b.y);
        const right = Math.min(a.x + a.width, b.x + b.width);
        const bottom = Math.min(a.y + a.height, b.y + b.height);
        if (right <= left || bottom <= top)
            return kZeroRect;
        return makeRect(left, top, right - left, bottom - top);
    }

    // -[DOMBorderFinder _findDOMBorderForCropRect:node:]: the node in document order that matches
    // the rect best.
    function findBorderElementForRect(finder, rect)
    {
        let borderElement = null;
        forEachNode(document, node => {
            if (isHTMLElement(node) && sizeIsReasonable(finder.boundingBox(node)) && matchesRectBetterThan(finder, node, rect, borderElement))
                borderElement = node;
        });
        return borderElement;
    }

    // NSStringFromRect.
    function stringFromRect(rect)
    {
        return '{{' + rect.x + ', ' + rect.y + '}, {' + rect.width + ', ' + rect.height + '}}';
    }

    // -[BoxedDOMElement dictionaryRepresentation]: a missing name is the empty string.
    function dictionaryFromBoxedElement(boxed)
    {
        const dictionary = {};
        dictionary[kBoxedDOMElementTagNameKey] = boxed.tagName ?? '';
        dictionary[kBoxedDOMElementIDNameKey] = boxed.idName ?? '';
        dictionary[kBoxedDOMElementClassNameKey] = boxed.className ?? '';
        return dictionary;
    }

    // -[DOMBorderFinder signatureForBorderRect:] and -[ClipSignature initWithClippedElement:
    // originalBorderRect:], as a dictionary in -[ClipSignature dictionaryRepresentation]'s form. The
    // signature describes the element that best matches the rect, how its box lies in the rect, and
    // its children, siblings and parent; its score is the score that element earns against it.
    function signatureForRect(rect)
    {
        return signatureForElement(findBorderElementForRect(createBorderFinder(), rect), rect);
    }

    function signatureForElement(element, rect)
    {
        if (!element)
            return null;
        const box = createMeasurer()(element);
        const dictionary = {};
        dictionary[kClipSignatureElementKey] = dictionaryFromBoxedElement(boxedElementFromDOMElement(element));
        if (isHTMLElement(element.parentNode))
            dictionary[kClipSignatureParentElementKey] = dictionaryFromBoxedElement(boxedElementFromDOMElement(element.parentNode));
        const children = childElements(element);
        if (children.length)
            dictionary[kClipSignatureChildrenKey] = children.map(child => dictionaryFromBoxedElement(boxedElementFromDOMElement(child)));
        const siblings = siblingElements(element);
        if (siblings.length)
            dictionary[kClipSignatureSiblingsKey] = siblings.map(sibling => dictionaryFromBoxedElement(boxedElementFromDOMElement(sibling)));
        dictionary[kClipSignatureBorderOffsetTopKey] = f32(box.y - rect.y);
        dictionary[kClipSignatureBorderOffsetBottomKey] = f32((rect.y + rect.height) - (box.y + box.height));
        dictionary[kClipSignatureBorderOffsetLeftKey] = f32(box.x - rect.x);
        dictionary[kClipSignatureBorderOffsetRightKey] = f32((rect.x + rect.width) - (box.x + box.width));
        dictionary[kClipSignatureOriginalBorderRectKey] = stringFromRect(rect);
        const scroll = scrollOffsets(element);
        if (scroll.x || scroll.y) {
            dictionary[kClipSignatureScrollOffsetXKey] = f32(scroll.x);
            dictionary[kClipSignatureScrollOffsetYKey] = f32(scroll.y);
        }

        // The score the element earns against its own signature, unless another element earns more.
        const scoring = createBorderFinder();
        findBorderElementForSignature(scoring, signatureFromDictionary(dictionary));
        if (scoring.foundBorderElements.includes(element))
            dictionary[kClipSignatureScoreKey] = scoring.highestScore;
        return dictionary;
    }

    // Runs test as the document changes, at most once a frame, until it has a result; at the deadline,
    // test's result stands.
    function whenDocumentChanges(test, deadline)
    {
        return new Promise(resolve => {
            let scheduled = false;
            let observer = null;
            let timer = 0;
            function finish(result)
            {
                observer.disconnect();
                clearTimeout(timer);
                resolve(result);
            }
            function check()
            {
                scheduled = false;
                const result = test(false);
                if (result)
                    finish(result);
            }
            observer = new MutationObserver(() => {
                if (scheduled)
                    return;
                scheduled = true;
                requestAnimationFrame(check);
            });
            const immediate = test(false);
            if (immediate) {
                resolve(immediate);
                return;
            }
            observer.observe(document, { childList: true, subtree: true, attributes: true, characterData: true });
            timer = setTimeout(() => finish(test(true)), deadline);
        });
    }

    // The rect of the element a signature describes. The page settles after its load: script builds and
    // rebuilds parts of the document. The element is present once an element earning the signed
    // element's score lies where it was. At the deadline, the page has moved it, and it is the likeliest
    // of the elements of its kind.
    function placeBySignature(argument)
    {
        const signature = signatureFromDictionary(argument.signature);
        const score = argument.signature[kClipSignatureScoreKey];
        const viewportOrigin = argument.viewportOrigin;
        return whenDocumentChanges(atDeadline => {
            const matches = bestMatches(signature);
            const index = matches.elements.findIndex((element, i) => liesAtSignedPlace(element, matches.rects[i], signature));
            if (index >= 0 && (atDeadline || matches.score >= score))
                return { rect: publicRect(applyReveal(revealPlan(matches.elements[index], matches.rects[index], viewportOrigin))) };
            if (!atDeadline)
                return null;
            const kind = bestMatches(signature, true);
            if (!kind.likeliestElement)
                return { rect: null };
            return { rect: publicRect(applyReveal(revealPlan(kind.likeliestElement, kind.likeliest, viewportOrigin))) };
        }, argument.deadline);
    }

    // A signature for the clip's rect in the page.
    function signRect(rect)
    {
        return signatureForRect(makeRect(rect.x, rect.y, rect.width, rect.height));
    }

    // A signature for the clip's rect in the page once the element Safari signed lies there. Both
    // origins are whole pixels: element boxes are enclosing integer rects here and in Safari, whose
    // border offsets and scroll offset are whole pixels too. The page lays out apart from Safari's: its
    // ads, experiments and extensions differ. At the deadline, the element Safari signed is the likeliest
    // of the elements of its kind, wherever it lies, and the clip moves to it.
    function signRectWhenPresent(argument)
    {
        const safariSignature = argument.signature ? signatureFromDictionary(argument.signature) : null;
        const rect = makeRect(argument.rect.x, argument.rect.y, argument.rect.width, argument.rect.height);
        const viewportOrigin = argument.viewportOrigin;
        const boxScrolls = Array.isArray(argument.boxScrolls) ? argument.boxScrolls : [];
        if (safariSignature)
            safariSignature.boxScrolls = boxScrolls;
        return whenDocumentChanges(atDeadline => {
            const matches = safariSignature ? bestMatches(safariSignature) : null;
            if (!matches)
                return { signature: signatureForRect(rect) };
            const inPlace = matches.elements.map((element, index) => safariScrollPlan(element, matches.rects[index], boxScrolls)).find(plan => hasOrigin(plan.rect, rect));
            if (inPlace) {
                applyReveal(inPlace);
                return { signature: signatureForRect(rect) };
            }
            if (!atDeadline)
                return null;
            const kind = bestMatches(safariSignature, true);
            if (kind.likeliestElement) {
                const revealed = applyReveal(revealPlan(kind.likeliestElement, kind.likeliest, viewportOrigin));
                return { rect: publicRect(revealed), signature: signatureForRect(revealed) };
            }
            return { signature: signatureForRect(rect) };
        }, argument.deadline);
    }

    // After the load, script goes on changing the page: it puts content above the clip's element,
    // renders the element again, resizes what holds it and scrolls the boxes it lies in. The clip follows
    // the element's place in the layout, which transforms and animations of its box leave alone, and the
    // boxes it scrolls within are scrolled back to show it; the element is found again among the
    // elements of its kind when script replaces it, and the clip stays where it is while there is none.
    // The place is measured at most once a frame, and a missing element is looked for at most once a
    // second.
    let clipFollower = null;
    const kClipElementSearchInterval = 1000;

    // The element's offset in the document's layout, through its offset parents.
    function layoutOffset(element)
    {
        let x = 0;
        let y = 0;
        for (let ancestor = element; ancestor; ancestor = ancestor.offsetParent) {
            x += ancestor.offsetLeft;
            y += ancestor.offsetTop;
        }
        return { x, y };
    }

    function followClipElement(argument)
    {
        stopFollowingClipElement();
        const rect = makeRect(argument.x, argument.y, argument.width, argument.height);
        const placement = lastPlacement && lastPlacement.element.isConnected && hasOrigin(lastPlacement.rect, rect) ? lastPlacement : null;
        const signature = placement ? placement.signature : signatureForRect(rect);
        if (!signature)
            return false;
        const parsedSignature = signatureFromDictionary(signature);
        const follower = {
            element: null,
            viewportOrigin: argument.viewportOrigin,
            // The clip's place, and the element's layout offset and the scroll of the boxes it lies in,
            // when the clip took that place.
            basePlace: null,
            baseOffset: null,
            baseScroll: null,
            place: { x: rect.x, y: rect.y },
            userScrolled: false,
            scheduled: false,
            nextSearch: 0,
            searchTimer: 0,
        };
        function takeElement(element, place, offset, scroll)
        {
            follower.element = element;
            follower.basePlace = place;
            follower.baseOffset = offset || (element ? layoutOffset(element) : null);
            follower.baseScroll = scroll || (element ? scrollOffsets(element) : null);
        }
        // The element's place now, with the boxes it lies in scrolled to bring it to the clip's place in
        // the viewport as far as the document's scroll cannot.
        function placeOfElement()
        {
            const element = follower.element;
            if (element && element.isConnected) {
                if (!element.getClientRects().length)
                    return null;
                const offset = layoutOffset(element);
                const scroll = scrollOffsets(element);
                const x = follower.basePlace.x + offset.x - follower.baseOffset.x - (scroll.x - follower.baseScroll.x);
                const y = follower.basePlace.y + offset.y - follower.baseOffset.y - (scroll.y - follower.baseScroll.y);
                const placed = applyReveal(revealPlan(element, makeRect(x, y, rect.width, rect.height), follower.viewportOrigin));
                return { x: placed.x, y: placed.y };
            }
            follower.element = null;
            const now = performance.now();
            if (now < follower.nextSearch) {
                if (!follower.searchTimer)
                    follower.searchTimer = setTimeout(() => { follower.searchTimer = 0; schedule(); }, follower.nextSearch - now);
                return null;
            }
            follower.nextSearch = now + kClipElementSearchInterval;
            const kind = bestMatches(parsedSignature, true);
            if (!kind.likeliestElement)
                return null;
            const placed = applyReveal(revealPlan(kind.likeliestElement, kind.likeliest, follower.viewportOrigin));
            takeElement(kind.likeliestElement, { x: placed.x, y: placed.y });
            return { x: placed.x, y: placed.y };
        }
        function check()
        {
            follower.scheduled = false;
            if (clipFollower !== follower || follower.userScrolled)
                return;
            const place = placeOfElement();
            if (!place || (place.x === follower.place.x && place.y === follower.place.y))
                return;
            follower.place = place;
            postToPlugIn({ type: 'clipElementMoved', x: place.x, y: place.y });
        }
        function schedule()
        {
            if (follower.scheduled)
                return;
            follower.scheduled = true;
            requestAnimationFrame(check);
        }
        // A box the user scrolls in the clip stays where the user puts it.
        function userScroll(event)
        {
            if (follower.element && scrollingAncestors(follower.element).some(scroller => scroller.contains(event.target)))
                follower.userScrolled = true;
        }
        if (placement)
            takeElement(placement.element, { x: rect.x, y: rect.y }, placement.offset, placement.scroll);
        else
            takeElement(findBorderElementForRect(createBorderFinder(), rect), { x: rect.x, y: rect.y });
        const mutationObserver = new MutationObserver(schedule);
        mutationObserver.observe(document, { childList: true, subtree: true, attributes: true, characterData: true });
        const resizeObserver = new ResizeObserver(schedule);
        resizeObserver.observe(document.documentElement);
        window.addEventListener('resize', schedule);
        window.addEventListener('wheel', userScroll, { capture: true, passive: true });
        window.addEventListener('keydown', userScroll, true);
        follower.stop = () => {
            mutationObserver.disconnect();
            resizeObserver.disconnect();
            window.removeEventListener('resize', schedule);
            window.removeEventListener('wheel', userScroll, { capture: true, passive: true });
            window.removeEventListener('keydown', userScroll, true);
            clearTimeout(follower.searchTimer);
        };
        clipFollower = follower;
        schedule();
        return true;
    }

    function stopFollowingClipElement()
    {
        if (!clipFollower)
            return;
        clipFollower.stop();
        clipFollower = null;
    }

    // Whether a video or audio element whose box meets the rect is playing; an audio element has no box,
    // and plays for the whole page.
    function isPlayingMediaInRect(argument)
    {
        const rect = makeRect(argument.x, argument.y, argument.width, argument.height);
        const boundingBox = createMeasurer();
        return Array.prototype.some.call(document.querySelectorAll('video, audio'), media => !media.paused && !media.ended && (media.localName === 'audio' || !isZeroRect(intersectRects(boundingBox(media), rect))));
    }

    // Resolves once no image whose box meets the rect is still loading, or at the deadline. Pages load
    // images after their load event, and script puts images in place of placeholders, so this is
    // checked as images load and as the document changes.
    function whenImagesInRectLoad(argument)
    {
        const rect = makeRect(argument.rect.x, argument.rect.y, argument.rect.width, argument.rect.height);
        const isLoading = () => {
            const boundingBox = createMeasurer();
            return Array.prototype.some.call(document.images, image => !image.complete && !isZeroRect(intersectRects(boundingBox(image), rect)));
        };
        return new Promise(resolve => {
            let scheduled = false;
            let observer = null;
            let timer = 0;
            function finish()
            {
                observer.disconnect();
                document.removeEventListener('load', schedule, true);
                document.removeEventListener('error', schedule, true);
                clearTimeout(timer);
                resolve(true);
            }
            function check()
            {
                scheduled = false;
                if (!isLoading())
                    finish();
            }
            function schedule()
            {
                if (scheduled)
                    return;
                scheduled = true;
                requestAnimationFrame(check);
            }
            if (!isLoading()) {
                resolve(true);
                return;
            }
            observer = new MutationObserver(schedule);
            observer.observe(document, { childList: true, subtree: true, attributes: true });
            document.addEventListener('load', schedule, true);
            document.addEventListener('error', schedule, true);
            timer = setTimeout(finish, argument.deadline);
        });
    }

    // Snapper.

    function snapNodes()
    {
        const boundingBox = createMeasurer();
        const nodes = [];
        forEachNode(document, node => {
            if (!isElementNode(node) || !kSnapTags.includes(node.tagName))
                return;
            const box = boundingBox(node);
            const area = box.width * box.height;
            if (2500 > area)
                return;
            if (box.height > 900 || box.width > 900)
                return;
            nodes.push({ id: nodes.length, x: box.x, y: box.y, width: box.width, height: box.height });
        });
        return nodes;
    }

    function draggableRects()
    {
        const boundingBox = createMeasurer();
        const rects = [];
        forEachNode(document, node => {
            if (!isElementNode(node) || !kDraggableTags.includes(node.tagName))
                return;
            const box = boundingBox(node);
            if (box.width === 0 && box.height === 0)
                return;
            rects.push(makeRect(box.x, box.y, box.width, box.height));
        });
        return rects;
    }

    // The plug-in places the web view at the page's scroll offset, so it hears of every scroll and of
    // every change to the document's size.
    let reportedScrollX = window.scrollX;
    let reportedScrollY = window.scrollY;
    let reportedDocumentWidth = 0;
    let reportedDocumentHeight = 0;

    function postToPlugIn(message)
    {
        window.webkit.messageHandlers.webClip.postMessage(message);
    }

    function reportScroll()
    {
        if (window.scrollX === reportedScrollX && window.scrollY === reportedScrollY)
            return;
        reportedScrollX = window.scrollX;
        reportedScrollY = window.scrollY;
        postToPlugIn({ type: 'scroll', x: reportedScrollX, y: reportedScrollY });
    }

    function reportDocumentSize()
    {
        const width = document.documentElement.scrollWidth;
        const height = document.documentElement.scrollHeight;
        if (width === reportedDocumentWidth && height === reportedDocumentHeight)
            return;
        reportedDocumentWidth = width;
        reportedDocumentHeight = height;
        postToPlugIn({ type: 'documentSize', width, height });
    }

    function scrollToPoint(point)
    {
        window.scrollTo(point.x, point.y);
        reportedScrollX = window.scrollX;
        reportedScrollY = window.scrollY;
        return { x: reportedScrollX, y: reportedScrollY };
    }

    // The document grows with the body when the root element keeps the viewport's height.
    window.addEventListener('scroll', reportScroll, { passive: true });
    const documentResizeObserver = new ResizeObserver(reportDocumentSize);
    function observeDocumentSize()
    {
        documentResizeObserver.observe(document.documentElement);
        if (document.body)
            documentResizeObserver.observe(document.body);
    }
    if (document.body)
        observeDocumentSize();
    else
        document.addEventListener('DOMContentLoaded', observeDocumentSize, { once: true });

    const api = Object.freeze({
        scrollToPoint,
        placeBySignature,
        signRect,
        signRectWhenPresent,
        whenImagesInRectLoad,
        isPlayingMediaInRect,
        followClipElement,
        stopFollowingClipElement,
        snapNodes,
        draggableRects,
    });
    window.__webClip = api;
})();
