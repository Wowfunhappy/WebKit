'use strict';

// Without clipboardWrite or clipboardRead, a global page has the clipboard only through a user gesture,
// which it never gets.
const outcome = promise => promise.then(value => ({ resolved: value }), error => ({ rejected: error.name }));
(async () => {
    await fetch('http://127.0.0.1:8843/report?clipboard-denied-start=1');
    const result = {
        type: Object.prototype.toString.call(navigator.clipboard),
        write: await outcome(navigator.clipboard.writeText('denied')),
        read: await outcome(navigator.clipboard.readText()),
    };
    fetch(`http://127.0.0.1:8843/report?clipboard-denied=${encodeURIComponent(JSON.stringify(result))}`);
})();
