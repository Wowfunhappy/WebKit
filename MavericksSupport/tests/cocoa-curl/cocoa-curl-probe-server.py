#!/usr/bin/env python3
"""Raw loopback HTTP framing fixture. /probe/<case> answers with a fixed byte string from the table below,
/echo/<anything> answers with the request as JSON, /page runs every case through a browser's XHR/Fetch and
posts each result to /report. Every request, reply and result is appended as JSONL under --log-dir.
Usage: cocoa-curl-probe-server.py [--port 18981] [--log-dir /private/tmp/cocoa-curl-probe]
Serves cocoa-curl-transfer, cocoa-curl-resource-handle, cocoa-curl-network-data-task, cocoa-curl-handoff,
cocoa-curl-upload and cocoa-curl-legacy-ledger."""
import argparse, gzip, hashlib, json, pathlib, socket, threading, time
from urllib.parse import urlsplit, parse_qs
ROOT = pathlib.Path('/private/tmp/cocoa-curl-probe')
LOCK = threading.Lock()

def log(name, obj):
    with LOCK:
        with (ROOT / name).open('a') as f:
            f.write(json.dumps(obj, ensure_ascii=True, sort_keys=True) + '\n')

def response(fields=b'', body=b'HELLO', status=b'HTTP/1.1 200 OK', length=True, ctype=b'text/plain'):
    return status+b'\r\nContent-Type: '+ctype+b'\r\nCache-Control: no-store\r\n'+fields+(b'Content-Length: '+str(len(body)).encode()+b'\r\n' if length else b'')+b'Connection: close\r\n\r\n'+body

CASES = {}
CASES['_download_404_body'] = response(status=b'HTTP/1.1 404 Not Found')
CASES['_download_gzip_mime'] = response(body=gzip.compress(b'ENCODED FILE'), ctype=b'application/x-gzip')
CASES['_download_gzip_encoding'] = response(fields=b'Content-Encoding: gzip\r\n',body=gzip.compress(b'ENCODED HTTP'),ctype=b'application/octet-stream')

def add(name, fields=b'', body=b'HELLO', status=b'HTTP/1.1 200 OK', length=True):
    CASES[name] = response(fields, body, status, length)
add('baseline')
add('fold_sp', b'X-A: one\r\n two\r\nX-End: yes\r\n')
add('fold_tab', b'X-A: one\r\n\ttwo\r\nX-End: yes\r\n')
for name, cl in [('cl_same',b'5\r\nContent-Length: 5'),('cl_conflict',b'5\r\nContent-Length: 3'),('cl_conflict_reverse',b'3\r\nContent-Length: 5'),('cl_list_same',b'5, 5'),('cl_list_conflict',b'5, 3'),('cl_plus',b'+5'),('cl_zeroes',b'0005'),('cl_ows',b' \t5 \t'),('cl_negative',b'-1')]:
    add(name, b'Content-Length: '+cl+b'\r\n',length=False)
add('te_cl',b'Transfer-Encoding: chunked\r\nContent-Length: 99\r\n',b'5\r\nHELLO\r\n0\r\n\r\n',length=False)
add('te_unknown',b'Transfer-Encoding: frobnicate\r\n',length=False)
add('te_invalid',b'Transfer-Encoding: chunked,\r\n',b'5\r\nHELLO\r\n0\r\n\r\n',length=False)
add('te_unknown_chunked',b'Transfer-Encoding: frobnicate, chunked\r\n',b'5\r\nHELLO\r\n0\r\n\r\n',length=False)
for name,body in [('chunk_valid',b'5\r\nHELLO\r\n0\r\n\r\n'),('chunk_bad_size',b'Z\r\nHELLO\r\n0\r\n\r\n'),('chunk_partial_size',b'5Z\r\nHELLO\r\n0\r\n\r\n'),('chunk_extension',b'5;foo=bar;quoted="a;b"\r\nHELLO\r\n0\r\n\r\n'),('chunk_trailer',b'5\r\nHELLO\r\n0\r\nX-Trailer: yes\r\n\r\n'),('chunk_missing_zero',b'5\r\nHELLO\r\n')]:
    add(name,b'Transfer-Encoding: chunked\r\n'+(b'Trailer: X-Trailer\r\n' if name=='chunk_trailer' else b''),body,length=False)
