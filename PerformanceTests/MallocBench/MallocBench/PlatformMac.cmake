# MAVERICKS_BACKPORT: MallocBench.xcodeproj builds every target with GCC_SYMBOLS_PRIVATE_EXTERN = NO. OptionsCocoa.cmake
# compiles with -fvisibility=hidden and links with -dead_strip, under which the mbmalloc dylib the
# benchmark loads keeps no symbols at all.
add_compile_options(-fvisibility=default)
