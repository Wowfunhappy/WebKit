/* Local adaptive media regression fixture; jobs and expectations are supplied by the driver. */
(async function () {
'use strict';
const endpoint='http://localhost:8862',context=window.testContext,base=safari.extension.baseURI;
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function report(value){value.context=context;value.base=base;document.getElementById('log').textContent=JSON.stringify(value,null,2);await fetch(endpoint+'/report',{method:'POST',body:JSON.stringify(value)});}
async function until(check,v,limit=15000){const end=Date.now()+limit;while(!check()){if(v.error)throw new Error('media error '+v.error.code+': '+v.error.message);if(Date.now()>end)throw new Error('deadline');await sleep(25);}}
function state(v){return {wall:Date.now(),buffered:Array.from({length:v.buffered.length},(_,i)=>[v.buffered.start(i),v.buffered.end(i)]),droppedFrames:v.getVideoPlaybackQuality().droppedVideoFrames,ready:v.readyState,network:v.networkState,ended:v.ended,time:v.currentTime,duration:v.duration,width:v.videoWidth,height:v.videoHeight,error:v.error&&v.error.code,src:v.currentSrc,frames:v.getVideoPlaybackQuality().totalVideoFrames};}
async function play(job){
 const v=document.createElement('video'),events=[],row={job:job.id,path:job.path,url:job.url,relative:!!job.relative,steps:[],events};
 v.preload='auto';v.controls=true;v.muted=false;v.style.cssText='position:fixed;top:100px;left:10px;width:480px;z-index:1000';document.body.append(v);
 for(const name of ['loadedmetadata','playing','waiting','seeked','ended','error'])v.addEventListener(name,()=>events.push({name,state:state(v)}));
 let objectURL;
 try{
  let url=job.url||(job.relative?job.path:base+job.path);
  if(job.blob){const data=await(await fetch(base+job.path)).arrayBuffer();objectURL=URL.createObjectURL(new Blob([data],{type:job.blobType||''}));url=objectURL;}
  if(job.type){const s=document.createElement('source');s.type=job.type;s.src=url;v.append(s);}else v.src=url;
  v.load();await until(()=>v.readyState>=1,v);
  if(job.subtitles)for(const t of v.textTracks)t.mode='showing';
  let playError;const start=v.play();if(start)start.catch(e=>playError=String(e));
  await until(()=>v.currentTime>.25||v.ended||playError,v);if(playError)throw new Error(playError);
  row.initial=state(v);
  if(job.observe){row.observations=[];const end=Date.now()+job.observe;while(Date.now()<end&&!v.ended){if(v.error)throw new Error('media error '+v.error.code);row.observations.push(state(v));await sleep(200);}}
  else for(const fraction of [.6,.9]){v.pause();const target=v.duration*fraction;v.currentTime=target;await until(()=>!v.seeking&&v.readyState>=2&&Math.abs(v.currentTime-target)<.5,v);const seekTime=v.currentTime;const p=v.play();if(p)p.catch(e=>playError=String(e));await until(()=>v.currentTime>seekTime+.05||v.ended||playError,v);if(playError)throw new Error(playError);row.steps.push({fraction,target,seekTime,state:state(v)});}
  if(job.observe&&!v.ended)throw new Error('Playback did not reach EOS');
  if(job.observe&&new Set(row.observations.map(x=>x.width)).size<2)throw new Error('No variant resolution switch observed');
  row.textTracks=[...v.textTracks].map(t=>({label:t.label,language:t.language,mode:t.mode,cues:t.cues&&[...t.cues].map(c=>({start:c.startTime,end:c.endTime,text:c.text}))}));if(job.subtitles&&!row.textTracks.some(t=>t.cues&&t.cues.length))throw new Error('No subtitle cues loaded');row.ok=true;
 }catch(e){row.failure=String(e);row.ok=false;}
 row.final=state(v);v.pause();v.removeAttribute('src');v.replaceChildren();v.load();v.remove();if(objectURL)URL.revokeObjectURL(objectURL);
 await report(row);
}
await report({ready:true,types:Object.fromEntries(['application/vnd.apple.mpegurl','application/dash+xml','video/mp4','video/webm'].map(t=>[t,document.createElement('video').canPlayType(t)]))});
while(true){try{const job=await(await fetch(endpoint+'/next?context='+context)).json();if(job){if(job.action==='popover')safari.extension.toolbarItems[0].showPopover();else if(job.action==='play')await play(job);await report({job:job.id,done:true});}}catch(e){console.error(e);}await sleep(300);}
}());
