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
//     Target.targetCreated supplies the targetId) and unwrap incoming ones. Once the target exists the
//     bridge asks for the document itself, answering the modern InspectorDOMAgent's rule that it
//     dispatches a context-menu Inspect Element only once DOM.getDocument has been called: the classic
//     frontend's sole route to DOM.getDocument is DOMTreeManager.pushNodeToFrontend(), which it runs on
//     receiving that dispatch. The bridge's own reply is dropped, and the frontend's later
//     DOMTreeManager.requestDocument() issues its own DOM.getDocument, so every node id the frontend
//     holds is still issued after the id reset that call performs. It asks once per bridge instance,
//     which matches the lifetime of the backend's own m_documentRequested: Target.targetCreated arrives
//     for every target the frontend connects to and for every one created afterwards, provisional
//     targets included, and each further DOM.getDocument would reset the node ids the frontend is
//     holding mid-session. Two CSS payload shapes
//     drifted since the classic frontend: CSS.SelectorList.selectors became CSSSelector objects
//     ({text,specificity}) where the frontend expects strings, and the author stylesheet origin was
//     renamed "regular" -> "author"; fixPayload() flattens the selectors and maps the origin back.
//     It also carries the resource-type rename of part 7.
//  4. Commented-out (disabled) properties in the Styles editor (github #87). When a rule's body has
//     more declarations than lines, CSSStyleDeclarationTextEditor stops echoing the author's text
//     and synthesizes one line per property from CSSProperty.synthesizedText, which predates
//     disabled properties: it emits a disabled property as a live declaration, so the comment
//     delimiters vanish, the checkbox reads checked, and the next commit un-comments the property.
//     Today's frontend wraps it (CSSProperty.formattedText does `"/* " + text + " */"` when
//     disabled); restore that here, unchecking the checkbox to match and giving it the uncomment
//     direction the stock handler only implements for the separate comment-scanned checkbox.
//     Reach the frontend's classes through the bare `WebInspector` identifier, never
//     `window.WebInspector`: Main.js declares `const WebInspector = {}`, and a top-level const in a
//     classic script binds in the global LEXICAL environment, so it is not a property of `window`.
//  5. The persisted last-selected DOM node vs. Inspect Element. DOMTreeContentView remembers the node
//     that was selected when the inspector last closed and re-selects it by path as soon as the DOM
//     tree's root arrives, which is after the context menu's inspect event has selected the clicked
//     element. Today's frontend gates that restore on DOMManager.restoreSelectedNodeIsAllowed, cleared
//     in inspectNodeObject() and set again when the main frame navigates (DOMTreeContentView.js
//     _restoreSelectedNodeAfterUpdate); give the classic DOMTreeManager the same flag and have
//     _rootDOMNodeAvailable install the root without the restore while it is clear.
//  6. Revealing the selected DOM node once the tree has a size. FrameContentView.showDOMTree()
//     selects and reveals the node while the DOM tree content view is still detached from the
//     frontend document -- ContentBrowser.showContentView() attaches it only afterwards -- so
//     DOMTreeElement.onreveal()'s scrollIntoViewIfNeeded() measures a zero-height element and
//     Inspect Element lands with the clicked node scrolled out of sight. Today's frontend re-selects
//     the selected node from DOMTreeContentView.sizeDidChange() (upstream a85158d), which View.js
//     runs on the initial layout and on resizes, ahead of layout(). The classic frontend has no
//     layout reasons: ContentViewContainer._prepareContentViewToShow() and every content browser
//     resize both land in the one updateLayout(). So the wrapper measures the element and
//     re-selects only when the size differs from the last layout's, before the stock updateLayout()
//     sizes the selection highlight against the revealed tree.
//  7. Resource type names, translated in fixPayload() alongside the CSS shapes. Page.ResourceType
//     spells the stylesheet type "StyleSheet" and has split Fetch, EventSource, Ping and Beacon out
//     of the buckets that carried them; WebInspector.Resource.Type is keyed by the protocol names of
//     the classic frontend's own era, and a name it does not hold is stored raw as the resource's
//     type. Such a type has no display name, so the resource gets no type folder and
//     ResourceSidebarPanel sorts it among the folders with compareResourceTreeElements, which reads
//     .resource off a folder. Map each name back to the type that protocol version reported: fetches
//     and event sources were RawResource, hence XHR (InspectorResourceUtilities.cpp still spells
//     that default), and pings and beacons had no CachedResource at all, hence Other. The rename
//     lands on the wire so the frontend's own Type table stays stock -- FrameTreeElement's
//     folder-grouping heuristic counts the resources of every key in it.
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
(function(){var origSend=IFH.sendMessageToBackend.bind(IFH);var currentTargetId=null;var pendingQueue=[];var wrapperIdBase=1000000;var wrapperIds=Object.create(null);var bridgeIds=Object.create(null);
function wrap(ms){var wid=wrapperIdBase++;wrapperIds[wid]=true;return JSON.stringify({id:wid,method:'Target.sendMessageToTarget',params:{targetId:currentTargetId,message:ms}});}
function flushQueue(){if(!currentTargetId||!pendingQueue.length)return;var q=pendingQueue;pendingQueue=[];for(var i=0;i<q.length;i++)origSend(wrap(q[i]));}
var documentRequested=false;
function requestDocument(){if(documentRequested)return;documentRequested=true;var iid=wrapperIdBase++;bridgeIds[iid]=true;origSend(wrap(JSON.stringify({id:iid,method:'DOM.getDocument'})));}
var wkResourceTypes={StyleSheet:'Stylesheet',Fetch:'XHR',EventSource:'XHR',Ping:'Other',Beacon:'Other'};
function fixPayload(o){if(!o||typeof o!=='object')return;var sl=o.selectorList;if(sl&&sl.selectors instanceof Array&&sl.selectors.length&&typeof sl.selectors[0]==='object'){sl.selectors=sl.selectors.map(function(s){return s&&typeof s==='object'?String(s.text||''):s;});}if(o.origin==='author'&&(o.selectorList||o.style||o.styleSheetId))o.origin='regular';if(typeof wkResourceTypes[o.type]==='string'&&(typeof o.url==='string'||o.requestId!==undefined))o.type=wkResourceTypes[o.type];for(var k in o){var v=o[k];if(v&&typeof v==='object')fixPayload(v);}}
IFH.sendMessageToBackend=function(messageStr){
var msg=JSON.parse(messageStr);var dom=msg.method&&msg.method.split('.')[0];
if(dom==='Target'||dom==='Browser')return origSend(messageStr);
if(!currentTargetId){pendingQueue.push(messageStr);return;}
return origSend(wrap(messageStr));};
var _backendObj=null;Object.defineProperty(window,'InspectorBackend',{configurable:true,enumerable:true,get:function(){return _backendObj;},set:function(v){_backendObj=v;if(v&&!v.__patched){v.__patched=true;var origDisp=v.dispatch.bind(v);v.dispatch=function(message){var obj=(typeof message==='string')?JSON.parse(message):message;if(obj.method==='Target.targetCreated'&&obj.params&&obj.params.targetInfo){currentTargetId=obj.params.targetInfo.targetId;flushQueue();requestDocument();return;}if(obj.id!==undefined&&wrapperIds[obj.id]){delete wrapperIds[obj.id];return;}if(obj.method==='Target.dispatchMessageFromTarget'&&obj.params&&obj.params.message){var im=obj.params.message;if(typeof im==='string')im=JSON.parse(im);if(im&&im.id!==undefined&&bridgeIds[im.id]){delete bridgeIds[im.id];return;}fixPayload(im);return origDisp(im);}return origDisp(message);};}}});
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