add('status_no_reason',status=b'HTTP/1.1 200 ')
add('status_no_reason_no_sp',status=b'HTTP/1.1 200')
add('status_two_digits',status=b'HTTP/1.1 20 Odd')
add('status_four_digits',status=b'HTTP/1.1 2000 Odd')
CASES['http09_body'] = b'HELLO\n'
CASES['http09_empty'] = b''
add('name_space',b'X-A : one\r\nX-End: yes\r\n')
add('name_control',b'X-\x01A: one\r\nX-End: yes\r\n')
add('value_nul',b'X-A: one\x00two\r\nX-End: yes\r\n')
add('info_100')
CASES['info_100'] = b'HTTP/1.1 100 Continue\r\nX-Interim: yes\r\n\r\n'+CASES['info_100']
add('info_103')
CASES['info_103'] = b'HTTP/1.1 103 Early Hints\r\nLink: </hint.js>; rel=preload; as=script\r\nX-Interim: yes\r\n\r\n'+CASES['info_103']
add('body_204',status=b'HTTP/1.1 204 No Content')
add('body_304',status=b'HTTP/1.1 304 Not Modified')
add('duplicate_headers',b'X-Multi: one\r\nX-Multi: two\r\nX-Multi: three\r\n')
add('cookies_separate',b'Set-Cookie: clg_a=1; Path=/; Max-Age=600\r\nSet-Cookie: clg_b=2; Expires=Wed, 09 Jun 2027 10:18:14 GMT; Path=/\r\nSet-Cookie: clg_h=3; Path=/; HttpOnly; Max-Age=600\r\n')
add('cookies_comma_path',b'Set-Cookie: clg_p=one; Path=/probe, clg_phantom=oops; Max-Age=600\r\nSet-Cookie: clg_q=two; Path=/; Max-Age=600\r\n')
add('cookies_last_attr',b'Set-Cookie: clg_last=ok; Path=/wrong; Path=/; Max-Age=600\r\n')
add('cookies_control',b'Set-Cookie: clg_ctl=bad\x01value; Path=/; Max-Age=600\r\n')
add('cookies_prefix',b'Set-Cookie: __Host-clg_bad=1; Path=/; Max-Age=600\r\n')
for status in (303,307,308):
    add('redirect_'+str(status),b'Location: /echo/redirect_'+str(status).encode()+b'\r\n',body=b'',status=b'HTTP/1.1 '+str(status).encode()+b' Redirect')
for name,loc in [('location_space',b'/echo/space here'),('location_utf8',b'/echo/caf\xc3\xa9'),('location_latin1',b'/echo/caf\xe9'),('location_cr',b'/echo/cr\rX-Injected: yes'),('location_data',b'data:text/plain,LOCAL'),('location_ftp',b'ftp://127.0.0.1:18892/local'),('location_https',b'https://127.0.0.1:18892/local')]:
    add(name,b'Location: '+loc+b'\r\n',body=b'',status=b'HTTP/1.1 302 Found')

# Follow-up variants: separate syntax, delimitation and decoded-length effects.
for name, body in [('chunk_ext_token',b'5;foo=bar\r\nHELLO\r\n0\r\n\r\n'),('chunk_ext_bare',b'5;foo\r\nHELLO\r\n0\r\n\r\n'),('chunk_ext_quote',b'5;foo="bar"\r\nHELLO\r\n0\r\n\r\n'),('chunk_ext_two',b'5;foo=bar;baz=qux\r\nHELLO\r\n0\r\n\r\n'),('chunk_ext_quote_semi',b'5;foo="a;b"\r\nHELLO\r\n0\r\n\r\n'),('chunk_short_data',b'5\r\nHEL'),('chunk_no_final_crlf',b'5\r\nHELLO\r\n0\r\n')]:
    add(name,b'Transfer-Encoding: chunked\r\n',body,length=False)
