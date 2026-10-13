// Evaluated after Mozilla's Readability.js, in a world of WebKit's own on a page Safari 7's Reader is
// to show. mozillaReadabilityArticleHTMLForSafariReader() returns the markup of the document Safari's
// article finder runs against: the article Readability extracts, as one container of block elements
// under an <h1> title, the layout Safari's finder looks for. It returns null when Readability finds
// no article.

function mozillaReadabilityArticleHTMLForSafariReader()
{
    if (!document.body)
        return null;

    var copy = document.cloneNode(true);
    copyRenderedImageSizes(document, copy);
    var article = new Readability(copy).parse();
    if (!article || !article.content)
        return null;

    var articleDocument = document.implementation.createHTMLDocument(document.title);
    if (article.lang)
        articleDocument.documentElement.lang = article.lang;
    if (article.dir)
        articleDocument.documentElement.dir = article.dir;
    var title = articleDocument.createElement("h1");
    title.textContent = article.title || document.title;
    articleDocument.body.appendChild(title);

    var extracted = articleDocument.createElement("div");
    extracted.innerHTML = article.content;
    resolveFragmentLinks(extracted);
    resolveSourceSizes(extracted);
    var container = flattenedArticle(extracted, articleDocument);
    // Safari's finder takes no element shorter than 295px for an article, however short the article.
    container.style.minHeight = "300px";
    articleDocument.body.appendChild(container);

    return "<!DOCTYPE html>" + articleDocument.documentElement.outerHTML;
}

// Readability leaves a link to a fragment of the page as it is, a link within the document it parses.
// The article shows in a document of its own, so such a link is resolved against the page's base URL,
// as Readability resolves every other link.
function resolveFragmentLinks(root)
{
    var links = root.querySelectorAll("a[href^='#']");
    for (var i = 0; i < links.length; ++i)
        links[i].setAttribute("href", new URL(links[i].getAttribute("href"), document.baseURI).href);
}

// The article document loads no images and applies none of the page's style sheets; its images take the
// size each renders at on the page, and that width as their source size for srcset, and its SVG graphics
// the size each renders at.
// copy is a fresh clone of page, so their images and graphics correspond in order.
function copyRenderedImageSizes(page, copy)
{
    var images = page.getElementsByTagName("img");
    var copiedImages = copy.getElementsByTagName("img");
    for (var i = 0; i < images.length && i < copiedImages.length; ++i) {
        if (!images[i].width || !images[i].height)
            continue;
        var image = copiedImages[i];
        image.setAttribute("width", images[i].width);
        image.setAttribute("height", images[i].height);
        var sourceSize = images[i].width + "px";
        image.setAttribute("sizes", sourceSize);
        if (image.parentElement && image.parentElement.tagName === "PICTURE") {
            for (var source = image.parentElement.firstElementChild; source && source !== image; source = source.nextElementSibling) {
                if (source.tagName === "SOURCE" && source.hasAttribute("sizes"))
                    source.setAttribute("sizes", sourceSize);
            }
        }
    }

    // An outermost graphic takes its layout width, and its layout height unless its viewBox gives its aspect
    // ratio, which keeps it when the Reader's column narrows it: a graphic whose preserveAspectRatio aligns
    // none stretches to its box, so it takes both. A nested graphic is sized in its outer graphic's units.
    var graphics = page.getElementsByTagName("svg");
    var copiedGraphics = copy.getElementsByTagName("svg");
    for (var i = 0; i < graphics.length && i < copiedGraphics.length; ++i) {
        if (graphics[i].ownerSVGElement || !graphics[i].getClientRects().length)
            continue;
        var style = getComputedStyle(graphics[i]);
        var width = parseFloat(style.width);
        var height = parseFloat(style.height);
        if (!width || !height)
            continue;
        copiedGraphics[i].setAttribute("width", width);
        if (!graphics[i].hasAttribute("viewBox") || graphics[i].preserveAspectRatio.baseVal.align === SVGPreserveAspectRatio.SVG_PRESERVEASPECTRATIO_NONE)
            copiedGraphics[i].setAttribute("height", height);
    }
}

// Safari's Reader view has no size yet when the article enters it, so a source size relative to the
// viewport would resolve to 0 there. Every source size in the article is resolved here against the
// page's viewport, which the Reader view takes the place of.
function resolveSourceSizes(root)
{
    var images = root.getElementsByTagName("img");
    for (var i = 0; i < images.length; ++i) {
        var image = images[i];
        if (image.hasAttribute("srcset") || (image.parentElement && image.parentElement.tagName === "PICTURE"))
            image.setAttribute("sizes", sourceSizeOnPage(image.getAttribute("sizes")));
    }
    var sources = root.querySelectorAll("picture > source[sizes]");
    for (var i = 0; i < sources.length; ++i)
        sources[i].setAttribute("sizes", sourceSizeOnPage(sources[i].getAttribute("sizes")));
}

