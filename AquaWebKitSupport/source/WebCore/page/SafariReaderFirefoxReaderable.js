// Evaluated after Readability-readerable.js and before Firefox's Readerable.js, in a world of
// WebKit's own on a page whose Reader availability Safari 7 is deciding. Readerable.js is Firefox
// code; the globals below stand in for the Gecko ones it reads, with the values Firefox gives them.

var ChromeUtils = {
    importESModule() {
        return {
            XPCOMUtils: {
                // Readerable's only preference, reader.parse-on-load.enabled, at its default.
                defineLazyPreferenceGetter(object, name, preference, defaultValue) {
                    object[name] = defaultValue;
                },
            },
        };
    },
};

var Services = {
    io: {
        // The parts of an nsIURI Readerable reads.
        newURI(spec) {
            var url = new URL(spec);
            return { scheme: url.protocol.slice(0, -1), host: url.hostname, filePath: url.pathname };
        },
    },
};

HTMLDocument.isInstance = function(object) {
    return object instanceof HTMLDocument;
};

// Whether Firefox would offer Reader View for this page: AboutReaderChild's canDoReadabilityCheck
// and performReadabilityCheckNow.
function firefoxReaderViewIsAvailable()
{
    return Readerable.isEnabledForParseOnLoad
        && HTMLDocument.isInstance(document)
        && !document.mozSyntheticDocument
        && Readerable.shouldCheckUri(Services.io.newURI(document.baseURI), true)
        && Readerable.isProbablyReaderable(document);
}
