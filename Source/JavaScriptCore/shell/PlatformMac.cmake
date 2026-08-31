set(testapi_OBJC_SOURCES
    ../API/tests/CurrentThisInsideBlockGetterTest.mm
    ../API/tests/DateTests.mm
    ../API/tests/JSExportTests.mm
    # MAVERICKS_BACKPORT: build JSWrapperMapTests.mm as part of testapi's ObjC (ARC) sources on this backport.
    ../API/tests/JSWrapperMapTests.mm
    ../API/tests/Regress141275.mm
    ../API/tests/Regress141809.mm
    ../API/tests/testapi.mm
)
list(APPEND testapi_SOURCES ${testapi_OBJC_SOURCES})
set_source_files_properties(${testapi_OBJC_SOURCES} PROPERTIES COMPILE_FLAGS -fobjc-arc)
