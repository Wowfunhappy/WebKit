Run `bash MavericksSupport/tests/aac-parser-append/run.sh` after building dependencies.
The native appsrc → aacparse → appsink pipeline checks complete-frame emission before
EOS, byte identity, five append chunk sizes, partial final-frame retention, truncated
EOS, resynchronization after invalid bytes, and the parser's 7/9-byte header minima.
The existing 95-frame AAC fixture
supplies the expected bytes and frame boundaries.

An optional path to a candidate `gstaacparse.c` compiles that implementation into
the diagnostic instead of loading the deployed parser, for dependency patch review.
Compilation always appends to `/tmp/wk_build.log`.