for n in (0,3,5,15):
    add('te_cl_'+str(n),b'Transfer-Encoding: chunked\r\nContent-Length: '+str(n).encode()+b'\r\n',b'5\r\nHELLO\r\n0\r\n\r\n',length=False)
add('cl_plus_short',b'Content-Length: +3\r\n',length=False)
add('cl_alpha',b'Content-Length: abc\r\n',length=False)
add('cl_short_body',b'Content-Length: 9\r\n',length=False)
add('body_204_no_cl',status=b'HTTP/1.1 204 No Content',length=False)
add('body_304_no_cl',status=b'HTTP/1.1 304 Not Modified',length=False)
add('value_control',b'X-A: one\x01two\r\n')
add('cookies_comma_ext',b'Set-Cookie: clg_ext=one; Note=x, clg_ghost=two; Path=/; Max-Age=600\r\nSet-Cookie: clg_end=three; Path=/; Max-Age=600\r\n')
add('cookies_comma_expires',b'Set-Cookie: clg_date=one; Expires=Wed, 09 Jun 2027 10:18:14 GMT; Path=/\r\nSet-Cookie: clg_next=two; Path=/; Max-Age=600\r\n')
add('cookies_echo_marker')
# A logout: the response that sets a cookie, and the response that expires it.
add('cookie_logout_set', b'Set-Cookie: clg_logout=live; Path=/; Max-Age=600\r\n')
add('cookie_logout_clear', b'Set-Cookie: clg_logout=; Path=/; Max-Age=0\r\n')

add('te_parameter',b'Transfer-Encoding: chunked;foo=bar\r\n',b'5\r\nHELLO\r\n0\r\n\r\n',length=False)
add('te_bad_token',b'Transfer-Encoding: chu nked\r\n',b'5\r\nHELLO\r\n0\r\n\r\n',length=False)
# Remove only this harness's cookies, including HttpOnly and non-root paths.
COOKIE_NAMES=['clg_'+n for n in ['a','b','h','p','phantom','q','last','ctl','ext','ghost','end','date','next']]+['__Host-clg_bad']
COOKIE_PATHS=['/','/probe','/wrong']
add('cleanup',b''.join(b'Set-Cookie: '+n.encode()+b'=; Path='+p.encode()+b'; Max-Age=0\r\n' for n in COOKIE_NAMES for p in COOKIE_PATHS))

add('cleanup_comma',b'Set-Cookie: clg_p=; Path=/probe, clg_phantom=oops; Max-Age=0\r\n')


# Full Cocoa switchover acceptance cases. These are unconditional browser requests.
add('value_bare_cr', b'X-A: original\rX-Injected: fabricated\r\nX-End: yes\r\n')
add('value_bare_lf', b'X-A: original\nX-Injected: fabricated\r\nX-End: yes\r\n')
add('cookies_single_comma_attribute', b'Set-Cookie: clg_single=one; Note=legal, clg_fabricated=two; Path=/; Max-Age=600\r\n')
for count in (1, 15, 16, 17, 18, 19, 20, 21):
    names = ['redirect_limit_'+str(count)] + ['_hop_'+str(count)+'_'+str(i) for i in range(1,count)]
    for i,name in enumerate(names):
        target = '/probe/'+names[i+1] if i+1<len(names) else '/echo/redirect_done_'+str(count)
        add(name, b'Location: '+target.encode()+b'\r\n', b'', b'HTTP/1.1 302 Found')
