"use strict";
const assert = require("assert");
const requests = [];
const bodies = new Map([
    ["https://media.invalid/high.m3u8", "#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXT-X-MEDIA-SEQUENCE:10\n#EXTINF:5,\nhigh-10.ts\n"],
    ["https://media.invalid/low.m3u8", "#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXT-X-MEDIA-SEQUENCE:10\n#EXTINF:5,\nlow-10.ts\n"],
]);
global.fetch = async url => {
    requests.push(url);
    const text = bodies.get(url);
    let read = false;
    return {
        ok: text !== undefined, url,
        body: { getReader: () => ({
            read: async () => read ? { done: true } : (read = true, { done: false, value: new TextEncoder().encode(text) }),
            cancel: async () => {},
        }) },
    };
};
const path = require("path");
const extensionRoot = process.env.AQUAWEBKIT_EXTENSIONS_DIR || path.resolve(__dirname, "../../../../AquaWebKit-Extensions");
require(path.join(extensionRoot, "lib/HLSPlaylistRelay.js"));

(async () => {
    const resources = new Map();
    let provider, end;
    const source = {
        url: "http://127.0.0.1:9000/token/index.m3u8",
        closed: new Promise(resolve => { end = resolve; }),
        close: async () => end(),
        setResource: async (name, data) => {
            resources.set(name, data);
            return "http://127.0.0.1:9000/token/" + name;
        },
        setPlaylistProvider: async callback => { provider = callback; },
    };
    const master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000\nhigh.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nlow.m3u8\n";
    await MediaHLSRelay.create({ publish: async () => source }, { url: "https://media.invalid/master.m3u8", playlist: master });
    assert.deepStrictEqual(requests, [], "Unused variants must not be fetched");
    const root = await provider("index.m3u8");
    assert(root.includes("/token/playlist-1.m3u8") && root.includes("/token/playlist-2.m3u8"));
    const high = await provider("playlist-1.m3u8");
    assert(high.includes("https://media.invalid/high-10.ts"));
    assert.deepStrictEqual(requests, ["https://media.invalid/high.m3u8"]);
    bodies.set("https://media.invalid/high.m3u8", bodies.get("https://media.invalid/high.m3u8").replace(/10/g, "11"));
    assert((await provider("playlist-1.m3u8")).includes("#EXT-X-MEDIA-SEQUENCE:11"));
    assert(!requests.includes("https://media.invalid/low.m3u8"));
    assert.strictEqual(await provider("unknown.m3u8"), null);
    bodies.delete("https://media.invalid/high.m3u8");
    await assert.rejects(provider("playlist-1.m3u8"), /playlist-fetch-failed/);
    assert((await provider("playlist-2.m3u8")).includes("https://media.invalid/low-10.ts"));
    await source.close();
    await Promise.resolve();
    assert.strictEqual(await provider("playlist-2.m3u8"), null);
    console.log("PASS receiver-driven playlist fetch, rendition preservation, URI rebasing, refresh, error and closure");
})().catch(error => { console.error(error); process.exitCode = 1; });
