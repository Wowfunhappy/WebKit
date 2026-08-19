#!/bin/bash
# capture.sh — capture evidence the moment github misbehaves (labels not applying,
# "Failed to load issues", missing rows). Records the failing request/exception in
# the live Safari session so the occurrence is diagnosable.
#
# USAGE:
#   1) Once per Safari tab you're about to use:   ./capture.sh arm
#      (survives github's in-app navigations; re-arm after a full page reload)
#   2) The moment something misbehaves:           ./capture.sh dump
#      Writes a timestamped report to /tmp/github-failure-<time>.txt
#
# It only reads from the page; it changes nothing.

set -u
ACTION="${1:-dump}"
OUT="/tmp/github-failure-$(date +%Y%m%d-%H%M%S).txt"

run_js() {
    osascript -e "set js to \"$1\"" -e 'tell application "Safari" to do JavaScript js in front document' 2>/dev/null
}

arm_js='(function(){ if (window.__ghcap) return "already armed"; var C = window.__ghcap = {req:[], errs:[], ui:[], t0:Date.now()}; var of = window.fetch; window.fetch = function(input, init){ var url = (typeof input === "string") ? input : (input && input.url) || "?"; var method = (init && init.method) || "GET"; var t = performance.now(); var rec = {t: Math.round(t), m: method, u: String(url).substring(0,160), s: "pending", ms: 0}; C.req.push(rec); if (C.req.length > 400) C.req.shift(); return of.apply(this, arguments).then(function(r){ rec.s = String(r.status); rec.ms = Math.round(performance.now()-t); return r; }, function(e){ rec.s = "NETERR:" + (e && e.name) + ":" + String(e && e.message).substring(0,100); rec.ms = Math.round(performance.now()-t); throw e; }); }; var oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send; XMLHttpRequest.prototype.open = function(m,u){ this.__m=m; this.__u=String(u).substring(0,160); return oo.apply(this, arguments); }; XMLHttpRequest.prototype.send = function(){ var x=this, t=performance.now(); var rec={t:Math.round(t), m:(x.__m||"?")+"(xhr)", u:x.__u||"?", s:"pending", ms:0}; C.req.push(rec); x.addEventListener("loadend", function(){ rec.s = x.status ? String(x.status) : "NETERR:status0"; rec.ms = Math.round(performance.now()-t); }); return os.apply(this, arguments); }; window.addEventListener("error", function(e){ C.errs.push({t:Math.round(performance.now()), kind:"exception", msg:String(e.message).substring(0,240), at:String(e.filename||"").substring(0,90)+":"+e.lineno}); }); window.addEventListener("unhandledrejection", function(e){ var r=e.reason; C.errs.push({t:Math.round(performance.now()), kind:"promise-rejection", msg:((r&&r.stack)?String(r.stack):String(r)).substring(0,300)}); }); new MutationObserver(function(ms){ ms.forEach(function(m){ Array.prototype.forEach.call(m.addedNodes||[], function(n){ if (n.nodeType!==1) return; var t=(n.textContent||"").replace(/\s+/g," ").trim(); if (/Failed to load issues|We encountered an error|Something went wrong|please try again/i.test(t)) { C.ui.push({t:Math.round(performance.now()), text:t.substring(0,200)}); } }); }); }).observe(document.documentElement, {childList:true, subtree:true}); return "ARMED (recording). Reproduce the problem, then run: dump"; })()'

dump_js='(function(){ var C = window.__ghcap; if (!C) return "NOT ARMED — run: capture.sh arm  (then reproduce, then dump)"; var stuck = C.req.filter(function(r){ return r.s === "pending"; }); var neterr = C.req.filter(function(r){ return r.s.indexOf("NETERR") === 0; }); var http4xx5xx = C.req.filter(function(r){ return /^[45]/.test(r.s); }); var slow = C.req.filter(function(r){ return r.ms > 5000; }); var done = C.req.filter(function(r){ return r.ms > 0; }).map(function(r){ return r.ms; }).sort(function(a,b){ return a-b; }); return JSON.stringify({ url: location.href, recordedSeconds: Math.round((Date.now()-C.t0)/1000), issueRowsRendered: document.querySelectorAll("[data-testid=issue-list] li, .js-issue-row, [role=listitem]").length, totalRequests: C.req.length, latency: {p50: done.length?done[Math.floor(done.length/2)]:0, p90: done.length?done[Math.floor(done.length*0.9)]:0, max: done.length?done[done.length-1]:0}, STUCK_REQUESTS: stuck.slice(-25), NETWORK_ERRORS: neterr.slice(-25), HTTP_4xx_5xx: http4xx5xx.slice(-25), SLOW_OVER_5s: slow.slice(-25), JS_ERRORS: C.errs.slice(-25), ERROR_UI_SHOWN: C.ui.slice(-15) }, null, 1); })()'

case "$ACTION" in
    arm)
        run_js "$(printf '%s' "$arm_js" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        ;;
    dump)
        {
            echo "=== github flakiness capture: $(date) ==="
            echo
            echo "--- page-side recording ---"
            run_js "$(printf '%s' "$dump_js" | sed 's/\\/\\\\/g; s/"/\\"/g')"
            echo
            echo "--- browser processes ---"
            ps ax -o pid,etime,%cpu,rss,command | grep -E "[S]afari|[W]ebKit\.(WebContent|Networking)" | sed 's/\(.\{150\}\).*/\1/'
            echo
            NETPID=$(ps ax -o pid,command | grep "[c]om.apple.WebKit.Networking" | awk '{print $1}' | head -1)
            if [ -n "${NETPID:-}" ]; then
                echo "--- NetworkProcess sockets (pid $NETPID) ---"
                echo "established to proxy: $(lsof -nP -a -p "$NETPID" -iTCP -sTCP:ESTABLISHED 2>/dev/null | grep -c 6531)"
                echo "total TCP fds:        $(lsof -nP -a -p "$NETPID" -iTCP 2>/dev/null | grep -c . )"
            fi
            echo
            echo "--- recent WebKit crashes (last 5) ---"
            ls -lt "$HOME/Library/Logs/DiagnosticReports/" 2>/dev/null | grep -i webkit | head -5
        } > "$OUT" 2>&1
        echo "wrote $OUT"
        grep -E "STUCK_REQUESTS|NETWORK_ERRORS|HTTP_4xx_5xx|JS_ERRORS|ERROR_UI_SHOWN|NOT ARMED" "$OUT" | head -8
        ;;
    *)
        echo "usage: $0 arm|dump"; exit 2
        ;;
esac