COOKIE_NAMES += ['clg_single','clg_fabricated']
add('cleanup', b''.join(b'Set-Cookie: '+name.encode()+b'=; Path='+path.encode()+b'; Max-Age=0\r\n' for name in COOKIE_NAMES for path in COOKIE_PATHS))

PAGE = r'''<!doctype html><meta charset="utf-8"><title>Cocoa curl conformance</title>
<body><pre id="out">Running local probes</pre><script>
var params=new URLSearchParams(location.search), browser=params.get('browser')||'unknown', run=params.get('run')||'1';
window.R={ua:navigator.userAgent,browser:browser,run:run,results:[],done:false};
var cases=__CASES__;
var only=params.get('only'); if(only)cases=only.split(',');
function post(path,obj){var x=new XMLHttpRequest();x.open('POST',path,true);x.setRequestHeader('Content-Type','application/json');x.send(JSON.stringify(obj));}
function clean(){document.cookie.split(';').forEach(function(v){var n=v.split('=')[0].trim();if(n.indexOf('clg_')===0||n.indexOf('__Host-clg_')===0)document.cookie=n+'=; Path=/; Max-Age=0';});}
clean();
function xhrProbe(name){return new Promise(function(resolve){
 var method=(name.indexOf('redirect_')===0?'POST':name==='request_mixed'?'pRoPfInD':name.indexOf('request_post_')===0?'POST':'GET');
 var path=(name.indexOf('request_')===0?'/echo/':'/probe/')+name+'?browser='+browser+'&run='+run;
 var x=new XMLHttpRequest(), r={name:name,method:method}; x.open(method,path,true);x.timeout=6000;
 if(method==='POST'&&name.indexOf('redirect_')===0)x.setRequestHeader('Content-Type','application/octet-stream');
 if(name==='request_post_explicit')x.setRequestHeader('Content-Type','application/custom');
 x.onreadystatechange=function(){if(x.readyState===2){r.atHeaders={status:x.status,statusText:x.statusText,headers:x.getAllResponseHeaders()};}};
 function finish(event){r.event=event;r.status=x.status;r.statusText=x.statusText;r.headers=x.getAllResponseHeaders();r.body=x.responseText;r.url=x.responseURL;r.cookie=document.cookie;r.setCookie=x.getResponseHeader('Set-Cookie');
 R.results.push(r);post('/report?browser='+browser+'&run='+run,r);document.getElementById('out').textContent=JSON.stringify(R,null,2);resolve();}
 x.onload=function(){finish('load')};x.onerror=function(){finish('error')};x.ontimeout=function(){finish('timeout')};x.onabort=function(){finish('abort')};
 try{x.send(method==='POST'?new Uint8Array([65,0,66,255]).buffer:null)}catch(e){r.exception=String(e);finish('exception')}
 });}

function fetchProbe(name){
 var method=name.indexOf('redirect_')===0?'POST':name==='request_mixed'?'pRoPfInD':name.indexOf('request_post_')===0?'POST':'GET';
 var path=(name.indexOf('request_')===0?'/echo/':'/probe/')+name+'?browser='+browser+'&run='+run;
 var r={name:name,api:'fetch',method:method},c=new AbortController(),timer=setTimeout(function(){c.abort()},6000);
 var opts={method:method,signal:c.signal};
 if(method==='POST'){opts.body=new Uint8Array([65,0,66,255]).buffer;if(name.indexOf('redirect_')===0)opts.headers={'Content-Type':'application/octet-stream'};if(name==='request_post_explicit')opts.headers={'Content-Type':'application/custom'};}
 return fetch(path,opts).then(function(x){r.status=x.status;r.statusText=x.statusText;r.url=x.url;r.headers=Array.from(x.headers.entries());r.setCookie=x.headers.get('Set-Cookie');return x.text()}).then(function(t){r.body=t;r.event='load'},function(e){r.event='error';r.error=String(e)}).then(function(){clearTimeout(timer);r.cookie=document.cookie;R.results.push(r);post('/report?browser='+browser+'&run='+run,r);document.getElementById('out').textContent=JSON.stringify(R,null,2);});
}
function probe(name){return params.get('api')==='fetch'?fetchProbe(name):xhrProbe(name)}
var chain=Promise.resolve();cases.forEach(function(n){chain=chain.then(function(){return probe(n)});});
chain.then(function(){return probe('request_get')}).then(function(){R.done=true;post('/complete?browser='+browser+'&run='+run,R);document.getElementById('out').textContent=JSON.stringify(R,null,2);});
</script>'''

