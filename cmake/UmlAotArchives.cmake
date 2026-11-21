# SPDX-License-Identifier: GPL-2.0-or-later

# The one switch for the archive configurations (App Store, TestFlight) and the
# runtimes they embed: android/lineage-24/metadata/accepted-aot.env says
# whether the accepted AOT artifact may be in them
# (LINEAGE24_ACCEPTED_AOT_ARCHIVES). darwin/cpu/CMakeLists.txt takes the
# component in a device or App Store runtime only when it says "yes", for the
# accepted artifact and for one a build names (UML_AOT_ARTIFACT) alike.

# uml_aot_archives_state(<variable> <descriptor>)
#
# Sets <variable> to "yes" or "no" as the descriptor states, or to "none" when
# there is no descriptor (no artifact is accepted, and none may be archived).
function(uml_aot_archives_state variable descriptor)
    if(NOT EXISTS "${descriptor}")
        set(${variable} none PARENT_SCOPE)
        return()
    endif()
    file(STRINGS "${descriptor}" _line
        REGEX "^LINEAGE24_ACCEPTED_AOT_ARCHIVES='.*'$")
    string(REGEX REPLACE "^[A-Z0-9_]+='(.*)'$" "\\1" _state "${_line}")
    if(NOT _state STREQUAL "yes" AND NOT _state STREQUAL "no")
        message(FATAL_ERROR
            "${descriptor} states no LINEAGE24_ACCEPTED_AOT_ARCHIVES of yes "
            "or no")
    endif()
    set(${variable} ${_state} PARENT_SCOPE)
endfunction()

# uml_aot_require_archives(<descriptor> <artifact>)
#
# An App Store runtime that names an artifact is a configure error unless the
# descriptor accepts the component for archives: it is not built without the
# component in silence, since the build asked for it.
function(uml_aot_require_archives descriptor artifact)
    uml_aot_archives_state(_state "${descriptor}")
    if(_state STREQUAL "none")
        message(FATAL_ERROR
            "UML_AOT_ARTIFACT (${artifact}) names the AOT component for an "
            "App Store runtime, but ${descriptor} accepts no AOT artifact. "
            "Leave UML_AOT_ARTIFACT empty.")
    elseif(NOT _state STREQUAL "yes")
        message(FATAL_ERROR
            "UML_AOT_ARTIFACT (${artifact}) names the AOT component for an "
            "App Store runtime, but ${descriptor} sets "
            "LINEAGE24_ACCEPTED_AOT_ARCHIVES to no. "
            "Leave UML_AOT_ARTIFACT empty.")
    endif()
endfunction()
