#!/usr/bin/env python3
"Check cookie permissions after terminating Safari's Networking process. Run after seeding the cookie fixtures."
import importlib.util,json,os,time,subprocess
from pathlib import Path
os.environ.update(LC_ALL='en_US.UTF-8',LC_CTYPE='en_US.UTF-8')
s=importlib.util.spec_from_file_location('p',str(Path(__file__).with_name('check-extension-cookies.py')));p=importlib.util.module_from_spec(s);s.loader.exec_module(p)
w=p.window(p.roots()['all']);rows=[]
def run(label,expression):
 result=p.exercise(w,expression);rows.append(dict(label=label,result=result));(p.WORK/'network-restart.json').write_text(json.dumps(rows,indent=2));print(label,[(q['kind'],len(q.get('value',{}).get('cookies',{})),q.get('error')) for q in result.get('results',[]) if q['kind'] in ['fetch-include','websocket']],flush=True)
try:
 run('before',"cookieExercise({base:'http://localhost:8877',id:'network-restart-before'})")
 candidates=[int(line.split()[0]) for line in subprocess.check_output(['ps','-axo','pid=,comm='],text=True).splitlines() if line.split()[-1]=='com.apple.WebKit.Networking']
 assert len(candidates)==1, candidates
 pid=candidates[0]
 os.kill(pid,15)
 for i in range(100):
  try:os.kill(pid,0)
  except ProcessLookupError:break
  time.sleep(.1)
 else:raise RuntimeError('Networking did not exit')
 print('terminated Networking',pid,flush=True)
 run('after-tab',"cookieExercise({base:'http://localhost:8877',id:'network-restart-after-tab'})")
 run('after-shared',"cookieWorker({base:'http://localhost:8877',id:'network-restart-after-shared'},true)")
 run('after-global',"browser.runtime.sendMessage({cookieTest:'global',options:{base:'http://localhost:8877',id:'network-restart-after-global'}})")
 for row in rows:
  for q in row['result']['results']:
   if q['kind'] in ['fetch-include','websocket']:
    assert all('extck_h_'+kind+suffix in q.get('value',{}).get('cookies',{}) for kind in ['unspecified','none','lax','strict'] for suffix in ['', '_http']), row['label']
finally:p.close(w)
