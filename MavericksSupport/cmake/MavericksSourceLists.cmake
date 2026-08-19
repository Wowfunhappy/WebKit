# --------------------------------------------------------------------------
# Upstream's unified-source list files stay byte-upstream. Each is copied line-wise
# into the build tree without the withheld entries and with the added entries appended, and the
# framework's UNIFIED_SOURCE_LIST_FILES entry is swapped in place for the copy.
#
# In-place matters: generate-unified-source-bundles.rb sorts by directory and then by the index of the
# list file an entry came from, so moving a list to the end of UNIFIED_SOURCE_LIST_FILES would regroup
# every directory two lists share. Position *within* one list does not matter -- entries from the same
# list sort by basename -- so added entries append.
#
# The whole file is read at once and its semicolons escaped before it becomes a CMake list; file(STRINGS)
# builds the list first, which splits upstream's licence header on the semicolons inside it and feeds the
# fragments to the bundle generator as source entries.
#
# WEBKIT_COMPUTE_SOURCES (Source/cmake/WebKitMacros.cmake) composes "${CMAKE_CURRENT_SOURCE_DIR}/<entry>",
# so the replacement entry is spelled relative to the framework directory.
# --------------------------------------------------------------------------
set(MAVERICKS_SOURCE_LISTS_DIR "${CMAKE_BINARY_DIR}/MavericksSourceLists")
file(MAKE_DIRECTORY "${MAVERICKS_SOURCE_LISTS_DIR}")

macro(MAVERICKS_FILTER_SOURCE_LIST _frameworkDir _listVar _listEntry _withheldVar _addedVar)
    get_filename_component(_mavFramework "${_frameworkDir}" NAME)
    get_filename_component(_mavLeaf "${_listEntry}" NAME)
    set(_mavFiltered "${MAVERICKS_SOURCE_LISTS_DIR}/${_mavFramework}-${_mavLeaf}")
    set(_mavOut "")
    set(_mavSeen "")

    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${_frameworkDir}/${_listEntry}")

    file(READ "${_frameworkDir}/${_listEntry}" _mavRaw)
    string(REPLACE ";" "\\;" _mavRaw "${_mavRaw}")
    string(REPLACE "\n" ";" _mavLines "${_mavRaw}")

    foreach (_mavLine IN LISTS _mavLines)
        string(STRIP "${_mavLine}" _mavTrimmed)
        set(_mavDrop OFF)
        foreach (_mavWithheld IN LISTS ${_withheldVar})
            if (_mavTrimmed STREQUAL "${_mavWithheld}")
                set(_mavDrop ON)
                list(APPEND _mavSeen "${_mavWithheld}")
                break()
            endif ()
        endforeach ()
        if (NOT _mavDrop)
            string(APPEND _mavOut "${_mavLine}\n")
        endif ()
    endforeach ()

    # Every withheld entry must have matched an upstream line verbatim. A miss means upstream renamed,
    # re-annotated or dropped that entry, and the withholding no longer says what it used to.
    foreach (_mavWithheld IN LISTS ${_withheldVar})
        list(FIND _mavSeen "${_mavWithheld}" _mavFound)
        if (_mavFound EQUAL -1)
            message(FATAL_ERROR
                "MAVERICKS_FILTER_SOURCE_LIST(${_listEntry}): withheld entry did not match any line:\n"
                "    ${_mavWithheld}\n"
                "Re-derive the withheld/added sets against the current upstream file.")
        endif ()
    endforeach ()

    foreach (_mavAdd IN LISTS ${_addedVar})
        string(APPEND _mavOut "${_mavAdd}\n")
    endforeach ()
    file(WRITE "${_mavFiltered}" "${_mavOut}")

    file(RELATIVE_PATH _mavRel "${_frameworkDir}" "${_mavFiltered}")
    set(_mavSwapped "")
    set(_mavMatchedList OFF)
    foreach (_mavItem IN LISTS ${_listVar})
        if (_mavItem STREQUAL "${_listEntry}")
            list(APPEND _mavSwapped "${_mavRel}")
            set(_mavMatchedList ON)
        else ()
            list(APPEND _mavSwapped "${_mavItem}")
        endif ()
    endforeach ()
    if (NOT _mavMatchedList)
        message(FATAL_ERROR
            "MAVERICKS_FILTER_SOURCE_LIST(${_listEntry}): ${_listVar} carries no such entry.")
    endif ()
    set(${_listVar} "${_mavSwapped}")
endmacro()
