/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#if PLATFORM(MAC)

namespace WebCore {

// MAVERICKS_BACKPORT: single source of truth for the classic-frontend bridge user script.
//
// The backport deliberately ships the system stock (Safari 8-era) WebInspectorUI frontend for its
// Aqua toolbar + pill tab icons, run against the modern WebKit backend. The classic frontend
// predates today's InspectorFrontendHost IDL and inspector protocol, so this document-start user
// script bridges the drift and paints the #52/#66/#69 unified titlebar+toolbar. It is injected into
// the frontend page's MAIN world (before the frontend's own document-start scripts) by both ports:
//   - WebKit (WK2): as a WKUserScript in WKInspectorViewController's webViewConfiguration.
//   - WebKitLegacy (WK1): via +[WebView _addUserScriptToGroup:...] in the standard world.
// Injecting it as a native user script is CSP-exempt, so the frontend page's own
// `script-src 'self'` (satisfied for its own resources under the real-origin inspector-resource://
// scheme both ports serve it from) is left untouched. Both ports consume this one string so the
// bridge cannot drift between frameworks.
//
// Three parts:
//  1. Unified titlebar+toolbar chrome (#52/#66/#69). Adds the measured Aqua gradient + a 22px
//     #wk-titlebar strip as body's first child (stock 56px toolbar untouched below it), the window
//     title fed from InspectorFrontendHost.inspectedURLChanged, and background mousedowns routed to
//     IFH.startWindowDrag() (undocked only). Gradient endpoints measured off a native Mavericks
//     unified titlebar (Finder, lossless samples, frontmost-verified): ACTIVE = 1px rgb(242) bevel,
//     rgb(234)->rgb(176), 1px rgb(105) border; INACTIVE = rgb(240)->rgb(223), 1px rgb(166) border.
//  2. InspectorFrontendHost drift. The classic frontend calls platform()/localizedStringsURL()/
//     inspectorBackendCommandsURL() as METHODS and uses a few IFH methods the modern host dropped;
//     the modern IDL exposes attribute getters. Wrap the attributes as methods, stub the removed.
//  3. Protocol bridge. The classic frontend sends bare per-domain commands ({method:'DOM.getDocument'});
//     the modern backend routes per-target via Target.sendMessageToTarget and answers with
//     Target.dispatchMessageFromTarget. Wrap outgoing non-Target/Browser commands (queueing until
//     Target.targetCreated supplies the targetId) and unwrap incoming ones. Two CSS payload shapes
//     drifted since the classic frontend: CSS.SelectorList.selectors became CSSSelector objects
//     ({text,specificity}) where the frontend expects strings, and the author stylesheet origin was
//     renamed "regular" -> "author"; fixSel() flattens the selectors and maps the origin back.
//
// Every failure path surfaces via console.error (into the frontend page's own console) rather than
// being swallowed, so a translation bug is diagnosable instead of a silently-dropped message.
inline const char* classicInspectorFrontendBridgeScriptUTF8()
{
    return R"WKIB((function(){
var wkCSS="body:not(.docked){background-image:-webkit-linear-gradient(top,rgb(242,242,242),rgb(234,234,234) 1px,rgb(176,176,176) 77px,rgb(105,105,105) 77px,rgb(105,105,105) 78px);background-repeat:no-repeat;background-size:100% 78px;border-top-left-radius:4px;border-top-right-radius:4px;}body:not(.docked).window-inactive{background-image:-webkit-linear-gradient(top,rgb(240,240,240),rgb(223,223,223) 77px,rgb(166,166,166) 77px,rgb(166,166,166) 78px);}body.docked{background-color:white;}#wk-titlebar{height:22px;-webkit-flex:none;text-align:center;font-family:'Lucida Grande';font-size:13px;line-height:22px;color:rgba(0,0,0,0.85);text-shadow:rgba(255,255,255,0.5) 0 1px 0;padding:0 80px;overflow:hidden;white-space:nowrap;text-overflow:ellipsis;cursor:default;}body.window-inactive #wk-titlebar{color:rgba(0,0,0,0.5);}body.docked #wk-titlebar{display:none;}";
function wkAddStyle(){if(document.getElementById('wk-unified-style'))return;var st=document.createElement('style');st.id='wk-unified-style';st.textContent=wkCSS;(document.head||document.documentElement).appendChild(st);}
if(document.documentElement)wkAddStyle();else document.addEventListener('DOMContentLoaded',wkAddStyle);
var IFH=window.InspectorFrontendHost;if(!IFH)return;
function asMethod(name){var val=IFH[name];Object.defineProperty(IFH,name,{value:function(){return val;},writable:true,configurable:true});}
if(typeof IFH.platform!=='function')asMethod('platform');
if(typeof IFH.localizedStringsURL!=='function')asMethod('localizedStringsURL');
if(typeof IFH.inspectorBackendCommandsURL!=='function')Object.defineProperty(IFH,'inspectorBackendCommandsURL',{value:function(){return 'InspectorBackendCommands.js';},writable:true,configurable:true});
if(typeof IFH.inspectorBackendCommandsURLs!=='function')Object.defineProperty(IFH,'inspectorBackendCommandsURLs',{value:function(){return ['InspectorBackendCommands.js'];},writable:true,configurable:true});
if(typeof IFH.debuggableType!=='function'&&'debuggableInfo' in IFH){var di=IFH.debuggableInfo;Object.defineProperty(IFH,'debuggableType',{value:function(){return di&&di.debuggableType||'web';},writable:true,configurable:true});}
if(typeof IFH.setToolbarHeight!=='function')Object.defineProperty(IFH,'setToolbarHeight',{value:function(){},writable:true,configurable:true});
if(typeof IFH.setAttachedWindowHeight!=='function')Object.defineProperty(IFH,'setAttachedWindowHeight',{value:function(){},writable:true,configurable:true});
if(typeof IFH.setAttachedWindowWidth!=='function')Object.defineProperty(IFH,'setAttachedWindowWidth',{value:function(){},writable:true,configurable:true});
(function(){var origSend=IFH.sendMessageToBackend.bind(IFH);var currentTargetId=null;var pendingQueue=[];var wrapperIdBase=1000000;var wrapperIds=Object.create(null);
function wrap(ms){var wid=wrapperIdBase++;wrapperIds[wid]=true;return JSON.stringify({id:wid,method:'Target.sendMessageToTarget',params:{targetId:currentTargetId,message:ms}});}
function flushQueue(){if(!currentTargetId||!pendingQueue.length)return;var q=pendingQueue;pendingQueue=[];for(var i=0;i<q.length;i++)origSend(wrap(q[i]));}
function fixSel(o){if(!o||typeof o!=='object')return;var sl=o.selectorList;if(sl&&sl.selectors instanceof Array&&sl.selectors.length&&typeof sl.selectors[0]==='object'){sl.selectors=sl.selectors.map(function(s){return s&&typeof s==='object'?String(s.text||''):s;});}if(o.origin==='author'&&(o.selectorList||o.style||o.styleSheetId))o.origin='regular';for(var k in o){var v=o[k];if(v&&typeof v==='object')fixSel(v);}}
IFH.sendMessageToBackend=function(messageStr){
try{var msg=JSON.parse(messageStr);var dom=msg.method&&msg.method.split('.')[0];
if(dom==='Target'||dom==='Browser')return origSend(messageStr);
if(!currentTargetId){pendingQueue.push(messageStr);return;}
return origSend(wrap(messageStr));
}catch(e){console.error('[wk-inspector-bridge] sendMessageToBackend failed',e);}return origSend(messageStr);};
var _backendObj=null;Object.defineProperty(window,'InspectorBackend',{configurable:true,enumerable:true,get:function(){return _backendObj;},set:function(v){_backendObj=v;if(v&&!v.__patched){v.__patched=true;var origDisp=v.dispatch.bind(v);v.dispatch=function(message){try{var obj=(typeof message==='string')?JSON.parse(message):message;if(obj.method==='Target.targetCreated'&&obj.params&&obj.params.targetInfo){currentTargetId=obj.params.targetInfo.targetId;flushQueue();return;}if(obj.id!==undefined&&wrapperIds[obj.id]){delete wrapperIds[obj.id];return;}if(obj.method==='Target.dispatchMessageFromTarget'&&obj.params&&obj.params.message){var im=obj.params.message;if(typeof im==='string'&&(im.indexOf('selectorList')!==-1||im.indexOf('"origin":"author"')!==-1)){try{var po=JSON.parse(im);fixSel(po);return origDisp(po);}catch(e2){console.error('[wk-inspector-bridge] CSS payload rewrite failed',e2);}}return origDisp(im);}}catch(e){console.error('[wk-inspector-bridge] InspectorBackend.dispatch failed',e);}return origDisp(message);};}}});
})();
try{var wkTitle='Web Inspector';
document.addEventListener('DOMContentLoaded',function(){try{
if(document.getElementById('wk-titlebar'))return;
var bar=document.createElement('div');bar.id='wk-titlebar';bar.textContent=wkTitle;
document.body.insertBefore(bar,document.body.firstChild);
}catch(e){console.error('[wk-inspector-bridge] titlebar insert failed',e);}});
if(typeof IFH.inspectedURLChanged==='function'){var origIUC=IFH.inspectedURLChanged.bind(IFH);Object.defineProperty(IFH,'inspectedURLChanged',{value:function(t){try{wkTitle='Web Inspector — '+t;var b=document.getElementById('wk-titlebar');if(b)b.textContent=wkTitle;}catch(e){console.error('[wk-inspector-bridge] title update failed',e);}return origIUC(t);},writable:true,configurable:true});}
}catch(e){console.error('[wk-inspector-bridge] title hook failed',e);}
try{document.addEventListener('mousedown',function(ev){
if(ev.button!==0||!ev.target||!ev.target.closest)return;
if(document.body&&document.body.classList.contains('docked'))return;
if(!ev.target.closest('#wk-titlebar, #toolbar, .toolbar'))return;
if(ev.target.closest('button,input,select,textarea,a,.item,.toolbar-item,.dashboard-container,.navigation-bar,.search-bar,[role=button]'))return;
if(IFH.startWindowDrag){IFH.startWindowDrag();ev.preventDefault();ev.stopPropagation();}
},true);}catch(e){console.error('[wk-inspector-bridge] drag handler failed',e);}
})();)WKIB";
}

} // namespace WebCore

#endif // PLATFORM(MAC)
