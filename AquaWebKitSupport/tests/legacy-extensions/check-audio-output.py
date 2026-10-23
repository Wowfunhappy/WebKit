#!/usr/bin/env python3
"""Build and verify physical audio suppression against the installed GStreamer runtime."""
import pathlib,json,shlex,subprocess,os,resource
root=pathlib.Path(__file__).resolve().parents[3]
out=pathlib.Path(__file__).resolve().parent/'build'/'audio-output'
out.mkdir(parents=True,exist_ok=True)
soft,hard=resource.getrlimit(resource.RLIMIT_NOFILE)
resource.setrlimit(resource.RLIMIT_NOFILE,(min(10240,hard) if hard!=-1 else 10240,hard))
log=open('/tmp/wk_build.log','a')
row=next(r for r in json.load(open(root/'WebKitBuild/Release/compile_commands.json')) if r['file'].endswith('/MediaRestreamCapture.cpp'))
base=shlex.split(row['command']);base.insert(1,'-DMediaPlayerAudioOutputSuppression=ProbeAudioOutputSuppression')
for option,filename in (('-include-pch','cmake_pch.hxx.pch'),('-include','cmake_pch.hxx')):
 matches=[i for i in range(len(base)-3) if base[i:i+3]==['-Xclang',option,'-Xclang'] and pathlib.Path(base[i+3]).name==filename]
 for i in reversed(matches):del base[i:i+4]
objects=[]
for src,name in [(root/'AquaWebKitSupport/tests/legacy-extensions/MediaPlayerAudioOutputSuppressionTest.cpp','AudioOutputTest'),(root/'AquaWebKitSupport/source/WebCore/platform/graphics/gstreamer/MediaPlayerAudioOutputSuppression.cpp','AudioOutputImpl')]:
 obj=out/(name+'.o');objects.append(str(obj));cmd=base.copy();cmd[cmd.index('-o')+1]=str(obj);cmd[-1]=str(src)
 subprocess.run(cmd,cwd=row['directory'],stdout=log,stderr=subprocess.STDOUT,check=True)
gst='/System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/WebCore.framework/Versions/A/Frameworks/gstreamer/lib/'
jsc='/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Frameworks/'
cmd=[str(root/'AquaWebKitSupport/toolchain/build/clang/bin/clang++'),'-mmacosx-version-min=10.9',*objects,'-o',str(out/'AudioOutputTest'),'-Wl,-client_name,WebKit','/System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/WebCore.framework/WebCore','/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore','-Wl,-rpath,'+jsc]
for name in ('gstapp-1.0.0','gstaudio-1.0.0','gstreamer-1.0.0','gobject-2.0.0','glib-2.0.0','c++.1','c++abi.1'):cmd.append((gst if name.startswith('gst') else jsc)+'lib'+name+'.dylib')
subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,check=True)

log.close()
env=dict(os.environ,GST_REGISTRY_FORK="no",GST_PLUGIN_SYSTEM_PATH=gst+"gstreamer-1.0")
subprocess.run([str(out/"AudioOutputTest")],env=env,check=True)
