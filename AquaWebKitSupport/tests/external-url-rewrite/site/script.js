(async function () {
    const results = [];
    const out = document.getElementById("out");
    results.push("location=" + location.href);
    results.push("h1color=" + getComputedStyle(document.getElementById("h")).color);
    await new Promise(r => { const i = document.getElementById("img"); if (i.complete) r(); else { i.onload = r; i.onerror = r; } });
    results.push("imgWidth=" + document.getElementById("img").naturalWidth);
    const xhr = new XMLHttpRequest();
    xhr.open("GET", "/data.json", false);
    xhr.setRequestHeader("X-Page-Header", "removed-by-the-rewrite");
    xhr.send();
    results.push("xhr=" + xhr.status + " " + xhr.responseText.trim() + " responseURL=" + xhr.responseURL);
    const response = await fetch("data.json?x=1");
    const body = await response.json();
    results.push("fetch=" + response.status + " ok=" + body.ok + " redirected=" + response.redirected + " url=" + response.url);
    for (const kind of ["relative", "absolute"]) {
        try {
            const redirected = await fetch("/redirect-" + kind);
            const redirectedBody = await redirected.json();
            results.push("redirect-" + kind + "=" + redirected.status + " ok=" + redirectedBody.ok + " url=" + redirected.url);
        } catch (error) {
            results.push("redirect-" + kind + "=failed " + error);
        }
    }
    results.push("nav=" + JSON.stringify(performance.getEntriesByType("navigation").map(e => ({ name: e.name, redirectCount: e.redirectCount }))));
    results.push("history=" + history.length);
    results.push("cookie=" + document.cookie);
    out.textContent = results.join("\n");
    const pass = results[1].includes("0, 128, 0") && results[2] === "imgWidth=100" && xhr.status === 200 && response.status === 200 && !response.redirected;
    document.title = (pass ? "PASS" : "FAIL") + " " + results.join(" | ");
})();
