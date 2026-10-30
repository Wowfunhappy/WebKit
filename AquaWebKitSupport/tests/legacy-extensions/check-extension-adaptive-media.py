#!/usr/bin/env python3
"""Local controller/server for generated extension adaptive media fixtures.

serve --fixture DIR --results DIR: hosts HTTP fixtures and extension job queues.
run --context {tab,global,popover} --id ID --path PATH [--http] [--relative]
    expects playback and seeking, unless --expect-failure is specified.
render --installed DIR --base URI: fills absolute extension URIs after installation.
All outputs and generated extensions are outside the repository by explicit paths.
"""
import argparse
import collections
import http.server
import json
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request


def serve(args):
    fixture=args.fixture.resolve(); args.results.mkdir(parents=True,exist_ok=True)
    queues=collections.defaultdict(collections.deque); events=[];lock=threading.Lock()
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self,*unused): pass
        def reply(self,obj):
            data=json.dumps(obj).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Access-Control-Allow-Origin','*');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
        def do_POST(self):
            obj=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            with lock:
                if self.path=='/enqueue':queues[obj['context']].append(obj)
                else:
                    obj['serverTime']=time.time();events.append(obj)
                    with (args.results/'events.jsonl').open('a') as f:f.write(json.dumps(obj)+'\n')
            self.reply({'ok':True})
        def do_GET(self):
            u=urllib.parse.urlsplit(self.path);q=urllib.parse.parse_qs(u.query)
            if u.path=='/next':
                with lock:
                    key=q.get('context',[''])[0];obj=queues[key].popleft() if queues[key] else None
                self.reply(obj);return
            if u.path=='/events':
                with lock:obj=list(events)
                self.reply(obj);return
            mode,_,relative=u.path.lstrip('/').partition('/')
            if mode not in ['media','switch'] or Path(relative).is_absolute() or '..' in Path(relative).parts:self.send_error(404);return
            path=fixture/relative;template=path.with_name(path.name+'.template')
            if template.exists():data=template.read_text().replace('{{BASE}}',args.url+'/'+mode+'/').encode()
            elif path.is_file():data=path.read_bytes()
            else:self.send_error(404);return
            length=len(data);start=0;end=length-1;status=200;request_range=self.headers.get('Range')
            if request_range:
                match=re.fullmatch(r'bytes=(\d+)-(\d*)',request_range)
                if not match:self.send_error(416);return
                start=int(match[1]);end=min(int(match[2]) if match[2] else end,end)
                if start>end:self.send_error(416);return
                status=206
            content_type={'.m3u8':'application/vnd.apple.mpegurl','.mpd':'application/dash+xml','.ts':'video/mp2t','.mp4':'video/mp4','.m4s':'video/mp4','.webm':'video/webm','.vtt':'text/vtt'}.get(path.suffix,'application/octet-stream')
            self.send_response(status);self.send_header('Content-Type',content_type);self.send_header('Content-Length',str(end-start+1));self.send_header('Accept-Ranges','bytes');self.send_header('Cache-Control','no-store');self.send_header('Access-Control-Allow-Origin','*')
            if status==206:self.send_header('Content-Range','bytes %d-%d/%d'%(start,end,length))
            self.end_headers()
            began=time.time();sent=0;slow=mode=='switch' and '/high/seg-' in relative and int(re.search(r'seg-(\d+)',relative)[1])>=2
            try:
                for at in range(start,end+1,8192):
                    chunk=data[at:min(at+8192,end+1)];self.wfile.write(chunk);self.wfile.flush();sent+=len(chunk)
                    if slow:time.sleep(len(chunk)/30000)
            except (BrokenPipeError,ConnectionResetError):pass
            finally:
                with lock:
                    with (args.results/'requests.jsonl').open('a') as f:f.write(json.dumps({'path':u.path,'range':request_range,'status':status,'bytes':sent,'seconds':time.time()-began,'slow':slow,'time':began})+'\n')
    http.server.ThreadingHTTPServer(('127.0.0.1',urllib.parse.urlsplit(args.url).port or 8862),Handler).serve_forever()


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--url',default='http://localhost:8862');subs=p.add_subparsers(dest='command',required=True)
    s=subs.add_parser('serve');s.add_argument('--fixture',type=Path,required=True);s.add_argument('--results',type=Path,required=True)
    s=subs.add_parser('render');s.add_argument('--installed',type=Path,required=True);s.add_argument('--base',required=True)
    s=subs.add_parser('run');s.add_argument('--context',choices=['tab','global','popover'],required=True);s.add_argument('--id',required=True);s.add_argument('--path',default='hls/ts/master.m3u8');s.add_argument('--http',action='store_true');s.add_argument('--relative',action='store_true');s.add_argument('--switch',action='store_true');s.add_argument('--subtitles',action='store_true');s.add_argument('--type');s.add_argument('--blob',action='store_true');s.add_argument('--blob-type',default='');s.add_argument('--expect-failure',action='store_true');s.add_argument('--output',type=Path,required=True)
    s=subs.add_parser('popover')
    args=p.parse_args()
    if args.command=='serve':serve(args);return
    if args.command=='render':
        subprocess.run([sys.executable,str(Path(__file__).with_name('generate-extension-adaptive-media.py')),'--output',str(args.installed),'--render-base',args.base],check=True);return
    job={'context':'global','action':'popover','id':'show-popover'} if args.command=='popover' else {'context':args.context,'action':'play','id':args.id,'path':args.path,'relative':args.relative,'subtitles':args.subtitles,'type':args.type,'blob':args.blob,'blobType':args.blob_type}
    if args.command=='run' and args.http:job['url']=args.url+('/switch/' if args.switch else '/media/')+args.path
    if args.command=='run' and args.switch:job['observe']=90000
    json.load(urllib.request.urlopen(urllib.request.Request(args.url+'/enqueue',data=json.dumps(job).encode())))
    if args.command=='popover':return
    deadline=time.time()+150
    while time.time()<deadline:
        rows=[x for x in json.load(urllib.request.urlopen(args.url+'/events')) if x.get('job')==args.id]
        if any(x.get('done') for x in rows):
            args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(rows,indent=2));result=next(x for x in rows if 'ok' in x)
            passed=result['ok'] != args.expect_failure
            print(args.id, 'PASS' if passed else 'FAIL',result.get('failure',''),result['final'])
            if not passed:raise SystemExit(1)
            return
        time.sleep(.25)
    raise SystemExit('No result before driver deadline: '+args.id)

if __name__=='__main__':main()
