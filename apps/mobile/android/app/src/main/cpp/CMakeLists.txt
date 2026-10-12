cmake_minimum_required(VERSION 3.22.1)
project(storage_sqlite_jni LANGUAGES CXX)

add_library(storage_sqlite_jni SHARED storage_sqlite_jni.cpp)

find_library(log-lib log)
find_library(dl-lib dl)
target_link_libraries(storage_sqlite_jni ${log-lib} ${dl-lib})

target_compile_features(storage_sqlite_jni PRIVATE cxx_std_17)
target_compile_options(storage_sqlite_jni PRIVATE -Wall -Wextra -Werror=return-type)
