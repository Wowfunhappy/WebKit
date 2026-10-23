importScripts('quicktime-mse.js', 'quicktime-live.js');
const clockEvents = new EventTarget();
let time = 0;
let seek;
self.onmessage = event => {
    if (event.data.time !== undefined) {
        time = event.data.time;
        clockEvents.dispatchEvent(new Event('timeupdate'));
        return;
    }
    if (event.data.seek !== undefined) {
        time = event.data.seek;
        if (seek) seek();
        return;
    }
    const media = new MediaSource();
    self.postMessage({ handle: media.handle }, [media.handle]);
    if (event.data.mode === 'live') {
        const clock = {
            get currentTime() { return time; },
            addEventListener: (...args) => clockEvents.addEventListener(...args),
            removeEventListener: (...args) => clockEvents.removeEventListener(...args),
            play: () => { self.postMessage({ play: true }); return Promise.resolve(); }
        };
        loadLiveHandoffMedia(media, clock, event.data.source, report => self.postMessage({ report }), event.data.finish, event.data.finite)
            .catch(error => self.postMessage({ report: error.stack }));
        return;
    }
    loadHandoffMedia(media, event.data.source, event.data.mode,
        report => self.postMessage({ report }), () => time, callback => { seek = callback; }, callback => clockEvents.addEventListener('timeupdate', callback))
        .catch(error => self.postMessage({ report: error.stack }));
};
