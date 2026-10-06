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
set(AQUAWEBKIT_SOURCE_LISTS_DIR "${CMAKE_BINARY_DIR}/AquaWebKitSourceLists")
file(MAKE_DIRECTORY "${AQUAWEBKIT_SOURCE_LISTS_DIR}")

macro(AQUAWEBKIT_FILTER_SOURCE_LIST _frameworkDir _listVar _listEntry _withheldVar _addedVar)
    get_filename_component(_aquaWebKitFramework "${_frameworkDir}" NAME)
    get_filename_component(_aquaWebKitLeaf "${_listEntry}" NAME)
    set(_aquaWebKitFiltered "${AQUAWEBKIT_SOURCE_LISTS_DIR}/${_aquaWebKitFramework}-${_aquaWebKitLeaf}")
    set(_aquaWebKitOut "")
    set(_aquaWebKitSeen "")

    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${_frameworkDir}/${_listEntry}")

    file(READ "${_frameworkDir}/${_listEntry}" _aquaWebKitRaw)
    string(REPLACE ";" "\\;" _aquaWebKitRaw "${_aquaWebKitRaw}")
    string(REPLACE "\n" ";" _aquaWebKitLines "${_aquaWebKitRaw}")

    foreach (_aquaWebKitLine IN LISTS _aquaWebKitLines)
        string(STRIP "${_aquaWebKitLine}" _aquaWebKitTrimmed)
        set(_aquaWebKitDrop OFF)
        foreach (_aquaWebKitWithheld IN LISTS ${_withheldVar})
            if (_aquaWebKitTrimmed STREQUAL "${_aquaWebKitWithheld}")
                set(_aquaWebKitDrop ON)
                list(APPEND _aquaWebKitSeen "${_aquaWebKitWithheld}")
                break()
            endif ()
        endforeach ()
        if (NOT _aquaWebKitDrop)
            string(APPEND _aquaWebKitOut "${_aquaWebKitLine}\n")
        endif ()
    endforeach ()

    # Every withheld entry must have matched an upstream line verbatim. A miss means upstream renamed,
    # re-annotated or dropped that entry, and the withholding no longer says what it used to.
    foreach (_aquaWebKitWithheld IN LISTS ${_withheldVar})
        list(FIND _aquaWebKitSeen "${_aquaWebKitWithheld}" _aquaWebKitFound)
        if (_aquaWebKitFound EQUAL -1)
            message(FATAL_ERROR
                "AQUAWEBKIT_FILTER_SOURCE_LIST(${_listEntry}): withheld entry did not match any line:\n"
                "    ${_aquaWebKitWithheld}\n"
                "Re-derive the withheld/added sets against the current upstream file.")
        endif ()
    endforeach ()

    foreach (_aquaWebKitAdd IN LISTS ${_addedVar})
        string(APPEND _aquaWebKitOut "${_aquaWebKitAdd}\n")
    endforeach ()
    file(WRITE "${_aquaWebKitFiltered}" "${_aquaWebKitOut}")

    file(RELATIVE_PATH _aquaWebKitRel "${_frameworkDir}" "${_aquaWebKitFiltered}")
    set(_aquaWebKitSwapped "")
    set(_aquaWebKitMatchedList OFF)
    foreach (_aquaWebKitItem IN LISTS ${_listVar})
        if (_aquaWebKitItem STREQUAL "${_listEntry}")
            list(APPEND _aquaWebKitSwapped "${_aquaWebKitRel}")
            set(_aquaWebKitMatchedList ON)
        else ()
            list(APPEND _aquaWebKitSwapped "${_aquaWebKitItem}")
        endif ()
    endforeach ()
    if (NOT _aquaWebKitMatchedList)
        message(FATAL_ERROR
            "AQUAWEBKIT_FILTER_SOURCE_LIST(${_listEntry}): ${_listVar} carries no such entry.")
    endif ()
    set(${_listVar} "${_aquaWebKitSwapped}")
endmacro()
