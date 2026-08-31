# Builds a keyed HLS stream from 12 bipbop segments: one video variant plus an alternate audio
# rendition, every segment under its own AES-128 key served by the slow key endpoint.
import os, re, subprocess, binascii
SRC=os.path.join(os.path.dirname(__file__),'src'); OUT=os.path.join(os.path.dirname(__file__),'out'); os.makedirs(OUT,exist_ok=True)
BASE='http://127.0.0.1:8900/'
KEYBASE=BASE+'key/'
def build(name, srcdir, tag):
    lines=open(os.path.join(srcdir,'prog_index.m3u8')).read().splitlines()
    segs=[]; durs=[]; ranges=[]; dur=None; rng=None; offset=0
    for l in lines:
        if l.startswith('#EXTINF'): dur=float(l.split(':')[1].split(',')[0])
        elif l.startswith('#EXT-X-BYTERANGE'):
            spec=l.split(':')[1]; ln=int(spec.split('@')[0]); off=int(spec.split('@')[1]) if '@' in spec else offset; rng=(off,ln); offset=off+ln
        elif l and not l.startswith('#'):
            segs.append(l); durs.append(dur); ranges.append(rng); rng=None
            if len(segs)==12: break
    target=max(1,int(round(max(durs)+0.5)))
    od=os.path.join(OUT,name); os.makedirs(od,exist_ok=True); os.makedirs(os.path.join(OUT,'key'),exist_ok=True)
    pl=['#EXTM3U','#EXT-X-VERSION:3','#EXT-X-TARGETDURATION:%d'%target,'#EXT-X-MEDIA-SEQUENCE:0','#EXT-X-PLAYLIST-TYPE:VOD']
    for i,(seg,dur) in enumerate(zip(segs,durs)):
        key=os.urandom(16); iv=os.urandom(16)
        kname='%s%d.key'%(tag,i); open(os.path.join(OUT,'key',kname),'wb').write(key)
        data=open(os.path.join(srcdir,os.path.basename(seg)),'rb').read()
        if ranges[i]: data=data[ranges[i][0]:ranges[i][0]+ranges[i][1]]
        enc=subprocess.run(['openssl','enc','-aes-128-cbc','-K',binascii.hexlify(key).decode(),'-iv',binascii.hexlify(iv).decode()],input=data,stdout=subprocess.PIPE,check=True).stdout
        open(os.path.join(od,'seg%d.ts'%i),'wb').write(enc)
        pl.append('#EXT-X-KEY:METHOD=AES-128,URI="%s%s",IV=0x%s'%(KEYBASE,kname,binascii.hexlify(iv).decode()))
        pl.append('#EXTINF:%.3f,'%dur); pl.append(BASE+name+'/seg%d.ts'%i)
    pl.append('#EXT-X-ENDLIST'); open(os.path.join(od,'prog.m3u8'),'w').write('\n'.join(pl)+'\n')
    # a second variant over the same segments, so the demuxer has a bitrate ladder
    open(os.path.join(od,'prog-hi.m3u8'),'w').write('\n'.join(pl)+'\n')
build('video',os.path.join(SRC,'gear1'),'v'); build('audio',os.path.join(SRC,'alternate_audio_aac'),'a')
open(os.path.join(OUT,'master.m3u8'),'w').write('''#EXTM3U
#EXT-X-VERSION:4
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",LANGUAGE="eng",NAME="Alt Audio",AUTOSELECT=YES,DEFAULT=YES,URI="audio/prog.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=263851,CODECS="mp4a.40.2, avc1.4d400d",RESOLUTION=416x234,AUDIO="aud"
video/prog.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=380000,CODECS="mp4a.40.2, avc1.4d400d",RESOLUTION=416x234,AUDIO="aud"
video/prog-hi.m3u8
''')
open(os.path.join(OUT,'master-live.m3u8'),'w').write('''#EXTM3U
#EXT-X-VERSION:4
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",LANGUAGE="eng",NAME="Alt Audio",AUTOSELECT=YES,DEFAULT=YES,URI="live/audio.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=263851,CODECS="mp4a.40.2, avc1.4d400d",RESOLUTION=416x234,AUDIO="aud"
live/video.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=380000,CODECS="mp4a.40.2, avc1.4d400d",RESOLUTION=416x234,AUDIO="aud"
live/video-hi.m3u8
''')
print('generated', len(os.listdir(os.path.join(OUT,'key'))), 'keys')
