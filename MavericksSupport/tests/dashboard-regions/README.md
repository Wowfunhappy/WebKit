After building and installing, run:

```sh
bash MavericksSupport/tests/dashboard-regions/run.sh
```

The native WebKit1 harness compares Dashboard SPI bounds with DOM geometry for a multiline inline
inside an offset containing block and an overflow-clipping ancestor. It checks all four region
offsets and an ordinary box region. Comparisons allow one pixel for the SPI's integer snapping of
fractional DOM coordinates. Compiler output goes to `/tmp/wk_build.log`; the executable lives under
`WebKitBuild/Release/dashboard-regions`.
