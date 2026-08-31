// libsqlite3: entry points modern WebKit calls that 10.9's SQLite (3.7) does not export.
#include "wk_polyfill.h"

#include <sqlite3.h>

// ---------------------------------------------------------------------------------------------------
// sqlite3 -- 10.9 ships SQLite 3.7, so the entry points added in later versions are absent.
// ---------------------------------------------------------------------------------------------------

// sqlite3_errstr (SQLite 3.7.15) — 10.9 ships an older SQLite. Map the primary result codes to the same
// strings SQLite uses, so WebCore's diagnostic logging stays meaningful. Used only for error messages.
WK_POLYFILL_ABSENT("/usr/lib/libsqlite3.dylib", const char *, sqlite3_errstr, (int rc)) {
    switch (rc & 0xff) {
        case 0:  return "not an error";
        case 1:  return "SQL logic error";
        case 2:  return "internal error";
        case 3:  return "access permission denied";
        case 4:  return "query aborted";
        case 5:  return "database is locked";
        case 6:  return "database table is locked";
        case 7:  return "out of memory";
        case 8:  return "attempt to write a readonly database";
        case 9:  return "interrupted";
        case 10: return "disk I/O error";
        case 11: return "database disk image is malformed";
        case 12: return "unknown operation";
        case 13: return "database or disk is full";
        case 14: return "unable to open database file";
        case 15: return "locking protocol";
        case 17: return "database schema has changed";
        case 18: return "string or blob too big";
        case 19: return "constraint failed";
        case 20: return "datatype mismatch";
        case 21: return "library routine called out of sequence";
        case 23: return "authorization denied";
        case 25: return "column index out of range";
        case 26: return "file is not a database";
        case 100: return "another row available";
        case 101: return "no more rows available";
        default: return "unknown error";
    }
}

// sqlite3_bind_blob64 (SQLite 3.8.7 / 10.10+): 10.9 ships SQLite 3.7; forward to sqlite3_bind_blob
// (WebKit blob lengths are always well under INT_MAX).
WK_SYSTEM_FN("/usr/lib/libsqlite3.dylib", int, sqlite3_bind_blob,
    (sqlite3_stmt *, int, const void *, int, void (*)(void *)));
WK_POLYFILL_ABSENT("/usr/lib/libsqlite3.dylib", int, sqlite3_bind_blob64,
    (sqlite3_stmt *statement, int index, const void *data, sqlite3_uint64 length, void (*destructor)(void *)))
{
    if (!WK_SYSTEM(sqlite3_bind_blob))
        return SQLITE_ERROR;
    return WK_SYSTEM(sqlite3_bind_blob)(statement, index, data, (int)length, destructor);
}
