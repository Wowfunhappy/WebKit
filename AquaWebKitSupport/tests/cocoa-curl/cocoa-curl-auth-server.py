#!/usr/bin/env python3
"""Loopback Basic/Digest/NTLM fixture."""
import base64,hashlib,http.server,json,os,pathlib,secrets,sys,threading
import spnego
from urllib.parse import urlsplit
PROXY = '--proxy' in sys.argv
AUTH_FIELD = 'Proxy-Authorization' if PROXY else 'Authorization'
CHALLENGE_FIELD = 'Proxy-Authenticate' if PROXY else 'WWW-Authenticate'
ROOT=pathlib.Path('/private/tmp/curl-auth-fixtures')
ROOT.mkdir(parents=True, exist_ok=True)
CREDENTIALS=ROOT/'ntlm-users.txt'
CREDENTIALS.write_text('CURL:curl-test:correct-password\n')
CREDENTIALS.chmod(0o600)
os.environ['NTLM_USER_FILE']=str(CREDENTIALS)
NONCE=secrets.token_hex(24)
REALM='Cocoa curl authentication fixture'
LOCK=threading.Lock()
class Handler(http.server.BaseHTTPRequestHandler):
 protocol_version='HTTP/1.1'
 def setup(self):super().setup();self.context=None
 def finish(self):super().finish()
 def reply(self,status,body=b'',headers=None):
  self.send_response(status)
  for name,value in (headers or {}).items():self.send_header(name,value)
  self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Content-Length',str(len(body)));self.end_headers()
  if self.command!='HEAD':self.wfile.write(body)
 def do_HEAD(self):self.do_GET()
 def do_POST(self):self.do_GET()
 def do_GET(self):
  body=self.rfile.read(int(self.headers.get('Content-Length','0')))
  auth=self.headers.get(AUTH_FIELD,'')
  method=urlsplit(self.path).path.strip('/')
  sticky='sticky' in self.path
  principal=None;responseHeaders={};error=None;digestURI=None
  try:
   if method=='basic':
    if auth=='Basic '+base64.b64encode(b'curl-test:correct-password').decode():principal='curl-test'
    else:responseHeaders[CHALLENGE_FIELD]='Basic realm="'+REALM+'"'
   elif method=='digest':
    from urllib.request import parse_http_list,parse_keqv_list
    fields=parse_keqv_list(parse_http_list(auth[7:])) if auth.startswith('Digest ') else {}
    digestURI=fields.get('uri')
    h=lambda value:hashlib.sha256(value.encode()).hexdigest()
    expected=h(':'.join((h('curl-test:'+REALM+':correct-password'),NONCE,fields.get('nc',''),fields.get('cnonce',''),'auth',h(self.command+':'+self.path))))
    if fields.get('username')=='curl-test' and fields.get('realm')==REALM and fields.get('nonce')==NONCE and fields.get('uri')==self.path and fields.get('qop')=='auth' and secrets.compare_digest(expected,fields.get('response','')):principal='curl-test'
    else:responseHeaders[CHALLENGE_FIELD]='Digest realm="'+REALM+'", nonce="'+NONCE+'", algorithm=SHA-256, qop="auth"'
   elif method=='ntlm':
    scheme='NTLM' if method=='ntlm' else 'Negotiate'
    if not auth.startswith(scheme+' '):responseHeaders[CHALLENGE_FIELD]=scheme
    else:
     if self.context is None:self.context=spnego.server(protocol='ntlm')
     token=self.context.step(base64.b64decode(auth.split(' ',1)[1]))
     if token:responseHeaders[CHALLENGE_FIELD]=scheme+' '+base64.b64encode(token).decode()
     if self.context.complete:principal=self.context.client_principal
    if sticky and not principal:responseHeaders['Set-Cookie']='auth-sequence='+('challenge' if self.context else 'initial')+'; Path=/; SameSite=Lax'
   else:self.reply(404,b'Unknown authentication method');return
   status=200 if principal else (407 if PROXY else 401)
   if principal and 'body' in self.path and body!=bytes(range(32)):status=403;error='Authentication did not preserve the complete binary request body.' 
   if principal and sticky and self.headers.get('Cookie')!='auth-sequence=challenge':status=403;error='The handshake cookie was not applied before the authenticated request.'
  except Exception as failure:status=403;error=repr(failure)
  with LOCK,(ROOT/('proxy-wire.jsonl' if PROXY else 'http-wire.jsonl')).open('a') as log:log.write(json.dumps({'method':self.command,'path':self.path,'authorization_scheme':auth.split(' ',1)[0] if auth else None,'cookie':self.headers.get('Cookie'),'body_bytes':len(body),'status':status,'principal':principal,'error':error,'digest_uri':digestURI})+'\n')
  payload=('<!doctype html><title>Authenticated</title><h1>'+str(principal)+'</h1>').encode() if status==200 else (error or '').encode()
  self.reply(status,payload,responseHeaders)
port=18985 if PROXY else 18984
server=http.server.ThreadingHTTPServer(('127.0.0.1',port),Handler)
print(('Proxy' if PROXY else 'Origin')+' Basic/Digest/NTLM fixture listening on '+str(port),flush=True)
server.serve_forever()
