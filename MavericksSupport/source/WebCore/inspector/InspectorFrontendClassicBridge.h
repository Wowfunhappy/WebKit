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

#import <Foundation/Foundation.h>

namespace WebCore {

// Whether the com.apple.WebInspectorUI bundle that inspector-resource:// serves from is the classic
// frontend the bridge below adapts. The frontend built from this tree carries the Test.html the
// system's does not, and dyld answers with it wherever the build directory is on
// DYLD_FRAMEWORK_PATH; a frontend built from this tree matches this backend and takes no bridge.
inline bool inspectorFrontendIsClassic()
{
    static const bool isClassic = [] {
        NSBundle *bundle = [NSBundle bundleWithIdentifier:@"com.apple.WebInspectorUI"];
        return bundle && ![bundle pathForResource:@"Test" ofType:@"html"];
    }();
    return isClassic;
}

// The classic-frontend bridge user script, shared by both ports.
//
// The inspector frontend is the system's WebInspectorUI, whose InspectorFrontendHost calls and
// protocol payloads follow an older IDL and protocol than this backend's. This document-start user
// script adapts one to the other and paints the unified titlebar+toolbar (#52/#66/#69). Both ports
// inject it into the frontend page's main world ahead of the frontend's own document-start scripts:
//   - WebKit (WK2): as a WKUserScript in WKInspectorViewController's webViewConfiguration.
//   - WebKitLegacy (WK1): via +[WebView _addUserScriptToGroup:...] in the standard world.
// A native user script is exempt from the frontend page's `script-src 'self'` CSP, which its own
// resources satisfy under the inspector-resource:// scheme both ports serve them from.
//
// Seven parts:
//  1. Unified titlebar+toolbar chrome (#52/#66/#69). Adds the measured Aqua gradient + a 22px
//     #wk-titlebar strip as body's first child (stock 56px toolbar untouched below it), the window
//     title fed from InspectorFrontendHost.inspectedURLChanged, and background mousedowns routed to
//     IFH.startWindowDrag() (undocked only). Gradient endpoints measured off a native Mavericks
//     unified titlebar (Finder, lossless samples, frontmost-verified): ACTIVE = 1px rgb(242) bevel,
//     rgb(234)->rgb(176), 1px rgb(105) border; INACTIVE = rgb(240)->rgb(223), 1px rgb(166) border.
//  2. InspectorFrontendHost drift. The classic frontend calls platform()/localizedStringsURL()/
//     inspectorBackendCommandsURL() as METHODS where the modern IDL exposes attribute getters, so
//     each attribute is wrapped as a method. setToolbarHeight() is the classic name for what the
//     modern frontend does in WI._updateSheetRect(): both report the geometry a sheet is positioned
//     against (-window:willPositionSheet:usingRect: reads it back), so it forwards #main's bounding
//     rect to setSheetRect() exactly as today's frontend does, from the classic call site and from
//     the two WI._updateSheetRect() runs on (load completion and window resize).
//  3. Protocol bridge. The classic frontend sends bare per-domain commands ({method:'DOM.getDocument'});
//     the modern backend routes per-target via Target.sendMessageToTarget and answers with
//     Target.dispatchMessageFromTarget. Wrap outgoing non-Target/Browser commands (queueing until
//     Target.targetCreated supplies the page target) and unwrap incoming ones. Once the target exists the
//     bridge asks for the document itself, answering the modern InspectorDOMAgent's rule that it
//     dispatches a context-menu Inspect Element only once DOM.getDocument has been called: the classic
//     frontend's sole route to DOM.getDocument is DOMTreeManager.pushNodeToFrontend(), which it runs on
//     receiving that dispatch. The bridge's own reply is dropped, and the frontend's later
//     DOMTreeManager.requestDocument() issues its own DOM.getDocument, so every node id the frontend
//     holds is still issued after the id reset that call performs. It asks once per page target, the
//     lifetime of that target's m_documentRequested.
//     A navigation that changes process arrives as a provisional page target, handled as today's
//     TargetManager handles it: targets start paused (Target.setPauseOnStart), and a provisional one
//     receives the frontend's per-target state -- every domain it enabled, a running Timeline or
//     Profiler recording, the persistent Debugger and Page settings and its URL breakpoints, kept as
//     the frontend sends them and forwarded to provisional targets as they change -- plus
//     DOM.getDocument, and is then resumed. Its messages are held until
//     Target.didCommitProvisionalTarget makes it the page target, then delivered in order; the classic
//     FrameResourceManager takes the committed main frame as a navigation to a new frame. Events from
//     any other target are dropped, and non-page targets are resumed untouched. The classic
//     InspectorBackend holds its runAfterPendingDispatches() work until every command it sent has a
//     reply, so each frontend command is tracked against the target it went to and answered with an
//     error when that target is replaced or destroyed, or the backend refuses to route it. The backend's
//     CSS.SelectorList.selectors are CSSSelector objects ({text,specificity}) where the frontend reads
//     strings, and it names the author stylesheet origin "author" where the frontend reads "regular";
//     fixPayload() flattens the selectors and maps the origin. Runtime.ExecutionContextDescription
//     names its world in `type` where the frontend reads `isPageContext`, the normal world's context
//     being the page's; fixPayload() supplies the flag. A Console.StackTrace is an object carrying its
//     `callFrames` where the frontend reads the call frame array itself; fixPayload() unwraps it. Held
//     messages are delivered one at a time, as separate dispatches: an exception one of them raises is
//     rethrown on its own turn. The classic frontend measures a request's latency and duration from the
//     requestWillBeSent timestamp, taken when the web process issues it, while the backend times
//     responseReceived on arrival and loadingFinished at the network's responseEnd; fixNetworkTimes()
//     restates both as that timestamp plus the offsets the response's timing reports, the times the
//     in-tree frontend draws.
//     It also carries the resource-type rename of part 7.
//  4. Commented-out (disabled) properties in the Styles editor (github #87). When a rule's body has
//     more declarations than lines, CSSStyleDeclarationTextEditor stops echoing the author's text
//     and synthesizes one line per property from CSSProperty.synthesizedText, which has no disabled
//     state: it emits a disabled property as a live declaration, so the comment
//     delimiters vanish, the checkbox reads checked, and the next commit un-comments the property.
//     The in-tree frontend wraps it (CSSProperty.formattedText does `"/* " + text + " */"` when
//     disabled); restore that here, unchecking the checkbox to match and giving it the uncomment
//     direction the stock handler only implements for the separate comment-scanned checkbox.
//     A rule's CSSStyle reaches the frontend as its declaration list, the text the in-tree frontend
//     edits: the classic editor echoes a style's whole cssText back through CSS.setStyleText, and the
//     backend appends the rule's nested rules to that text from the style sheet. wkStripNestedRules()
//     drops each nested rule from cssText, telling it from a declaration by CSS Syntax's rule for a
//     block's contents (a declaration is an ident, then `:`, then a value in which a top-level
//     {}-block stands alone unless the property is custom), and moves the property and style ranges
//     onto the shortened text. A rule style's multi-line text goes out ending in a newline and the
//     closing brace's indentation, the shape the backend expects when it repeats that last line.
//     Reach the frontend's classes through the bare `WebInspector` identifier, never
//     `window.WebInspector`: Main.js declares `const WebInspector = {}`, and a top-level const in a
//     classic script binds in the global LEXICAL environment, so it is not a property of `window`.
//  5. The persisted last-selected DOM node vs. Inspect Element. DOMTreeContentView remembers the node
//     that was selected when the inspector last closed and re-selects it by path as soon as the DOM
//     tree's root arrives, which is after the context menu's inspect event has selected the clicked
//     element. The in-tree frontend gates that restore on DOMManager.restoreSelectedNodeIsAllowed, cleared
//     in inspectNodeObject() and set again when the main frame navigates (DOMTreeContentView.js
//     _restoreSelectedNodeAfterUpdate); give the classic DOMTreeManager the same flag and have
//     _rootDOMNodeAvailable install the root without the restore while it is clear.
//  6. Revealing the selected DOM node once the tree has a size. FrameContentView.showDOMTree()
//     selects and reveals the node while the DOM tree content view is still detached from the
//     frontend document -- ContentBrowser.showContentView() attaches it only afterwards -- so
//     DOMTreeElement.onreveal()'s scrollIntoViewIfNeeded() measures a zero-height element and
//     Inspect Element lands with the clicked node scrolled out of sight. The in-tree frontend re-selects
//     the selected node from DOMTreeContentView.sizeDidChange() (upstream a85158d), which View.js
//     runs on the initial layout and on resizes, ahead of layout(). The classic frontend has no
//     layout reasons: ContentViewContainer._prepareContentViewToShow() and every content browser
//     resize both land in the one updateLayout(). So the wrapper measures the element and
//     re-selects only when the size differs from the last layout's, before the stock updateLayout()
//     sizes the selection highlight against the revealed tree.
//  7. Resource type names, translated in fixPayload() alongside the CSS shapes. Page.ResourceType
//     spells the stylesheet type "StyleSheet" and names Fetch, EventSource, Ping and Beacon, none of
//     which WebInspector.Resource.Type holds; the frontend stores such a name raw as the resource's
//     type, which has no display name, so the resource gets no type folder and ResourceSidebarPanel
//     sorts it among the folders with compareResourceTreeElements, which reads .resource off a folder.
//     Fetches and event sources map to XHR, the RawResource default InspectorResourceUtilities.cpp
//     spells, and pings and beacons to Other. The rename lands on the wire so the frontend's own Type
//     table stays stock -- FrameTreeElement's folder-grouping heuristic counts the resources of every
//     key in it.
inline const char* classicInspectorFrontendBridgeScriptUTF8()
{
    return R"WKIB((function(){
var wkCSS="body:not(.docked){background-image:-webkit-linear-gradient(top,rgb(242,242,242),rgb(234,234,234) 1px,rgb(176,176,176) 77px,rgb(105,105,105) 77px,rgb(105,105,105) 78px);background-repeat:no-repeat;background-size:100% 78px;border-top-left-radius:4px;border-top-right-radius:4px;}body:not(.docked).window-inactive{background-image:-webkit-linear-gradient(top,rgb(240,240,240),rgb(223,223,223) 77px,rgb(166,166,166) 77px,rgb(166,166,166) 78px);}body.docked{background-color:white;}#wk-titlebar{height:22px;-webkit-flex:none;text-align:center;font-family:'Lucida Grande';font-size:13px;line-height:22px;color:rgba(0,0,0,0.85);text-shadow:rgba(255,255,255,0.5) 0 1px 0;padding:0 80px;overflow:hidden;white-space:nowrap;text-overflow:ellipsis;cursor:default;}body.window-inactive #wk-titlebar{color:rgba(0,0,0,0.5);}body.docked #wk-titlebar{display:none;}";
function wkAddStyle(){if(document.getElementById('wk-unified-style'))return;var st=document.createElement('style');st.id='wk-unified-style';st.textContent=wkCSS;(document.head||document.documentElement).appendChild(st);}
if(document.documentElement)wkAddStyle();else document.addEventListener('DOMContentLoaded',wkAddStyle);
var IFH=window.InspectorFrontendHost;if(!IFH)return;
function asMethod(name){var val=IFH[name];Object.defineProperty(IFH,name,{value:function(){return val;},writable:true,configurable:true});}
asMethod('platform');
asMethod('localizedStringsURL');
Object.defineProperty(IFH,'inspectorBackendCommandsURL',{value:function(){return 'InspectorBackendCommands.js';},writable:true,configurable:true});
Object.defineProperty(IFH,'inspectorBackendCommandsURLs',{value:function(){return ['InspectorBackendCommands.js'];},writable:true,configurable:true});
Object.defineProperty(IFH,'debuggableType',{value:function(){return IFH.debuggableInfo.debuggableType;},writable:true,configurable:true});
function wkUpdateSheetRect(){var r=document.getElementById('main').getBoundingClientRect();IFH.setSheetRect(r.x,r.y,r.width,r.height);}
Object.defineProperty(IFH,'setToolbarHeight',{value:wkUpdateSheetRect,writable:true,configurable:true});
document.addEventListener('DOMContentLoaded',function(){window.addEventListener('resize',wkUpdateSheetRect);wkUpdateSheetRect();});
(function(){var origSend=IFH.sendMessageToBackend.bind(IFH);var currentTargetId=null;var provisionalTargets=Object.create(null);var pendingQueue=[];var nextWireId=1;var outerCalls=Object.create(null);var innerCalls=Object.create(null);
function sendToBackend(method,params){var wid=nextWireId++;outerCalls[wid]={};origSend(JSON.stringify({id:wid,method:method,params:params}));}
function wrapFor(targetId,inner){var wid=nextWireId++;outerCalls[wid]={targetId:targetId,innerId:inner.id};return JSON.stringify({id:wid,method:'Target.sendMessageToTarget',params:{targetId:targetId,message:JSON.stringify(inner)}});}
function sendFromBridge(targetId,method,params){var iid=nextWireId++;innerCalls[iid]={};var m={id:iid,method:method};if(params)m.params=params;origSend(wrapFor(targetId,m));}
var outstanding=Object.create(null);
function sendFrontendMessage(msg){var t=currentTargetId;if(msg.id!==undefined){var iid=nextWireId++;innerCalls[iid]={frontendId:msg.id};(outstanding[t]||(outstanding[t]=Object.create(null)))[iid]=true;msg.id=iid;}origSend(wrapFor(t,msg));}
function flushQueue(){if(!currentTargetId||!pendingQueue.length)return;var q=pendingQueue;pendingQueue=[];for(var i=0;i<q.length;i++)sendFrontendMessage(q[i]);}
var targetState=[];var pendingBreakpoints=Object.create(null);var persistentSetters={'Debugger.setBreakpointsActive':1,'Debugger.setPauseOnExceptions':1,'Page.setCompositingBordersVisible':1};
function setTargetState(key,msg){for(var i=0;i<targetState.length;i++){if(targetState[i].key===key){targetState.splice(i,1);break;}}if(msg)targetState.push({key:key,method:msg.method,params:msg.params});}
function recordTargetState(msg){var m=msg.method;var dot=m.lastIndexOf('.');var dom=m.slice(0,dot);var cmd=m.slice(dot+1);
if(cmd==='enable'||cmd==='disable'){setTargetState(dom+'.enabled',cmd==='enable'?msg:null);return true;}
if((dom==='Timeline'||dom==='Profiler')&&(cmd==='start'||cmd==='stop')){setTargetState(dom+'.recording',cmd==='start'?msg:null);return true;}
if(persistentSetters[m]){setTargetState(m,msg);return true;}
if(m==='Debugger.setBreakpointByUrl'){pendingBreakpoints[msg.id]=msg;return true;}
if(m==='Debugger.removeBreakpoint'&&msg.params){setTargetState('breakpoint:'+msg.params.breakpointId,null);return true;}
return false;}
function initializeTarget(targetId){for(var i=0;i<targetState.length;i++)sendFromBridge(targetId,targetState[i].method,targetState[i].params);sendFromBridge(targetId,'DOM.getDocument');}
var documentRequested=false;
function requestDocument(){if(documentRequested)return;documentRequested=true;sendFromBridge(currentTargetId,'DOM.getDocument');}
function targetCreated(info){var id=info.targetId;
if(info.type!=='page'){if(info.isPaused)sendToBackend('Target.resume',{targetId:id});return;}
if(info.isProvisional){provisionalTargets[id]=[];initializeTarget(id);if(info.isPaused)sendToBackend('Target.resume',{targetId:id});return;}
if(!currentTargetId)sendToBackend('Target.setPauseOnStart',{pauseOnStart:true});
currentTargetId=id;flushQueue();requestDocument();}
var wkRequestTimes=Object.create(null);
function fixNetworkTimes(im){var p=im.params;if(!im.method||!p||p.requestId===undefined)return;var t=wkRequestTimes[p.requestId];
if(im.method==='Network.requestWillBeSent'){if(!t)wkRequestTimes[p.requestId]={sent:p.timestamp};return;}
if(!t)return;
if(im.method==='Network.responseReceived'){var tm=p.response&&p.response.timing;if(tm&&tm.startTime>0&&tm.fetchStart>0&&tm.responseStart>=0){t.start=tm.startTime;p.timestamp=t.sent+(tm.fetchStart+tm.responseStart/1000-tm.startTime);}return;}
if(im.method==='Network.loadingFinished'&&t.start!==undefined)p.timestamp=t.sent+(p.timestamp-t.start);
if(im.method==='Network.loadingFinished'||im.method==='Network.loadingFailed')delete wkRequestTimes[p.requestId];}
var wkResourceTypes={StyleSheet:'Stylesheet',Fetch:'XHR',EventSource:'XHR',Ping:'Other',Beacon:'Other'};
function fixPayload(o){if(!o||typeof o!=='object')return;if(o.selectorList&&o.style&&o.style.styleId)ruleStyleIds[wkStyleKey(o.style.styleId)]=true;if(typeof o.cssText==='string'&&o.cssProperties instanceof Array&&o.styleId&&ruleStyleIds[wkStyleKey(o.styleId)])wkStripNestedRules(o);var sl=o.selectorList;if(sl&&sl.selectors instanceof Array&&sl.selectors.length&&typeof sl.selectors[0]==='object'){sl.selectors=sl.selectors.map(function(s){return s&&typeof s==='object'?String(s.text||''):s;});}if(o.origin==='author'&&(o.selectorList||o.style||o.styleSheetId))o.origin='regular';if(typeof wkResourceTypes[o.type]==='string'&&(typeof o.url==='string'||o.requestId!==undefined))o.type=wkResourceTypes[o.type];var st=o.stackTrace;if(st&&typeof st==='object'&&!(st instanceof Array)&&st.callFrames instanceof Array)o.stackTrace=st.callFrames;if(typeof o.frameId==='string'&&typeof o.id==='number'&&(o.type==='normal'||o.type==='user'||o.type==='internal')&&o.isPageContext===undefined)o.isPageContext=o.type==='normal';for(var k in o){var v=o[k];if(v&&typeof v==='object')fixPayload(v);}}
function wkComponentEnd(t,j){var n=t.length,c=t[j];
if(c==='/'&&t[j+1]==='*'){var e=t.indexOf('*/',j+2);return e<0?n:e+2;}
if(c==='"'||c==="'"){j++;while(j<n&&t[j]!==c&&t[j]!=='\n'){if(t[j]==='\\')j++;j++;}return j<n&&t[j]===c?j+1:j;}
if(c==='\\')return Math.min(j+2,n);
if((c==='u'||c==='U')&&/^url\(/i.test(t.substr(j,4))&&!(j&&/[-\w\u0080-￿\\]/.test(t[j-1]))){var k=j+4;while(k<n&&/\s/.test(t[k]))k++;if(t[k]!=='"'&&t[k]!=="'"){while(k<n&&t[k]!==')'){if(t[k]==='\\')k++;k++;}return Math.min(k+1,n);}return wkComponentEnd(t,j+3);}
if(c==='('||c==='['||c==='{'){var close=c==='('?')':c==='['?']':'}';j++;while(j<n&&t[j]!==close)j=wkComponentEnd(t,j);return Math.min(j+1,n);}
return j+1;}
function wkNestedRuleSpans(t){var n=t.length,pos=0,spans=[],m;
while(pos<n){var c=t[pos];
if(/\s/.test(c)||c===';'){pos++;continue;}
if(c==='/'&&t[pos+1]==='*'){pos=wkComponentEnd(t,pos);continue;}
var end=-1;
if(c==='@'){var j=pos;while(j<n&&t[j]!==';'&&t[j]!=='{')j=wkComponentEnd(t,j);end=j<n&&t[j]==='{'?wkComponentEnd(t,j):Math.min(j+1,n);}
else{var decl=false;m=/^(?:--|-?(?:[A-Za-z_\u0080-￿]|\\[\s\S]))(?:[-\w\u0080-￿]|\\[\s\S])*/.exec(t.substr(pos));
if(m){var k=pos+m[0].length;while(k<n&&(/\s/.test(t[k])||(t[k]==='/'&&t[k+1]==='*')))k=/\s/.test(t[k])?k+1:wkComponentEnd(t,k);
if(t[k]===':'){var block=false,other=false;k++;while(k<n&&t[k]!==';'){if(t[k]==='{')block=true;else if(!/\s/.test(t[k])&&!(t[k]==='/'&&t[k+1]==='*'))other=true;k=wkComponentEnd(t,k);}
if(m[0].indexOf('--')===0||!(block&&other)){decl=true;pos=k;}}}
if(!decl){var q=pos;while(q<n&&t[q]!=='{'&&t[q]!==';')q=wkComponentEnd(t,q);if(q<n&&t[q]==='{')end=wkComponentEnd(t,q);else pos=q;}}
if(end>=0){var s0=pos;while(s0>0&&/\s/.test(t[s0-1])&&!(spans.length&&s0<=spans[spans.length-1][1]))s0--;spans.push([s0,end]);pos=end;}}
return spans;}
function wkStripNestedRules(o){var t=o.cssText,spans=wkNestedRuleSpans(t);if(!spans.length)return;
var out='',k=0;spans.forEach(function(sp){out+=t.substring(k,sp[0]);k=sp[1];});out+=t.substring(k);o.cssText=out;
var r=o.range;if(!r)return;
function starts(x){var a=[0];for(var i=0;i<x.length;i++)if(x[i]==='\n')a.push(i+1);return a;}
var inStarts=starts(t),outStarts=starts(out);
function toOffset(line,col){var l=line-r.startLine;return l?inStarts[l]+col:col-r.startColumn;}
function removedBefore(off){var d=0;for(var i=0;i<spans.length;i++){if(spans[i][1]<=off)d+=spans[i][1]-spans[i][0];else if(spans[i][0]<off)d+=off-spans[i][0];}return d;}
function inSpan(off){for(var i=0;i<spans.length;i++)if(off>spans[i][0]&&off<spans[i][1])return true;return false;}
function toPosition(off){var l=0;while(l+1<outStarts.length&&outStarts[l+1]<=off)l++;return{line:r.startLine+l,column:l?off-outStarts[l]:r.startColumn+off};}
(o.cssProperties||[]).forEach(function(prop){var pr=prop.range;if(!pr)return;var s0=toOffset(pr.startLine,pr.startColumn),e0=toOffset(pr.endLine,pr.endColumn);
if(inSpan(s0)){delete prop.range;return;}var ps=toPosition(s0-removedBefore(s0)),pe=toPosition(e0-removedBefore(e0));pr.startLine=ps.line;pr.startColumn=ps.column;pr.endLine=pe.line;pr.endColumn=pe.column;});
var end=toPosition(out.length);r.endLine=end.line;r.endColumn=end.column;}
function wkStyleKey(id){return id.styleSheetId+'/'+id.ordinal;}
var ruleStyleIds=Object.create(null);
function wkRuleDeclarationText(t){if(t.indexOf('\n')<0)return t;var e=t.length;while(e&&/\s/.test(t[e-1]))e--;var tail=t.substring(e),nl=tail.lastIndexOf('\n');return t.substring(0,e)+'\n'+(nl<0?'':tail.substring(nl+1));}
IFH.sendMessageToBackend=function(messageStr){
var msg=JSON.parse(messageStr);var dom=msg.method&&msg.method.split('.')[0];
if(msg.method==='CSS.setStyleText'&&msg.params&&msg.params.styleId&&typeof msg.params.text==='string'&&ruleStyleIds[wkStyleKey(msg.params.styleId)])msg.params.text=wkRuleDeclarationText(msg.params.text);
if(dom==='Target'||dom==='Browser'){var wid=nextWireId++;outerCalls[wid]={frontendId:msg.id};msg.id=wid;return origSend(JSON.stringify(msg));}
if(recordTargetState(msg)){for(var tid in provisionalTargets)sendFromBridge(tid,msg.method,msg.params);}
if(!currentTargetId){pendingQueue.push(msg);return;}
sendFrontendMessage(msg);};
var _backendObj=null;Object.defineProperty(window,'InspectorBackend',{configurable:true,enumerable:true,get:function(){return _backendObj;},set:function(v){_backendObj=v;if(v&&!v.__patched){v.__patched=true;var origDisp=v.dispatch.bind(v);
function failCommand(t,iid,text){var o=outstanding[t];if(!o||!o[iid])return;delete o[iid];var c=innerCalls[iid];delete innerCalls[iid];origDisp({id:c.frontendId,error:{code:-32000,message:text}});}
function failTarget(t,text){var o=outstanding[t];delete outstanding[t];if(o)for(var iid in o){var c=innerCalls[iid];delete innerCalls[iid];origDisp({id:c.frontendId,error:{code:-32000,message:text}});}}
function deliver(im,t){if(im.id!==undefined){var o=outstanding[t];if(!o||!o[im.id])return;delete o[im.id];var c=innerCalls[im.id];delete innerCalls[im.id];im.id=c.frontendId;}if(im.id!==undefined&&pendingBreakpoints[im.id]){var bp=pendingBreakpoints[im.id];delete pendingBreakpoints[im.id];if(im.result&&im.result.breakpointId)setTargetState('breakpoint:'+im.result.breakpointId,bp);}fixNetworkTimes(im);fixPayload(im);return origDisp(im);}
v.dispatch=function(message){var obj=(typeof message==='string')?JSON.parse(message):message;var p=obj.params;
if(obj.method==='Target.targetCreated'&&p&&p.targetInfo){targetCreated(p.targetInfo);return;}
if(obj.method==='Target.didCommitProvisionalTarget'&&p){var held=provisionalTargets[p.newTargetId]||[];delete provisionalTargets[p.newTargetId];failTarget(p.oldTargetId,'Target was replaced');currentTargetId=p.newTargetId;held.forEach(function(im){try{deliver(im,p.newTargetId);}catch(e){setTimeout(function(){throw e;},0);}});return;}
if(obj.method==='Target.targetDestroyed'&&p){delete provisionalTargets[p.targetId];failTarget(p.targetId,'Target was destroyed');return;}
if(obj.id!==undefined){var w=outerCalls[obj.id];delete outerCalls[obj.id];if(!w)return;if(w.frontendId!==undefined){obj.id=w.frontendId;return origDisp(obj);}if(obj.error&&w.targetId!==undefined){if(innerCalls[w.innerId]&&innerCalls[w.innerId].frontendId===undefined)delete innerCalls[w.innerId];else failCommand(w.targetId,w.innerId,obj.error.message);}return;}
if(obj.method==='Target.dispatchMessageFromTarget'&&p&&p.message){var im=p.message;if(typeof im==='string')im=JSON.parse(im);if(im&&im.id!==undefined&&innerCalls[im.id]&&innerCalls[im.id].frontendId===undefined){delete innerCalls[im.id];return;}var held=provisionalTargets[p.targetId];if(held){held.push(im);return;}if(p.targetId!==currentTargetId&&im.id===undefined)return;return deliver(im,p.targetId);}
return origDisp(message);};}}});
})();
var wkTitle='Web Inspector';
document.addEventListener('DOMContentLoaded',function(){
if(document.getElementById('wk-titlebar'))return;
var bar=document.createElement('div');bar.id='wk-titlebar';bar.textContent=wkTitle;
document.body.insertBefore(bar,document.body.firstChild);
});
if(typeof IFH.inspectedURLChanged==='function'){var origIUC=IFH.inspectedURLChanged.bind(IFH);Object.defineProperty(IFH,'inspectedURLChanged',{value:function(t){wkTitle='Web Inspector — '+t;var b=document.getElementById('wk-titlebar');if(b)b.textContent=wkTitle;return origIUC(t);},writable:true,configurable:true});}
document.addEventListener('mousedown',function(ev){
if(ev.button!==0||!ev.target||!ev.target.closest)return;
if(document.body&&document.body.classList.contains('docked'))return;
if(!ev.target.closest('#wk-titlebar, #toolbar, .toolbar'))return;
if(ev.target.closest('button,input,select,textarea,a,.item,.toolbar-item,.dashboard-container,.navigation-bar,.search-bar,[role=button]'))return;
if(IFH.startWindowDrag){IFH.startWindowDrag();ev.preventDefault();ev.stopPropagation();}
},true);
document.addEventListener('DOMContentLoaded',function(){
var W=(typeof WebInspector!=='undefined')?WebInspector:null;if(!W)return;
var CP=W.CSSProperty&&W.CSSProperty.prototype;
if(CP&&Object.getOwnPropertyDescriptor(CP,'synthesizedText')){Object.defineProperty(CP,'synthesizedText',{configurable:true,get:function(){
var n=this.name;if(!n)return"";
var p=this.priority;var t=n+": "+this.value.trim()+(p?" !"+p:"")+";";
return this.enabled?t:"/* "+t+" */";}});}
var TE=W.CSSStyleDeclarationTextEditor&&W.CSSStyleDeclarationTextEditor.prototype;
if(!TE||typeof TE._createTextMarkerForPropertyIfNeeded!=='function'||typeof TE._propertyCheckboxChanged!=='function')return;
var origMarker=TE._createTextMarkerForPropertyIfNeeded;
TE._createTextMarkerForPropertyIfNeeded=function(from,to,property){origMarker.call(this,from,to,property);
var marks=this._codeMirror.findMarksAt(from);
for(var i=0;i<marks.length;++i){var m=marks[i],w=m.__propertyCheckbox&&m.replacedWith;if(!w)continue;
var box=w.__cssProperty===property?w:(w.querySelector?w.querySelector('input[type=checkbox]'):null);
if(box&&box.__cssProperty===property)box.checked=!!property.enabled;}};
var origToggle=TE._propertyCheckboxChanged;
TE._propertyCheckboxChanged=function(event){
if(!event.target.checked)return origToggle.call(this,event);
var property=event.target.__cssProperty;if(!property)return;
var textMarker=property.__propertyTextMarker;if(!textMarker)return;
var range=textMarker.find();if(!range)return;
var text=this._codeMirror.getRange(range.from,range.to).replace(/^\/\*\s*/,"").replace(/\s*\*\/$/,"");
if(text.length&&text.charAt(text.length-1)!==";")text+=";";
function update(){this._codeMirror.replaceRange(text,range.from,range.to);this._createColorSwatches(true,range.from.line);}
this._codeMirror.operation(update.bind(this));};
});
document.addEventListener('DOMContentLoaded',function(){
var W=(typeof WebInspector!=='undefined')?WebInspector:null;if(!W)return;
var DTM=W.DOMTreeManager&&W.DOMTreeManager.prototype;
var DTV=W.DOMTreeContentView&&W.DOMTreeContentView.prototype;
if(!DTM||!DTV||typeof DTM.inspectNodeObject!=='function'||typeof DTV._rootDOMNodeAvailable!=='function')return;
var origInspectNodeObject=DTM.inspectNodeObject;
DTM.inspectNodeObject=function(remoteObject){this._restoreSelectedNodeIsAllowed=false;return origInspectNodeObject.call(this,remoteObject);};
var origRootDOMNodeAvailable=DTV._rootDOMNodeAvailable;
DTV._rootDOMNodeAvailable=function(rootDOMNode){
var manager=W.domTreeManager;
if(rootDOMNode&&manager&&manager._restoreSelectedNodeIsAllowed===false){this._domTreeOutline.rootDOMNode=rootDOMNode;return;}
return origRootDOMNodeAvailable.call(this,rootDOMNode);};
W.Frame.addEventListener(W.Frame.Event.MainResourceDidChange,function(event){
if(event.target.isMainFrame()&&W.domTreeManager)W.domTreeManager._restoreSelectedNodeIsAllowed=true;});
});
document.addEventListener('DOMContentLoaded',function(){
var W=(typeof WebInspector!=='undefined')?WebInspector:null;if(!W)return;
var DTV=W.DOMTreeContentView&&W.DOMTreeContentView.prototype;
if(!DTV||typeof DTV.updateLayout!=='function')return;
var origUpdateLayout=DTV.updateLayout;
DTV.updateLayout=function(){
var size=this._lastLaidOutSize,width=this.element.offsetWidth,height=this.element.offsetHeight;
if(!size||size.width!==width||size.height!==height){
this._lastLaidOutSize={width:width,height:height};
this._domTreeOutline.selectDOMNode(this._domTreeOutline.selectedDOMNode());}
return origUpdateLayout.call(this);};
});
})();)WKIB";
}

} // namespace WebCore

#endif // PLATFORM(MAC)
