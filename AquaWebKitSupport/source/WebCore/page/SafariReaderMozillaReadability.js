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
    resolveSourceSizes(extracted);
    var container = flattenedArticle(extracted, articleDocument);
    // Safari's finder takes no element shorter than 295px for an article, however short the article.
    container.style.minHeight = "300px";
    articleDocument.body.appendChild(container);

    return "<!DOCTYPE html>" + articleDocument.documentElement.outerHTML;
}

// The article document loads no images; its images take the size each renders at on the page, and
// that width as their source size for srcset.
// copy is a fresh clone of page, so their images correspond in order.
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
// blocks directly: a wrapper that holds blocks gives up its children, and one that holds only
// inline content becomes a paragraph.
function flattenedArticle(root, articleDocument)
{
    const blockTags = /^(P|H[1-6]|FIGURE|BLOCKQUOTE|UL|OL|DL|PRE|TABLE|HR|IMG|PICTURE|VIDEO|AUDIO|IFRAME)$/;
    const wrapperTags = /^(DIV|SECTION|ARTICLE|MAIN|HEADER|FOOTER|ASIDE|NAV|SPAN|FORM|CENTER|FONT)$/;

    function holdsBlocks(element)
    {
        for (var child = element.firstElementChild; child; child = child.nextElementSibling) {
            if (blockTags.test(child.tagName) || (wrapperTags.test(child.tagName) && holdsBlocks(child)))
                return true;
        }
        return false;
    }

    var container = articleDocument.createElement("div");

    function appendParagraph(nodes)
    {
        var paragraph = articleDocument.createElement("p");
        nodes.forEach(function(node) { paragraph.appendChild(node); });
        container.appendChild(paragraph);
    }

    function flatten(element)
    {
        for (var node = element.firstChild; node; ) {
            var next = node.nextSibling;
            if (node.nodeType === Node.ELEMENT_NODE && wrapperTags.test(node.tagName)) {
                if (holdsBlocks(node))
                    flatten(node);
                else if (node.textContent.trim().length || node.querySelector("img, picture, video"))
                    appendParagraph(Array.prototype.slice.call(node.childNodes));
            } else if (node.nodeType === Node.ELEMENT_NODE)
                container.appendChild(node);
            else if (node.nodeType === Node.TEXT_NODE && node.data.trim().length)
                appendParagraph([node]);
            node = next;
        }
    }

    flatten(root);
    return container;
}
