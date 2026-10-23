async function loadLiveHandoffMedia(media, video, source, report, finish = false, finite = false) {
    await new Promise(resolve => media.addEventListener('sourceopen', resolve, { once: true }));
    const mp4 = source.endsWith('.mp4');
    const mime = source === 'flac.webm' ? 'audio/webm; codecs=flac' : mp4 ? 'video/mp4; codecs="avc1.42E01E,mp4a.40.2"' : 'video/webm; codecs="vp8,vorbis"';
    const buffer = media.addSourceBuffer(mime);
    const url = '/quicktime-media/' + source;
    const manifest = await (await fetch(url.replace(/\.(mp4|webm)$/, '.json'))).json();
    async function append(offset, length) {
        const response = await fetch(url, { headers: { Range: 'bytes=' + offset + '-' + (offset + length - 1) } });
        if (response.status !== 206) throw new Error('Expected byte range');
        const bytes = await response.arrayBuffer();
        await update(() => buffer.appendBuffer(bytes));
    }
    function update(action) {
        return new Promise((resolve, reject) => {
            const done = () => { cleanup(); resolve(); };
            const error = () => { cleanup(); reject(new Error('SourceBuffer error')); };
            function cleanup() {
                buffer.removeEventListener('updateend', done);
                buffer.removeEventListener('error', error);
            }
            buffer.addEventListener('updateend', done);
            buffer.addEventListener('error', error);
            try { action(); } catch (error) { cleanup(); reject(error); }
        });
    }
    await append(0, manifest.init);
    media.duration = finite ? 3600 : Infinity;
    let next = 0, cycle = 0, busy = false;
    async function refill() {
        if (busy) return;
        busy = true;
        try {
            while (!buffer.buffered.length || buffer.buffered.end(buffer.buffered.length - 1) < video.currentTime + 12) {
                if (next === manifest.fragments.length) {
                    if (finish) {
                        media.endOfStream();
                        video.removeEventListener('timeupdate', refill);
                        return;
                    }
                    ++cycle;
                    next = 0;
                    buffer.timestampOffset = cycle * manifest.duration;
                }
                const fragment = manifest.fragments[next++];
                await append(fragment.offset, fragment.length);
            }
            const before = Math.max(0, video.currentTime - 10);
            if (before > 0) await update(() => buffer.remove(0, before));
            report('Live cycle ' + cycle + '; time ' + video.currentTime.toFixed(2) + '; buffered '
                + Array.from({ length: buffer.buffered.length }, (_, i) => [buffer.buffered.start(i), buffer.buffered.end(i)]));
        } catch (error) {
            report(error.stack);
        } finally {
            busy = false;
        }
    }
    video.addEventListener('timeupdate', refill);
    await refill();
    await video.play();
}
