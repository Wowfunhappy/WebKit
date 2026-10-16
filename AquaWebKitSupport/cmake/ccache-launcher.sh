#!/bin/sh
# Compiler launcher: ccache-launcher.sh <ccache> <compile command...>
# A compile that writes a precompiled header runs directly, as in Source/cmake/WebKitCCache.cmake;
# every other compile goes through ccache.
ccache=$1
shift
for argument; do
    if [ "$argument" = -emit-pch ]; then
        exec "$@"
    fi
done
exec "$ccache" "$@"
