#pragma once
// MAVERICKS_BACKPORT: empty stub header. The real BaseBoard SPI is iOS-only and absent on macOS 10.9; this
// stub exists so that a bare #import "BaseBoardSPI.h" (from ConnectionCocoa.mm via header-search paths)
// resolves to an empty definition instead of failing the 10.9 build.
