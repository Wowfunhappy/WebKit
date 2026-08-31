add_definitions(-DBPLATFORM_MAC=1)

list(APPEND bmalloc_SOURCES
    # MAVERICKS_BACKPORT: this list names a file the tree does not contain.
    # bmalloc/IsoHeap.cpp
    bmalloc/ProcessCheck.mm
)
