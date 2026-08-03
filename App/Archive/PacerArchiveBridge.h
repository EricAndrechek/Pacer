//
//  PacerArchiveBridge.h
//  Bridging header for the DuckDB archive spike.
//
//  SPIKE — not a shipping path. Proves that a large C++ static library
//  links into the real Pacer target, runs under the hardened runtime, and
//  can write into the App Group container, before any schema work is
//  committed to. The library currently resolves against Homebrew's
//  `duckdb` formula (see the `DUCKDB_*` settings in project.yml); shipping
//  this would mean vendoring a minimal, deployment-target-matched build as
//  an XCFramework so CI and contributors don't need Homebrew.
//
//  Everything behind it is gated on PACER_ARCHIVE_SPIKE=1 and compiled out
//  of the widget extension entirely.
//

#ifndef PacerArchiveBridge_h
#define PacerArchiveBridge_h

#include "duckdb.h"

#endif /* PacerArchiveBridge_h */