def handle(c,addr):
    target=''; request=b''
    try:
        c.settimeout(8)
        while b'\r\n\r\n' not in request:
            d=c.recv(65536)
            if not d:return
            request+=d
        head,body=request.split(b'\r\n\r\n',1)
        first=head.split(b'\r\n',1)[0]
        method,target,_=first.decode('latin1').split(' ',2)
        headers={}
        for line in head.split(b'\r\n')[1:]:
            k,v=line.split(b':',1);headers[k.decode('latin1').lower()]=v.strip().decode('latin1')
        if headers.get('expect','').lower() == '100-continue':
            c.sendall(b'HTTP/1.1 100 Continue\r\n\r\n')
        length=int(headers.get('content-length','0'))
        while len(body)<length:
            d=c.recv(65536)
            if not d:break
            body+=d;request+=d
        parsed=urlsplit(target); path=parsed.path;query=parse_qs(parsed.query)
        log('requests.jsonl',dict(time=time.time(),target=target,method=method,headers=headers,request_repr=repr(request),request_hex=request.hex(),body_hex=body.hex()))
        if path=='/page':
            names=[n for n in CASES if not n.startswith(('cleanup','_'))]+['request_mixed','request_post_binary','request_post_explicit']
            payload=response(body=PAGE.replace('__CASES__',json.dumps(names)).encode(),ctype=b'text/html; charset=utf-8')
        elif path.startswith('/probe/'):
            payload=CASES[path.rsplit('/',1)[-1]]
        elif path.startswith('/echo/'):
            echo=dict(method=method,target=target,headers=headers,body_hex=body.hex())
            payload=response(body=json.dumps(echo,sort_keys=True).encode(),ctype=b'application/json')
        elif path in ('/report','/complete'):
            obj=json.loads(body.decode());obj['query']=query;log('results.jsonl' if path=='/report' else 'complete.jsonl',obj)
            payload=response(body=b'OK')
        elif path=='/hint.js':payload=response(body=b'window.HINT=true;',ctype=b'text/javascript')
        else:payload=response(body=b'not found',status=b'HTTP/1.1 404 Not Found')
        c.sendall(payload)
        log('wire.jsonl',dict(time=time.time(),target=target,sent_len=len(payload),sent_repr=repr(payload),sent_hex=payload.hex(),sha256=hashlib.sha256(payload).hexdigest()))
        try:c.shutdown(socket.SHUT_WR)
        except OSError:pass
    except Exception as e:log('server_errors.jsonl',dict(time=time.time(),target=target,error=repr(e),request_repr=repr(request)))
    finally:c.close()

def main():
    global ROOT
    p=argparse.ArgumentParser();p.add_argument('--port',type=int,default=18981);p.add_argument('--log-dir',type=pathlib.Path,default=ROOT);a=p.parse_args()
    ROOT=a.log_dir;ROOT.mkdir(parents=True,exist_ok=True)
    (ROOT/'cases.json').write_text(json.dumps({k:dict(repr=repr(v),hex=v.hex(),sha256=hashlib.sha256(v).hexdigest()) for k,v in CASES.items()},indent=2))
    s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('127.0.0.1',a.port));s.listen(64)
    print('listening 127.0.0.1:'+str(a.port),flush=True)
    while True:
        c,addr=s.accept();threading.Thread(target=handle,args=(c,addr),daemon=True).start()
if __name__=='__main__':main()
