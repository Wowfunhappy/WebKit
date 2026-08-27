# Serves the generated stream on 8900; key files answer after a delay so key fetches overlap, and
# /live/*.m3u8 serves the playlists as live until LIVE_REFRESHES requests have been answered.
import http.server, os, sys, time
ROOT=os.path.join(os.path.dirname(os.path.abspath(__file__)),'out'); DELAY=float(sys.argv[1]) if len(sys.argv)>1 else 1.5; LIVE_REFRESHES=int(sys.argv[2]) if len(sys.argv)>2 else 3
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self,*a,**k): super().__init__(*a,directory=ROOT,**k)
    live_hits={}
    def do_GET(self):
        if self.path.startswith('/key/'): time.sleep(DELAY)
        if self.path=='/reset':
            H.live_hits={}; self.send_response(204); self.end_headers(); return
        if self.path.startswith('/live/'):
            # A live playlist: the VOD playlist without its ENDLIST for the first LIVE_REFRESHES
            # requests, then with it, so the demuxer sees a live-to-VOD transition mid-play.
            name=self.path[len('/live/'):].replace('.m3u8','')
            src={'video':'video/prog.m3u8','video-hi':'video/prog-hi.m3u8','audio':'audio/prog.m3u8'}.get(name)
            if not src: self.send_error(404); return
            n=H.live_hits.get(name,0); H.live_hits[name]=n+1
            body=open(os.path.join(ROOT,src)).read()
            if n < LIVE_REFRESHES:
                body='\n'.join(l for l in body.splitlines() if l not in ('#EXT-X-ENDLIST','#EXT-X-PLAYLIST-TYPE:VOD'))+'\n'
            data=body.encode(); self.send_response(200); self.send_header('Content-Type','application/vnd.apple.mpegurl'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data); return
        super().do_GET()
    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin','*'); self.send_header('Cache-Control','no-store'); super().end_headers()
    def log_message(self,*a): pass
http.server.ThreadingHTTPServer(('127.0.0.1',8900),H).serve_forever()
