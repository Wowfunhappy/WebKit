(function () {
    if (window !== window.top || !document.querySelector('#video'))
        return;
    var previousPanel = document.querySelector('#media-player-test');
    if (previousPanel)
        previousPanel.remove();
    var panel = document.createElement('div');
    panel.id = 'media-player-test';
    var application = document.createElement('input');
    application.id = 'target-application';
    application.value = 'com.apple.QuickTimePlayerX';
    application.size = 48;
    var button = document.createElement('button');
    button.id = 'open-media-player';
    button.textContent = 'Open in target application';
    var result = document.createElement('pre');
    result.id = 'media-player-result';
    button.addEventListener('click', function () {
        result.textContent = 'pending';
        var options = { application: application.value };
        var parameters = new URLSearchParams(location.search);
        if (parameters.has("sourceMode"))
            options.sourceMode = parameters.get("sourceMode");
        if (parameters.has("capture"))
            options.capture = JSON.parse(parameters.get("capture"));
        if (parameters.has("routeTimeout"))
            options.routeTimeout = Number(parameters.get("routeTimeout"));
        var title = parameters.get("title");
        options.title = title === null ? document.title : title;
        if (application.value === "com.apple.QuickTimePlayerX")
            options.title = options.title.replace(/\//g, "\u2215");
        if (!parameters.has("omitOpeningMessage"))
            options.openingMessage = parameters.has("openingMessage") ? parameters.get("openingMessage") : "Opening test player\u2026";
        if (application.value === "com.apple.QuickTimePlayerX")
            options.adapter = { position: "time", duration: "durn", rate: "rate", play: "MVWRplay", pause: "MVWRpaus" };
        if (parameters.get("adapter") === "fixture")
            options.adapter = { position: "time", duration: "durn", rate: "rate", play: "testplay", pause: "testpaus" };
        var selection = new URLSearchParams(location.search).get("tracks");
        var video = document.querySelector('#video');
        var tracks = Array.from(video.textTracks);
        if (selection === "none")
            options.textTracks = [];
        else if (selection === "showing")
            options.textTracks = tracks.filter(function (track) { return track.mode === "showing"; });
        else if (selection === "all")
            options.textTracks = tracks.filter(function (track) { return track.mode !== "disabled"; });
        else if (selection === "duplicate")
            options.textTracks = [tracks[0], tracks[0]];
        else if (selection === "foreign") {
            var foreign = document.createElement('video').addTextTrack('captions');
            foreign.mode = "hidden";
            options.textTracks = [foreign];
        } else if (selection === "disabled") {
            tracks[0].mode = "disabled";
            options.textTracks = [tracks[0]];
        } else if (selection === "invalid")
            options.textTracks = [{}];
        else if (selection === "not-array")
            options.textTracks = {};
        else if (selection === "oversized")
            options.textTracks = new Array(0xffffffff);
        else if (selection === "adopted") {
            options.textTracks = [tracks[0]];
            Object.defineProperty(options.textTracks, "0", { get: function () { document.implementation.createHTMLDocument().adoptNode(video); return tracks[0]; } });
        } else if (selection === "throwing") {
            options.textTracks = [tracks[0]];
            Object.defineProperty(options.textTracks, "0", { get: function () { throw new Error("track getter"); } });
        }
        var resolver = parameters.get("resolve");
        if (resolver) {
            options.resolveSource = async function (url) {
                result.dataset.resolving = "true";
                if (resolver === "reject")
                    throw new Error("test rejection");
                if (resolver === "timeout" || resolver === "timeout-replaced")
                    return new Promise(function () { });
                if (resolver === "delay")
                    await new Promise(function (resolve) { setTimeout(resolve, 3000); });
                if (resolver === "invalid")
                    return { url: url, playlist: 42 };
                if (resolver === "oversized")
                    return { url: url, playlist: "#EXTM3U" + " ".repeat(1024 * 1024) };
                if (resolver === "playlist" && parameters.has("playlist"))
                    return { url: url, playlist: await (await fetch(parameters.get("playlist"))).text() };
                if (resolver === "playlist")
                    return { url: url, playlist: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000000\n" + new URL("/quicktime-media/index.m3u8", url).href + "\n" };
                return { url: url };
            };
        }
        var scopeMode = parameters.get("handoffScope");
        var operation;
        if (scopeMode) {
            var savedScope;
            operation = aqua.mediaPlayer.withHandoff(function (scope) {
                savedScope = scope;
                result.dataset.scope = "active";
                scope.signal.addEventListener("abort", function () { result.dataset.scope = "aborted"; });
                if (scopeMode === "throw")
                    throw new Error("scope-test-error");
                if (scopeMode === "reject")
                    return Promise.reject(new Error("scope-test-error"));
                if (scopeMode === "timeout")
                    return new Promise(function () { });
                if (scopeMode === "stale")
                    return { method: "scope", url: "settled" };
                async function delayedOpen(activeScope) {
                    await new Promise(function (resolve) { setTimeout(resolve, 3000); });
                    return (scopeMode === "unscoped" ? aqua.mediaPlayer : activeScope).open(video, options);
                }
                return scopeMode === "nested" ? scope.withHandoff(delayedOpen) : delayedOpen(scope);
            });
            if (scopeMode === "stale")
                operation = operation.then(function () { return savedScope.open(video, options); });
        } else
            operation = aqua.mediaPlayer.open(video, options);
        var operations = [operation];
        if (parameters.has("coalesce") || parameters.has("coalesceMode")) {
            var repeatOptions = Object.assign({}, options);
            if (parameters.has("coalesceMode"))
                repeatOptions.sourceMode = parameters.get("coalesceMode");
            if (options.adapter)
                repeatOptions.adapter = { pause: "MVWRpaus", play: "MVWRplay", rate: "rate", duration: "durn", position: "time" };
            if (Array.isArray(options.textTracks))
                repeatOptions.textTracks = options.textTracks.slice().reverse();
            operations.push(aqua.mediaPlayer.open(video, repeatOptions));
        }
        Promise.all(operations).then(function (values) {
            if (!values.every(function (value) { return value.url === values[0].url && value.method === values[0].method; })) {
                result.textContent = JSON.stringify({ error: "different-results" });
                return;
            }
            result.textContent = JSON.stringify(Object.assign({ coalesced: values.length }, values[0]));
        }, function (error) {
            result.textContent = JSON.stringify({ error: error.message });
        });
    });
    var lifetimePort;
    if (new URLSearchParams(location.search).get('dispatchMode') === 'port-close')
        lifetimePort = browser.runtime.connect({ name: 'handoff-lifetime:' + new URLSearchParams(location.search).get('dispatchID') });
    if (['unused-close', 'port-close'].includes(new URLSearchParams(location.search).get('dispatchMode'))) {
        window.addEventListener('pagehide', function () {
            navigator.sendBeacon('/handoff-dispatch-report', JSON.stringify({ id: new URLSearchParams(location.search).get('dispatchID'), stage: 'unloaded' }));
        });
    }
    var dispatch = document.createElement('button');
    dispatch.id = 'dispatch-media-player';
    dispatch.textContent = 'Dispatch handoff';
    dispatch.addEventListener('click', function () {
        var parameters = new URLSearchParams(location.search);
        safari.self.tab.dispatchMessage('test-prepare-handoff', { id: parameters.get('dispatchID'), mode: parameters.get('dispatchMode') });
    });
    safari.self.addEventListener('message', async function (event) {
        if (event.name === 'test-handoff-busy') {
            var until = Date.now() + event.message;
            while (Date.now() < until) { }
            return;
        }
        if (event.name !== 'test-handoff-ticket')
            return;
        var message = event.message;
        var reply = { id: message.id, stage: 'complete' };
        try {
            var operation = function (scope) {
                if (message.mode === 'port-close') {
                    return new Promise(function (resolve) {
                        lifetimePort.onMessage.addListener(function (value) {
                            if (value.kind === 'ping')
                                lifetimePort.postMessage({ kind: 'pong', absent: value.absent });
                            else if (value.kind === 'finish')
                                resolve({ roundtrip: true });
                        });
                        lifetimePort.postMessage('ready');
                    });
                }
                if (message.mode === 'claim' || message.mode === 'use-stored' || message.mode === 'replay' || message.mode === 'cancel' || message.mode === 'expired')
                    return { claimed: true };
                return scope.open(document.querySelector('#video'), {
                    application: 'org.aqua.webkit.media-handoff-receiver',
                    adapter: { position: 'time', duration: 'durn', rate: 'rate', play: 'testplay', pause: 'testpaus' },
                    sourceMode: 'direct'
                });
            };
            reply.value = await aqua.mediaPlayer.withHandoff(operation, { ticket: message.ticket });
            if (message.mode === 'replay')
                await aqua.mediaPlayer.withHandoff(operation, { ticket: message.ticket });
        } catch (error) {
            reply.error = error.message;
        }
        await fetch('/handoff-dispatch-report', { method: 'POST', body: JSON.stringify(reply) });
    }, false);
    panel.appendChild(dispatch);
    panel.appendChild(application);
    panel.appendChild(button);
    panel.appendChild(result);
    document.body.appendChild(panel);
}());
