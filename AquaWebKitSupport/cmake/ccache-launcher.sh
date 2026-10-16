#!/bin/sh
# Compiler launcher: ccache-launcher.sh <ccache> <compile command...>
# A compile that writes a precompiled header runs directly, as in Source/cmake/WebKitCCache.cmake;
# every other compile goes through ccache. Compile flags arrive in a response file, so the output
# path names a precompiled header.
ccache=$1
shift
previous=
for argument; do
    if [ "$previous" = -o ]; then
        case "$argument" in
            *.pch) exec "$@" ;;
        esac
    fi
    previous=$argument
done
exec "$ccache" "$@"
