async function loadEpochHandoffMedia(media, report, offset) {
    await new Promise(resolve => media.addEventListener('sourceopen', resolve, { once: true }));
    const buffer = media.addSourceBuffer('video/mp4; codecs="avc1.42E01E,mp4a.40.2"');
    for (const name of ['epoch-a', 'epoch-b']) {
        const bytes = await (await fetch('/quicktime-media/' + name + '.mp4')).arrayBuffer();
        buffer.timestampOffset = offset;
        await new Promise((resolve, reject) => {
            buffer.addEventListener('updateend', resolve, { once: true });
            buffer.addEventListener('error', reject, { once: true });
            buffer.appendBuffer(bytes);
        });
        offset = media.duration;
    }
    media.endOfStream();
    report('Two H.264 resolutions; duration ' + media.duration);
}
