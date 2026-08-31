# Rotating-key HLS stream

A local HLS stream for driving legacy `hlsdemux` through concurrent `GstUriDownloader` fetches:
one video variant and one alternate audio rendition, twelve segments each, every segment under
its own AES-128 key, and a key endpoint that answers after a delay so the two streams' key fetches
overlap and queue on the downloader. Seeking it every second or two lands cancels on queued
fetches, which is the path the adaptivedemux manifest-lock patch has to survive.

    ./fetch-sources.sh           # bipbop_16x9 gear1 + alternate_audio_aac into src/
    python3 gen.py               # out/: master.m3u8, video/, audio/, key/
    python3 keyserver.py 1.5 3   # serves out/ on 127.0.0.1:8900, keys after 1.5 s; /live/ playlists
                                 # gain their ENDLIST after 3 requests (master-live.m3u8)

Play `http://127.0.0.1:8900/master.m3u8` through `../hlstest.html` and seek.
