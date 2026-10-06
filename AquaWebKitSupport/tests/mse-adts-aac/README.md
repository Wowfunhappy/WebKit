# MSE raw ADTS AAC byte stream

`tone.aac` is a `say`-generated sentence encoded to raw ADTS AAC
(`afconvert -f adts -d aac@24000 -c 1`) — the same shape ChatGPT's "Read aloud"
returns from `/backend-api/synthesize?format=aac`.

Serve the `tests` directory and open `mse-adts-aac/index.html`:

    python2.7 -m SimpleHTTPServer 8791

Each button appends the identical bytes to a SourceBuffer, varying only the
container type and the append granularity. All three must reach `playing` with a
growing buffered range and no `FAIL` line.
