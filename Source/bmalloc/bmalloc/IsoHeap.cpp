// MAVERICKS_BACKPORT: empty translation unit. Source/bmalloc/PlatformMac.cmake still lists
// bmalloc/IsoHeap.cpp in bmalloc_SOURCES, but upstream's switch from bmalloc to mimalloc removed the
// real IsoHeap implementation. This stub provides the listed file so the bmalloc target compiles/links.
/* stub */
