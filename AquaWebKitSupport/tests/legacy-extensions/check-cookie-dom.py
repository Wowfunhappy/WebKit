#!/usr/bin/env python3
'Check that an embedded permitted web page receives network Strict cookies without exposing them through document.cookie.'
import importlib.util,json,os
from pathlib import Path
os.environ.update(LC_ALL='en_US.UTF-8',LC_CTYPE='en_US.UTF-8')
s=importlib.util.spec_from_file_location('p',str(Path(__file__).with_name('check-extension-cookies.py')));p=importlib.util.module_from_spec(s);s.loader.exec_module(p)
saved_policy=p.current_policy();w=None
try:
 p.policy(0);w=p.window(p.roots()['all'])
 p.js(w,'window.domResult=null;window.frameReady=false;addEventListener("message",e=>{if(e.data&&e.data.cookieResult)domResult=JSON.stringify(e.data.cookieResult)});window.f=document.createElement("iframe");f.onload=()=>frameReady=true;f.src="http://localhost:8877/cookie-frame.html";document.body.appendChild(f);"created"')
 p.wait(lambda:p.js(w,'frameReady')=='true','frame')
 p.js(w,'f.contentWindow.postMessage({cookieTest:"exercise",options:{base:"http://localhost:8877",id:"dom-network-control"}},"*");"sent"')
 r=json.loads(p.wait(lambda:p.js(w,'domResult||""'),'DOM result'))
 (p.WORK/'dom-control.json').write_text(json.dumps(r,indent=2));print('document.cookie',r.get('domCookies'));print('network',[(q['kind'],len(q.get('value',{}).get('cookies',{}))) for q in r['results'] if q['kind']=='fetch-include'])
 assert set(r['domCookies'])=={'extck_h_none','extck_h_unspecified'},r
 assert len(r['results'][0]['value']['cookies'])==8,r
finally:
 try:
  if w is not None:p.close(w)
 finally:p.policy(saved_policy)
