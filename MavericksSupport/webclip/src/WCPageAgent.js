// Web Clip page agent. Runs in an isolated content world of the clip's WKWebView and does
// everything the Web Clip plug-in does with the DOM: collecting the nodes the Snapper snaps to,
// collecting the plug-in elements reported as Dashboard control regions, and scrolling the page.
//
// All rects are in document coordinates as {x, y, width, height}. An element's box is
// WebKit's absolute bounding box: the union of its fragment rects, each widened to whole
// pixels, and a zero rect for an element without boxes.

(function () {
    'use strict';

    const kSnapTags = ['DIV', 'IMG', 'TABLE', 'P', 'OBJECT', 'INPUT'];
    const kDraggableTags = ['OBJECT', 'EMBED', 'APPLET'];

    function makeRect(x, y, width, height)
    {
        return { x, y, width, height };
    }

    const kZeroRect = Object.freeze(makeRect(0, 0, 0, 0));

    // DOM access.

    function isElementNode(node)
    {
        return node.nodeType === 1;
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
        snapNodes,
        draggableRects,
    });
    window.__webClip = api;
})();
