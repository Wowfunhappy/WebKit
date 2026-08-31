#!/bin/bash
# watch.sh — passive watchdog for the intermittent github failures.
#
# Runs in the background while you use Safari normally. Every ~20s it looks at the
# front tab; if it's a github page it makes sure the recorder is installed (idempotent),
# then checks for failure signatures. The instant one appears it writes a full report to
# /tmp/github-failure-<timestamp>.txt and prints a line here.
#
# Start:  nohup MavericksSupport/tests/github-flakiness/watch.sh > /tmp/gh-watch.out 2>&1 &
# Stop:   pkill -f github-flakiness/watch.sh
#
# Read-only with respect to the page: it wraps fetch/XHR to observe, and changes nothing.

INTERVAL="${1:-20}"

arm_js='(function(){ if (window.__ghcap) return "armed"; var C = window.__ghcap = {req:[], errs:[], ui:[], t0: Date.now()}; var of = window.fetch; window.fetch = function(input, init){ var url = (typeof input === "string") ? input : (input && input.url) || "?"; var m = (init && init.method) || "GET"; var t = performance.now(); var rec = {t: Math.round(t), m: m, u: String(url).substring(0,160), s: "pending", ms: 0}; C.req.push(rec); if (C.req.length > 500) C.req.shift(); return of.apply(this, arguments).then(function(r){ rec.s = String(r.status); rec.ms = Math.round(performance.now()-t); if (String(url).indexOf("_graphql") >= 0) { try { r.clone().text().then(function(tx){ try { var j = JSON.parse(tx); if (j && j.errors && j.errors.length) { rec.gqlErrors = j.errors.slice(0,3).map(function(e){ return String(e && (e.message||e.type)).substring(0,140); }); } } catch(e) { rec.nonJson = tx.substring(0,120); } }, function(){}); } catch(e){} } return r; }, function(e){ rec.s = "NETERR:" + (e && e.name) + ":" + String(e && e.message).substring(0,80); rec.ms = Math.round(performance.now()-t); throw e; }); }; var oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send; XMLHttpRequest.prototype.open = function(m,u){ this.__m=m; this.__u=String(u).substring(0,160); return oo.apply(this, arguments); }; XMLHttpRequest.prototype.send = function(){ var x=this, t=performance.now(); var rec={t:Math.round(t), m:(x.__m||"?")+"(xhr)", u:x.__u||"?", s:"pending", ms:0}; C.req.push(rec); x.addEventListener("loadend", function(){ rec.s = x.status ? String(x.status) : "NETERR:status0"; rec.ms = Math.round(performance.now()-t); }); return os.apply(this, arguments); }; window.addEventListener("error", function(e){ C.errs.push({kind:"exception", msg:String(e.message).substring(0,200), at:String(e.filename||"").substring(0,80)+":"+e.lineno}); }); window.addEventListener("unhandledrejection", function(e){ var r=e.reason; C.errs.push({kind:"rejection", msg:((r&&r.stack)?String(r.stack):String(r)).substring(0,240)}); }); new MutationObserver(function(ms){ ms.forEach(function(mu){ Array.prototype.forEach.call(mu.addedNodes||[], function(n){ if (n.nodeType!==1) return; var t=(n.textContent||"").replace(/\s+/g," ").trim(); if (/Failed to load issues|We encountered an error|Something went wrong (loading|displaying)|Couldn.t (load|display) this view|Please try again/i.test(t)) C.ui.push({text:t.substring(0,180)}); }); }); }).observe(document.documentElement, {childList:true, subtree:true}); return "armed-now"; })()'

# returns a compact failure verdict, or "clean"
probe_js='(function(){ var C = window.__ghcap; if (!C) return "norecorder"; var now = performance.now(); function fresh(a){ return a.filter(function(r){ return !r.__seen; }); } var stuck = fresh(C.req.filter(function(r){ return r.s === "pending" && (now - r.t) > 25000 && r.u.indexOf("copilot") < 0; })); var neterr = fresh(C.req.filter(function(r){ return r.s.indexOf("NETERR") === 0; })); var http45 = fresh(C.req.filter(function(r){ return /^[45]/.test(r.s); })); var gqlerr = fresh(C.req.filter(function(r){ return r.gqlErrors; })); var ui = fresh(C.ui); var js = fresh(C.errs); if (!stuck.length && !neterr.length && !http45.length && !gqlerr.length && !ui.length && !js.length) return "clean"; var out = "FAIL " + JSON.stringify({url: location.href.substring(0,110), stuck: stuck.slice(-5), netErrors: neterr.slice(-5), http4xx5xx: http45.slice(-5), graphqlErrors: gqlerr.slice(-4), errorUI: ui.slice(-4), jsErrors: js.slice(-5)}); [stuck, neterr, http45, gqlerr, ui, js].forEach(function(a){ a.forEach(function(r){ r.__seen = true; }); }); return out; })()'

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

run_js() {
    osascript -e "set js to \"$(esc "$1")\"" \
              -e 'tell application "Safari" to do JavaScript js in front document' 2>/dev/null
}

front_url() {
    osascript -e 'tell application "Safari" to get URL of front document' 2>/dev/null
}

echo "watching (every ${INTERVAL}s). use Safari normally; failures land in /tmp."
LAST_REPORT=0

while true; do
    U=$(front_url)
    case "$U" in
        *github.com*)
            run_js "$arm_js" >/dev/null
            V=$(run_js "$probe_js")
            case "$V" in
                FAIL*)
                    NOW=$(date +%s)
                    # rate-limit reports to one per 60s
                    if [ $((NOW - LAST_REPORT)) -gt 60 ]; then
                        LAST_REPORT=$NOW
                        OUT="/tmp/github-failure-$(date +%Y%m%d-%H%M%S).txt"
                        {
                            echo "=== github failure captured $(date) ==="
                            echo "$V" | sed 's/^FAIL //'
                            echo
                            echo "--- processes ---"
                            ps ax -o pid,etime,%cpu,rss,command | grep -E "[S]afari|[W]ebKit\.(WebContent|Networking)" | sed 's/\(.\{140\}\).*/\1/'
                            NETPID=$(ps ax -o pid,command | grep "[c]om.apple.WebKit.Networking" | awk '{print $1}' | head -1)
                            [ -n "$NETPID" ] && echo "proxy sockets: $(lsof -nP -a -p "$NETPID" -iTCP -sTCP:ESTABLISHED 2>/dev/null | grep -c 6531)"
                            echo "--- recent WebKit crashes ---"
                            ls -lt "$HOME/Library/Logs/DiagnosticReports/" 2>/dev/null | grep -i webkit | head -3
                        } > "$OUT" 2>&1
                        echo "FAILURE CAPTURED -> $OUT"
                    fi
                    ;;
            esac
            ;;
    esac
    sleep "$INTERVAL"
done