// The source size a sizes attribute selects on the page, as a length free of viewport units.
function sourceSizeOnPage(sizes)
{
    var entries = [];
    var depth = 0;
    var start = 0;
    sizes = sizes || "";
    for (var i = 0; i < sizes.length; ++i) {
        if (sizes[i] === "(")
            ++depth;
        else if (sizes[i] === ")")
            --depth;
        else if (sizes[i] === "," && !depth) {
            entries.push(sizes.slice(start, i));
            start = i + 1;
        }
    }
    entries.push(sizes.slice(start));

    for (var i = 0; i < entries.length; ++i) {
        var entry = entries[i].trim();
        var lengthStart = entry.length;
        if (entry[lengthStart - 1] === ")") {
            for (depth = 0; lengthStart > 0; ) {
                var character = entry[--lengthStart];
                if (character === ")")
                    ++depth;
                else if (character === "(" && !--depth)
                    break;
            }
            while (lengthStart > 0 && /[\w-]/.test(entry[lengthStart - 1]))
                --lengthStart;
        } else {
            while (lengthStart > 0 && !/[\s)]/.test(entry[lengthStart - 1]))
                --lengthStart;
        }
        var condition = entry.slice(0, lengthStart).trim();
        var length = lengthWithoutViewportUnits(entry.slice(lengthStart).trim());
        if (!length || /^auto$/i.test(length) || length.indexOf("%") !== -1 || !CSS.supports("width", length))
            continue;
        // Parenthesized, a media query list parses as the <media-condition> a sizes entry carries.
        if (condition && !window.matchMedia("(" + condition + ")").matches)
            continue;
        return length;
    }
    return window.innerWidth + "px";
}

function lengthWithoutViewportUnits(length)
{
    var vertical = /^(vertical|sideways)/.test(getComputedStyle(document.documentElement).writingMode);
    var units = {
        vw: window.innerWidth,
        vh: window.innerHeight,
        vi: vertical ? window.innerHeight : window.innerWidth,
        vb: vertical ? window.innerWidth : window.innerHeight,
        vmin: Math.min(window.innerWidth, window.innerHeight),
        vmax: Math.max(window.innerWidth, window.innerHeight),
    };
    return length.replace(/(\d*\.?\d+(?:e[+-]?\d+)?)[sld]?(vw|vh|vi|vb|vmin|vmax)\b/gi, function(match, value, unit) {
        return (parseFloat(value) * units[unit.toLowerCase()] / 100) + "px";
    });
}

// Readability keeps the article's own wrappers. The container this returns holds the article's
// blocks directly: a wrapper that holds blocks gives up its children, one that holds only inline
// content becomes a paragraph, and each run of inline content between blocks becomes a paragraph.
function flattenedArticle(root, articleDocument)
{
    const blockTags = /^(P|H[1-6]|FIGURE|BLOCKQUOTE|UL|OL|DL|PRE|TABLE|HR|IMG|PICTURE|VIDEO|AUDIO|IFRAME)$/;
    const wrapperTags = /^(DIV|SECTION|ARTICLE|MAIN|HEADER|FOOTER|ASIDE|NAV|SPAN|FORM|CENTER|FONT)$/;
    // HTML's phrasing content, with the obsolete phrasing elements HTML renders inline and autonomous custom
    // elements. The embedded elements among blockTags stand as blocks here.
    const phrasingNames = new Set(["a", "abbr", "area", "b", "bdi", "bdo", "br", "button", "canvas", "cite", "code", "data", "datalist", "del", "dfn", "em", "embed", "i", "input", "ins", "kbd", "label", "link", "map", "mark", "math", "meta", "meter", "noscript", "object", "output", "q", "ruby", "s", "samp", "script", "select", "slot", "small", "span", "strong", "sub", "sup", "svg", "template", "textarea", "time", "u", "var", "wbr", "acronym", "big", "font", "nobr", "strike", "tt"]);
    const embeddedSelector = "img, picture, video, audio, iframe, embed, object, svg, math, canvas";

    function isPhrasing(element)
    {
        return phrasingNames.has(element.localName) || element.localName.indexOf("-") !== -1;
    }

    function holdsBlocks(element)
    {
        for (var child = element.firstElementChild; child; child = child.nextElementSibling) {
            if (blockTags.test(child.tagName) || (wrapperTags.test(child.tagName) && holdsBlocks(child)))
                return true;
        }
        return false;
    }

    var container = articleDocument.createElement("div");

    function hasContent(node)
    {
        return node.textContent.trim().length || (node.nodeType === Node.ELEMENT_NODE && (node.matches(embeddedSelector) || node.querySelector(embeddedSelector)));
    }

    function appendParagraph(nodes)
    {
        if (!nodes.some(hasContent))
            return;
        var paragraph = articleDocument.createElement("p");
        nodes.forEach(function(node) { paragraph.appendChild(node); });
        container.appendChild(paragraph);
    }

    function flatten(element)
    {
        var run = [];
        for (var node = element.firstChild; node; ) {
            var next = node.nextSibling;
            var isElement = node.nodeType === Node.ELEMENT_NODE;
            if (node.nodeType === Node.TEXT_NODE || (isElement && isPhrasing(node) && !holdsBlocks(node)))
                run.push(node);
            else if (isElement) {
                appendParagraph(run);
                run = [];
                if (!wrapperTags.test(node.tagName))
                    container.appendChild(node);
                else if (holdsBlocks(node))
                    flatten(node);
                else
                    appendParagraph(Array.prototype.slice.call(node.childNodes));
            }
            node = next;
        }
        appendParagraph(run);
    }

    flatten(root);
    return container;
}
