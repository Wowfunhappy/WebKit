async function loadHandoffMedia(media, source, mode, report, currentTime, onSeek, onTime) {
    await new Promise(resolve => media.addEventListener('sourceopen', resolve, { once: true }));
    const mp4 = source.endsWith('.mp4');
    const mime = source === 'eac3.mp4' ? 'video/mp4; codecs="avc1.42E01E,ec-3"' : source === 'flac.webm' ? 'audio/webm; codecs=flac' : source === 'encrypted.mp4' ? 'video/mp4; codecs="avc1.64001F"' : mp4 ? 'video/mp4; codecs="avc1.42E01E,mp4a.40.2"'
        : source === 'vp9-opus.webm' ? 'video/webm; codecs="vp9,opus"' : 'video/webm; codecs="vp8,vorbis"';
    const buffer = media.addSourceBuffer(mime);
    const url = '/quicktime-media/' + source;
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
    if (mode !== 'window' && mode !== 'island') {
        const bytes = await (await fetch(url)).arrayBuffer();
        await update(() => buffer.appendBuffer(bytes));
        if (mode !== 'open')
            media.endOfStream();
        else
            media.duration = buffer.buffered.end(buffer.buffered.length - 1);
        report('Appended ' + bytes.byteLength + ' bytes; ' + media.readyState);
        return;
    }
    const manifest = await (await fetch(url.replace(/\.(mp4|webm)$/, '.json'))).json();
    async function bytes(offset, length) {
        const response = await fetch(url, { headers: { Range: 'bytes=' + offset + '-' + (offset + length - 1) } });
        if (response.status !== 206)
            throw new Error('Expected byte range');
        return response.arrayBuffer();
    }
    const init = await bytes(0, manifest.init);
    await update(() => buffer.appendBuffer(init));
    media.duration = manifest.duration;
    let sequence = Promise.resolve();
    let firstRefill = true;
    let filling = false;
    let bufferedThrough = 0;
    const appended = new Set();
    function refill() {
        if (filling) return sequence;
        filling = true;
        sequence = sequence.then(async () => {
            const target = currentTime();
            const first = Math.max(0, target - 2);
            const last = Math.min(manifest.duration, target + 6);
            if (first > 0) {
                await update(() => buffer.remove(0, first));
                for (const fragment of manifest.fragments) {
                    if (fragment.start < first) appended.delete(fragment.offset);
                }
            }
            for (const fragment of manifest.fragments) {
                const island = mode === 'island' && firstRefill && fragment.end > manifest.duration - 6;
                if (!island && (fragment.end <= first || fragment.start > last))
                    continue;
                if (appended.has(fragment.offset)) continue;
                const data = await bytes(fragment.offset, fragment.length);
                await update(() => buffer.appendBuffer(data));
                appended.add(fragment.offset);
            }
            firstRefill = false;
            bufferedThrough = last;
            if (last === manifest.duration)
                media.endOfStream();
            report('Window fetch at ' + target.toFixed(3) + '; buffered ' + Array.from({ length: buffer.buffered.length }, (_, i) => [buffer.buffered.start(i), buffer.buffered.end(i)]));
        }).catch(error => report(error.stack)).finally(() => { filling = false; });
        return sequence;
    }
    onSeek(refill);
    if (onTime) onTime(() => {
        if (bufferedThrough < manifest.duration && currentTime() + 3 >= bufferedThrough) refill();
    });
    await refill();
}
