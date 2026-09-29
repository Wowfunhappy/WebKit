// Web Clip page agent. Runs in an isolated content world of the clip's WKWebView and does
// everything the Web Clip plug-in does with the DOM: finding the clipped element from a
// ClipSignature, collecting the nodes the Snapper snaps to, and collecting the plug-in elements
// reported as Dashboard control regions.
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
    const kClipSignatureIndexInDocumentKey = 'ClipSignatureIndexInDocument';

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

    // -[NSNumber floatValue] and -[NSNumber unsignedIntValue] on property-list numbers.

    function isPropertyListNumber(value)
    {
        return typeof value === 'number' || typeof value === 'boolean';
    }

    function floatValue(value)
    {
        return f32(Number(value));
    }

    function unsignedIntValue(value)
    {
        const number = Math.trunc(Number(value));
        if (!Number.isFinite(number) || Math.abs(number) >= 2 ** 63)
            return 0;
        return Number(BigInt.asUintN(32, BigInt(number)));
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
            indexInDocument: 0,
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
        const indexInDocument = dictionary[kClipSignatureIndexInDocumentKey];
        if (isPropertyListNumber(indexInDocument))
            signature.indexInDocument = unsignedIntValue(indexInDocument);
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

    function scoreNodeAgainstSignature(finder, node, signature)
    {
        if (!isHTMLElement(node) || !sizeIsReasonable(finder.boundingBox(node)))
            return;
        const signatureElement = signature.boxedElement;
        if (!signatureElement || !stringsEqual(node.tagName, signatureElement.tagName))
            return;
        const childrenScore = scoreOfBoxedElements(signature.boxedChildren, childElements(node).map(finder.boxedElement));
        const siblingsScore = scoreOfSiblingElements(finder, signature.boxedSiblings, node);
        let score = (siblingsScore + childrenScore) >>> 0;
        score = (scoreOfBoxedElement(finder.boxedElement(node), signatureElement) + score) >>> 0;
        const adjustedRect = adjustRectByBorderOffset(finder.boundingBox(node), signature.borderOffset);
        score = (score + scoreRectAgainstRect(adjustedRect, signature.originalBorderRect)) >>> 0;
        setScoreForElement(finder, node, score);
    }

    function findBorderElementForSignature(finder, signature)
    {
        forEachNode(document, node => scoreNodeAgainstSignature(finder, node, signature));
    }

    // -[DOMBorderFinder borderRectForSignature:]. Returns null where the stock finder returns
    // NSZeroRect or raises.
    function rectForSignature(signatureDictionary)
    {
        if (!isDictionary(signatureDictionary))
            return null;
        const signature = signatureFromDictionary(signatureDictionary);
        const finder = createBorderFinder();
        findBorderElementForSignature(finder, signature);
        const found = finder.foundBorderElements;
        if (!found.length || signature.indexInDocument >= found.length)
            return null;
        return publicRect(adjustRectByBorderOffset(finder.boundingBox(found[signature.indexInDocument]), signature.borderOffset));
    }

    function publicRect(rect)
    {
        return isZeroRect(rect) ? null : makeRect(rect.x, rect.y, rect.width, rect.height);
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

    // -[WebClipper draggableControlRegions], before conversion to control regions.

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

    // The plug-in places the web view at the page's vertical scroll offset, so it hears of every
    // scroll and of every change to the document's height.
    let reportedScrollY = window.scrollY;
    let reportedDocumentHeight = 0;

    function postToPlugIn(message)
    {
        window.webkit.messageHandlers.webClip.postMessage(message);
    }

    function reportScroll()
    {
        if (window.scrollY === reportedScrollY)
            return;
        reportedScrollY = window.scrollY;
        postToPlugIn({ type: 'scroll', y: reportedScrollY });
    }

    function reportDocumentHeight()
    {
        const height = document.documentElement.scrollHeight;
        if (height === reportedDocumentHeight)
            return;
        reportedDocumentHeight = height;
        postToPlugIn({ type: 'documentHeight', height });
    }

    function scrollToY(y)
    {
        window.scrollTo(window.scrollX, y);
        reportedScrollY = window.scrollY;
        return reportedScrollY;
    }

    window.addEventListener('scroll', reportScroll, { passive: true });
    const documentResizeObserver = new ResizeObserver(reportDocumentHeight);
    if (document.documentElement)
        documentResizeObserver.observe(document.documentElement);
    else
        document.addEventListener('DOMContentLoaded', () => documentResizeObserver.observe(document.documentElement), { once: true });

    const api = Object.freeze({
        scrollToY,
        rectForSignature,
        snapNodes,
        draggableRects,
    });
    window.__webClip = api;
})();
