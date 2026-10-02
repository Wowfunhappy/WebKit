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
    var container = flattenedArticle(extracted, articleDocument);
    // Safari's finder takes no element shorter than 295px for an article, however short the article.
    container.style.minHeight = "300px";
    articleDocument.body.appendChild(container);

    return "<!DOCTYPE html>" + articleDocument.documentElement.outerHTML;
}

// The article document loads no images; its images take the size each renders at on the page.
// copy is a fresh clone of page, so their images correspond in order.
function copyRenderedImageSizes(page, copy)
{
    var images = page.getElementsByTagName("img");
    var copiedImages = copy.getElementsByTagName("img");
    for (var i = 0; i < images.length && i < copiedImages.length; ++i) {
        if (!images[i].width || !images[i].height)
            continue;
        copiedImages[i].setAttribute("width", images[i].width);
        copiedImages[i].setAttribute("height", images[i].height);
    }
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
