cmake_minimum_required(VERSION 3.11.0)
PROJECT (df-ai)

execute_process(COMMAND ${GIT_EXECUTABLE} describe --tags --abbrev=8 --long
    WORKING_DIRECTORY "${df-ai_SOURCE_DIR}"
    OUTPUT_VARIABLE DF_AI_GIT_DESCRIPTION)
execute_process(COMMAND ${GIT_EXECUTABLE} rev-parse HEAD
    WORKING_DIRECTORY "${df-ai_SOURCE_DIR}"
    OUTPUT_VARIABLE DF_AI_GIT_COMMIT)
execute_process(COMMAND ${GIT_EXECUTABLE} describe --tags --abbrev=8 --exact-match
    WORKING_DIRECTORY "${df-ai_SOURCE_DIR}"
    RESULT_VARIABLE DF_AI_GIT_TAGGED_RESULT
    OUTPUT_QUIET ERROR_QUIET)

set(git_describe_tmp_h ${df-ai_SOURCE_DIR}/df-ai-git-describe.tmp.h)
set(git_describe_h ${df-ai_SOURCE_DIR}/df-ai-git-describe.h)

file(WRITE ${git_describe_tmp_h} "")

macro(git_describe_definition var)
    string(STRIP "${${var}}" GIT_DEF_VALUE)
    file(APPEND ${git_describe_tmp_h} "#define ${var} \"${GIT_DEF_VALUE}\"\n")
endmacro()

git_describe_definition(DF_AI_GIT_DESCRIPTION)
git_describe_definition(DF_AI_GIT_COMMIT)
if(${DF_AI_GIT_TAGGED_RESULT} EQUAL 0)
    file(APPEND ${git_describe_tmp_h} "#define DF_AI_GIT_TAGGED\n")
endif()
execute_process(COMMAND ${CMAKE_COMMAND} -E copy_if_different
    ${git_describe_tmp_h} ${git_describe_h})

SET(PROJECT_SRCS
    df-ai.cpp
    ai.cpp
    embark.cpp
    config.cpp
    population.cpp
    population_death.cpp
    population_justice.cpp
    population_military.cpp
    population_nobles.cpp
    population_occupations.cpp
    population_pets.cpp
    plan.cpp
    plan_assign.cpp
    plan_cistern.cpp
    plan_construct.cpp
    plan_find.cpp
    plan_persist.cpp
    plan_priorities.cpp
    plan_setup.cpp
    plan_setup_blueprint.cpp
    plan_smooth.cpp
    plan_zones.cpp
    plan_task.cpp
    blueprint.cpp
    blueprint_furniture.cpp
    blueprint_room.cpp
    blueprint_merge.cpp
    blueprint_template.cpp
    stocks.cpp
    stocks_detect.cpp
    stocks_equipment.cpp
    stocks_farm.cpp
    stocks_find.cpp
    stocks_forge.cpp
    stocks_manager.cpp
    stocks_queue.cpp
    stocks_trade.cpp
    stocks_update.cpp
    camera.cpp
    room.cpp
    room_describe.cpp
    trade_helpers.cpp
    trade_manager.cpp
    event_manager.cpp
    exclusive_callback.cpp
    military.cpp
    pause.cpp
    log.cpp
    variable_string.cpp
)

SET(PROJECT_HDRS
    ai.h
    config.h
    debug.h
    population.h
    plan.h
    plan_priorities.h
    plan_setup.h
    blueprint.h
    stocks.h
    camera.h
    room.h
    trade.h
    event_manager.h
    exclusive_callback.h
    dfhack_shared.h
    df-ai-git-describe.h
    apply.h
    variable_string.h
)

IF("${DFHACK_BUILD_ARCH}" STREQUAL "32")
    set(CMAKE_CXX_COMPILER_ARCHITECTURE_ID X86)
    set(CMAKE_SIZEOF_VOID_P 4)
else()
    set(CMAKE_CXX_COMPILER_ARCHITECTURE_ID x64)
    set(CMAKE_SIZEOF_VOID_P 8)
endif()

SET_SOURCE_FILES_PROPERTIES( ${PROJECT_HDRS} PROPERTIES HEADER_FILE_ONLY TRUE)

LIST(APPEND PROJECT_SRCS ${PROJECT_HDRS})


LIST(APPEND PROJECT_LIBS jsoncpp_static lua ${ZLIB_LIBRARIES})


SET(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -DDFAI_RELEASE")

DFHACK_PLUGIN(df-ai ${PROJECT_SRCS} LINK_LIBRARIES ${PROJECT_LIBS} COMPILE_FLAGS_GCC "-Wno-error -Wno-unused-parameter" COMPILE_FLAGS_MSVC "/W3 /WX- /bigobj")
if(MSVC)
    # ship a PDB so DF/DFHack crash logs and dumps can be symbolized
    target_compile_options(df-ai PRIVATE /Zi)
    target_link_options(df-ai PRIVATE /DEBUG /OPT:REF /OPT:ICF)
    set_target_properties(df-ai PROPERTIES PDB_NAME "df-ai.plug")
endif()

INSTALL(DIRECTORY rooms/ DESTINATION df-ai-blueprints/rooms FILES_MATCHING PATTERN "*.json")
INSTALL(DIRECTORY plans/ DESTINATION df-ai-blueprints/plans FILES_MATCHING PATTERN "*.json")
