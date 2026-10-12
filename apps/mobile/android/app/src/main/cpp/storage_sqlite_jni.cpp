#include <jni.h>
#include <dlfcn.h>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

namespace {

struct sqlite3;
struct sqlite3_stmt;
struct sqlite3_vfs;
using sqlite3_int64 = long long;
using sqlite3_uint64 = unsigned long long;

constexpr int SQLITE_OPEN_READWRITE_VALUE = 0x00000002;
constexpr int SQLITE_OK_VALUE = 0;
constexpr int SQLITE_ROW_VALUE = 100;
constexpr int SQLITE_DONE_VALUE = 101;
constexpr int SQLITE_INTEGER_VALUE = 1;
constexpr int SQLITE_FLOAT_VALUE = 2;
constexpr int SQLITE_TEXT_VALUE = 3;
constexpr int SQLITE_BLOB_VALUE = 4;
constexpr int SQLITE_NULL_VALUE = 5;
constexpr int SQLITE_MISUSE_VALUE = 21;
constexpr int SQLITE_NOMEM_VALUE = 7;
constexpr int SQLITE_CANTOPEN_VALUE = 14;

using open_v2_fn = int (*)(const char*, sqlite3**, int, const char*);
using close_v2_fn = int (*)(sqlite3*);
using prepare_v2_fn = int (*)(sqlite3*, const char*, int, sqlite3_stmt**, const char**);
using finalize_fn = int (*)(sqlite3_stmt*);
using step_fn = int (*)(sqlite3_stmt*);
using bind_null_fn = int (*)(sqlite3_stmt*, int);
using bind_int64_fn = int (*)(sqlite3_stmt*, int, sqlite3_int64);
using bind_double_fn = int (*)(sqlite3_stmt*, int, double);
using bind_text_fn = int (*)(sqlite3_stmt*, int, const char*, int, void (*)(void*));
using bind_blob64_fn = int (*)(sqlite3_stmt*, int, const void*, sqlite3_uint64, void (*)(void*));
using column_count_fn = int (*)(sqlite3_stmt*);
using column_type_fn = int (*)(sqlite3_stmt*, int);
using column_bytes_fn = int (*)(sqlite3_stmt*, int);
using column_text_fn = const unsigned char* (*)(sqlite3_stmt*, int);
using column_blob_fn = const void* (*)(sqlite3_stmt*, int);
using column_int64_fn = sqlite3_int64 (*)(sqlite3_stmt*, int);
using column_double_fn = double (*)(sqlite3_stmt*, int);
using errmsg_fn = const char* (*)(sqlite3*);
using extended_errcode_fn = int (*)(sqlite3*);
using busy_timeout_fn = int (*)(sqlite3*, int);
using get_autocommit_fn = int (*)(sqlite3*);
using sourceid_fn = const char* (*)();
using libversion_fn = const char* (*)();
using threadsafe_fn = int (*)();
using vfs_find_fn = sqlite3_vfs* (*)(const char*);
thread_local int last_open_error_code = SQLITE_OK_VALUE;
thread_local std::string last_open_error_message;

struct SqliteApi {
  void* handle = nullptr;
  std::string library_path;
  open_v2_fn open_v2 = nullptr;
  close_v2_fn close_v2 = nullptr;
  prepare_v2_fn prepare_v2 = nullptr;
  finalize_fn finalize = nullptr;
  step_fn step = nullptr;
  bind_null_fn bind_null = nullptr;
  bind_int64_fn bind_int64 = nullptr;
  bind_double_fn bind_double = nullptr;
  bind_text_fn bind_text = nullptr;
  bind_blob64_fn bind_blob64 = nullptr;
  column_count_fn column_count = nullptr;
  column_type_fn column_type = nullptr;
  column_bytes_fn column_bytes = nullptr;
  column_text_fn column_text = nullptr;
  column_blob_fn column_blob = nullptr;
  column_int64_fn column_int64 = nullptr;
  column_double_fn column_double = nullptr;
  errmsg_fn errmsg = nullptr;
  extended_errcode_fn extended_errcode = nullptr;
  busy_timeout_fn busy_timeout = nullptr;
  get_autocommit_fn get_autocommit = nullptr;
  sourceid_fn sourceid = nullptr;
  libversion_fn libversion = nullptr;
  threadsafe_fn threadsafe = nullptr;
  vfs_find_fn vfs_find = nullptr;
};

SqliteApi& api() {
  static SqliteApi value;
  static std::once_flag once;
  std::call_once(once, [] {
    auto& a = value;
    // The package:sqlite3 native asset uses this exact basename on Android.
    // Never resolve through RTLD_DEFAULT or the platform SQLite namespace.
    a.handle = dlopen("libsqlite3.so", RTLD_NOW | RTLD_LOCAL);
    if (!a.handle) return;
    Dl_info owner{};
    auto resolve = [&](const char* name) -> void* {
      void* symbol = dlsym(a.handle, name);
      if (!symbol || dladdr(symbol, &owner) == 0 || !owner.dli_fname) return nullptr;
      const std::string path(owner.dli_fname);
      if (path.find("libsqlite3.so") == std::string::npos ||
          path.find("/system/") != std::string::npos) return nullptr;
      if (a.library_path.empty()) a.library_path = path;
      if (a.library_path != path) return nullptr;
      return symbol;
    };
#define RESOLVE(field, name) a.field = reinterpret_cast<decltype(a.field)>(resolve(name));
    RESOLVE(open_v2, "sqlite3_open_v2");
    RESOLVE(close_v2, "sqlite3_close_v2");
    RESOLVE(prepare_v2, "sqlite3_prepare_v2");
    RESOLVE(finalize, "sqlite3_finalize");
    RESOLVE(step, "sqlite3_step");
    RESOLVE(bind_null, "sqlite3_bind_null");
    RESOLVE(bind_int64, "sqlite3_bind_int64");
    RESOLVE(bind_double, "sqlite3_bind_double");
    RESOLVE(bind_text, "sqlite3_bind_text");
    RESOLVE(bind_blob64, "sqlite3_bind_blob64");
    RESOLVE(column_count, "sqlite3_column_count");
    RESOLVE(column_type, "sqlite3_column_type");
    RESOLVE(column_bytes, "sqlite3_column_bytes");
    RESOLVE(column_text, "sqlite3_column_text");
    RESOLVE(column_blob, "sqlite3_column_blob");
    RESOLVE(column_int64, "sqlite3_column_int64");
    RESOLVE(column_double, "sqlite3_column_double");
    RESOLVE(errmsg, "sqlite3_errmsg");
    RESOLVE(extended_errcode, "sqlite3_extended_errcode");
    RESOLVE(busy_timeout, "sqlite3_busy_timeout");
    RESOLVE(get_autocommit, "sqlite3_get_autocommit");
    RESOLVE(sourceid, "sqlite3_sourceid");
    RESOLVE(libversion, "sqlite3_libversion");
    RESOLVE(threadsafe, "sqlite3_threadsafe");
    RESOLVE(vfs_find, "sqlite3_vfs_find");
#undef RESOLVE
  });
  return value;
}

bool ready() {
  const auto& a = api();
  return a.handle && !a.library_path.empty() && a.open_v2 && a.close_v2 &&
      a.prepare_v2 && a.finalize && a.step && a.bind_null && a.bind_int64 &&
      a.bind_double && a.bind_text && a.bind_blob64 && a.column_count &&
      a.column_type && a.column_bytes && a.column_text && a.column_blob &&
      a.column_int64 && a.column_double && a.errmsg && a.extended_errcode &&
      a.busy_timeout && a.get_autocommit && a.sourceid && a.libversion && a.threadsafe && a.vfs_find;
}

struct DbHandle {
  sqlite3* db = nullptr;
  int error_code = SQLITE_OK_VALUE;
  std::string error_message;
};

void throwIllegal(JNIEnv* env, const std::string& message) {
  jclass clazz = env->FindClass("java/lang/IllegalStateException");
  env->ThrowNew(clazz, message.c_str());
}

void setError(JNIEnv* env, DbHandle* handle, int code, const char* message) {
  if (handle) {
    handle->error_code = code;
    handle->error_message = message ? message : "sqlite error";
  }
  (void)env;
}

DbHandle* handle(jlong value) { return reinterpret_cast<DbHandle*>(value); }

bool bindValue(JNIEnv* env, DbHandle* db, sqlite3_stmt* statement, jint index, jobject value) {
  auto& a = api();
  auto transient = reinterpret_cast<void (*)(void*)>(-1);
  if (!value) {
    const int rc = a.bind_null(statement, index);
    if (rc != SQLITE_OK_VALUE) setError(env, db, rc, "bind null failed");
    return rc == SQLITE_OK_VALUE;
  }
  jclass byteArrayClass = env->FindClass("[B");
  if (!byteArrayClass) { if (env->ExceptionCheck()) env->ExceptionClear(); setError(env, db, SQLITE_NOMEM_VALUE, "bind class lookup failed"); return false; }
  if (env->IsInstanceOf(value, byteArrayClass)) {
    auto bytes = static_cast<jbyteArray>(value);
    const jsize length = env->GetArrayLength(bytes);
    jbyte* data = env->GetByteArrayElements(bytes, nullptr);
    if (length > 0 && !data) { setError(env, db, SQLITE_NOMEM_VALUE, "bind blob allocation failed"); return false; }
    const int rc = a.bind_blob64(statement, index, data, static_cast<sqlite3_uint64>(length), transient);
    if (data) env->ReleaseByteArrayElements(bytes, data, JNI_ABORT);
    if (rc != SQLITE_OK_VALUE) { setError(env, db, rc, "bind blob failed"); return false; }
    return true;
  }
  jclass stringClass = env->FindClass("java/lang/String");
  if (!stringClass) { if (env->ExceptionCheck()) env->ExceptionClear(); setError(env, db, SQLITE_NOMEM_VALUE, "bind class lookup failed"); return false; }
  if (env->IsInstanceOf(value, stringClass)) {
    jmethodID getBytes = env->GetMethodID(stringClass, "getBytes", "(Ljava/nio/charset/Charset;)[B");
    jclass charsets = env->FindClass("java/nio/charset/StandardCharsets");
    if (!getBytes || !charsets) { if (env->ExceptionCheck()) env->ExceptionClear(); setError(env, db, SQLITE_NOMEM_VALUE, "bind text lookup failed"); return false; }
    jfieldID field = env->GetStaticFieldID(charsets, "UTF_8", "Ljava/nio/charset/Charset;");
    if (!field) { if (env->ExceptionCheck()) env->ExceptionClear(); setError(env, db, SQLITE_NOMEM_VALUE, "bind text charset unavailable"); return false; }
    jobject utf8 = env->GetStaticObjectField(charsets, field);
    if (!utf8) { if (env->ExceptionCheck()) env->ExceptionClear(); setError(env, db, SQLITE_NOMEM_VALUE, "bind text charset unavailable"); return false; }
    auto bytes = static_cast<jbyteArray>(env->CallObjectMethod(value, getBytes, utf8));
    if (env->ExceptionCheck() || !bytes) {
      if (env->ExceptionCheck()) env->ExceptionClear();
      setError(env, db, SQLITE_NOMEM_VALUE, "bind text conversion failed");
      return false;
    }
    const jsize length = env->GetArrayLength(bytes);
    jbyte* data = env->GetByteArrayElements(bytes, nullptr);
    if (length > 0 && !data) {
      env->DeleteLocalRef(bytes);
      setError(env, db, SQLITE_NOMEM_VALUE, "bind text allocation failed");
      return false;
    }
    const int rc = a.bind_text(statement, index, reinterpret_cast<const char*>(data), length, transient);
    if (data) env->ReleaseByteArrayElements(bytes, data, JNI_ABORT);
    env->DeleteLocalRef(bytes);
    env->DeleteLocalRef(utf8);
    env->DeleteLocalRef(charsets);
    if (rc != SQLITE_OK_VALUE) { setError(env, db, rc, "bind text failed"); return false; }
    return true;
  }
  jclass doubleClass = env->FindClass("java/lang/Double");
  jclass floatClass = env->FindClass("java/lang/Float");
  if (!doubleClass || !floatClass) { if (env->ExceptionCheck()) env->ExceptionClear(); setError(env, db, SQLITE_NOMEM_VALUE, "bind number lookup failed"); return false; }
  if (env->IsInstanceOf(value, doubleClass) || env->IsInstanceOf(value, floatClass)) {
    jclass valueClass = env->GetObjectClass(value);
    jmethodID method = valueClass ? env->GetMethodID(valueClass, "doubleValue", "()D") : nullptr;
    if (!method) { if (env->ExceptionCheck()) env->ExceptionClear(); setError(env, db, SQLITE_MISUSE_VALUE, "bind double method unavailable"); return false; }
    const double number = env->CallDoubleMethod(value, method);
    if (env->ExceptionCheck()) { env->ExceptionClear(); setError(env, db, SQLITE_MISUSE_VALUE, "bind double conversion failed"); return false; }
    const int rc = a.bind_double(statement, index, number);
    if (rc != SQLITE_OK_VALUE) { setError(env, db, rc, "bind double failed"); return false; }
    return true;
  }
  jclass booleanClass = env->FindClass("java/lang/Boolean");
  if (!booleanClass) { if (env->ExceptionCheck()) env->ExceptionClear(); setError(env, db, SQLITE_NOMEM_VALUE, "bind boolean lookup failed"); return false; }
  if (env->IsInstanceOf(value, booleanClass)) {
    jmethodID method = env->GetMethodID(booleanClass, "booleanValue", "()Z");
    if (!method) { if (env->ExceptionCheck()) env->ExceptionClear(); setError(env, db, SQLITE_MISUSE_VALUE, "bind boolean method unavailable"); return false; }
    const jboolean truth = env->CallBooleanMethod(value, method);
    if (env->ExceptionCheck()) { env->ExceptionClear(); setError(env, db, SQLITE_MISUSE_VALUE, "bind boolean conversion failed"); return false; }
    const int rc = a.bind_int64(statement, index, truth ? 1 : 0);
    if (rc != SQLITE_OK_VALUE) { setError(env, db, rc, "bind boolean failed"); return false; }
    return true;
  }
  jclass numberClass = env->FindClass("java/lang/Number");
  if (!numberClass) { if (env->ExceptionCheck()) env->ExceptionClear(); setError(env, db, SQLITE_NOMEM_VALUE, "bind number lookup failed"); return false; }
  if (env->IsInstanceOf(value, numberClass)) {
    jmethodID method = env->GetMethodID(numberClass, "longValue", "()J");
    if (!method) { if (env->ExceptionCheck()) env->ExceptionClear(); setError(env, db, SQLITE_MISUSE_VALUE, "bind integer method unavailable"); return false; }
    const jlong number = env->CallLongMethod(value, method);
    if (env->ExceptionCheck()) { env->ExceptionClear(); setError(env, db, SQLITE_MISUSE_VALUE, "bind integer conversion failed"); return false; }
    const int rc = a.bind_int64(statement, index, number);
    if (rc != SQLITE_OK_VALUE) { setError(env, db, rc, "bind integer failed"); return false; }
    return true;
  }
  setError(env, db, SQLITE_MISUSE_VALUE, "unsupported bind value");
  return false;
}

bool prepareAndBind(JNIEnv* env, DbHandle* db, const std::string& sql, jobjectArray args, sqlite3_stmt** out) {
  auto& a = api();
  int rc = a.prepare_v2(db->db, sql.c_str(), static_cast<int>(sql.size()), out, nullptr);
  if (rc != SQLITE_OK_VALUE) { setError(env, db, rc, a.errmsg(db->db)); return false; }
  const jsize count = args ? env->GetArrayLength(args) : 0;
  for (jsize i = 0; i < count; ++i) {
    if (env->PushLocalFrame(32) < 0) {
      setError(env, db, SQLITE_NOMEM_VALUE, "jni local frame unavailable");
      a.finalize(*out); *out = nullptr; return false;
    }
    const bool bound = bindValue(env, db, *out, static_cast<jint>(i + 1), env->GetObjectArrayElement(args, i));
    env->PopLocalFrame(nullptr);
    if (!bound) {
      a.finalize(*out); *out = nullptr; return false;
    }
  }
  return true;
}

jobject utf8String(JNIEnv* env, const unsigned char* data, int length) {
  if (!data) return nullptr;
  jbyteArray bytes = env->NewByteArray(length);
  if (!bytes) return nullptr;
  env->SetByteArrayRegion(bytes, 0, length, reinterpret_cast<const jbyte*>(data));
  if (env->ExceptionCheck()) { env->ExceptionClear(); env->DeleteLocalRef(bytes); return nullptr; }
  jclass strings = env->FindClass("java/lang/String");
  if (!strings) { if (env->ExceptionCheck()) env->ExceptionClear(); env->DeleteLocalRef(bytes); return nullptr; }
  jmethodID ctor = env->GetMethodID(strings, "<init>", "([BLjava/nio/charset/Charset;)V");
  jclass charsets = env->FindClass("java/nio/charset/StandardCharsets");
  if (!ctor || !charsets) { if (env->ExceptionCheck()) env->ExceptionClear(); env->DeleteLocalRef(bytes); env->DeleteLocalRef(strings); return nullptr; }
  jfieldID field = env->GetStaticFieldID(charsets, "UTF_8", "Ljava/nio/charset/Charset;");
  if (!field) { if (env->ExceptionCheck()) env->ExceptionClear(); env->DeleteLocalRef(bytes); env->DeleteLocalRef(charsets); env->DeleteLocalRef(strings); return nullptr; }
  jobject utf8 = env->GetStaticObjectField(charsets, field);
  if (!utf8) {
    env->DeleteLocalRef(bytes);
    env->DeleteLocalRef(charsets);
    env->DeleteLocalRef(strings);
    return nullptr;
  }
  jobject result = env->NewObject(strings, ctor, bytes, utf8);
  if (env->ExceptionCheck()) { env->ExceptionClear(); result = nullptr; }
  env->DeleteLocalRef(bytes);
  env->DeleteLocalRef(utf8);
  env->DeleteLocalRef(charsets);
  env->DeleteLocalRef(strings);
  return result;
}

jobject boxedLong(JNIEnv* env, jlong value) {
  jclass clazz = env->FindClass("java/lang/Long");
  if (!clazz) { if (env->ExceptionCheck()) env->ExceptionClear(); return nullptr; }
  jmethodID ctor = env->GetMethodID(clazz, "<init>", "(J)V");
  if (!ctor) { if (env->ExceptionCheck()) env->ExceptionClear(); env->DeleteLocalRef(clazz); return nullptr; }
  jobject result = env->NewObject(clazz, ctor, value);
  if (env->ExceptionCheck()) { env->ExceptionClear(); result = nullptr; }
  env->DeleteLocalRef(clazz);
  return result;
}

jobject boxedDouble(JNIEnv* env, jdouble value) {
  jclass clazz = env->FindClass("java/lang/Double");
  if (!clazz) { if (env->ExceptionCheck()) env->ExceptionClear(); return nullptr; }
  jmethodID ctor = env->GetMethodID(clazz, "<init>", "(D)V");
  if (!ctor) { if (env->ExceptionCheck()) env->ExceptionClear(); env->DeleteLocalRef(clazz); return nullptr; }
  jobject result = env->NewObject(clazz, ctor, value);
  if (env->ExceptionCheck()) { env->ExceptionClear(); result = nullptr; }
  env->DeleteLocalRef(clazz);
  return result;
}

jobject newArrayList(JNIEnv* env) {
  jclass clazz = env->FindClass("java/util/ArrayList");
  if (!clazz) { if (env->ExceptionCheck()) env->ExceptionClear(); return nullptr; }
  jmethodID ctor = env->GetMethodID(clazz, "<init>", "()V");
  if (!ctor) { if (env->ExceptionCheck()) env->ExceptionClear(); env->DeleteLocalRef(clazz); return nullptr; }
  jobject result = env->NewObject(clazz, ctor);
  env->DeleteLocalRef(clazz);
  return result;
}

bool addToList(JNIEnv* env, jobject list, jobject item) {
  jclass clazz = env->GetObjectClass(list);
  if (!clazz) return false;
  jmethodID add = env->GetMethodID(clazz, "add", "(Ljava/lang/Object;)Z");
  if (!add) { if (env->ExceptionCheck()) env->ExceptionClear(); env->DeleteLocalRef(clazz); return false; }
  const jboolean added = env->CallBooleanMethod(list, add, item);
  env->DeleteLocalRef(clazz);
  if (env->ExceptionCheck()) { env->ExceptionClear(); return false; }
  return added == JNI_TRUE;
}

jobject query(JNIEnv* env, DbHandle* db, const std::string& sql, jobjectArray args) {
  sqlite3_stmt* statement = nullptr;
  if (!prepareAndBind(env, db, sql, args, &statement)) return nullptr;
  jobject rows = newArrayList(env);
  if (!rows) {
    api().finalize(statement);
    setError(env, db, SQLITE_NOMEM_VALUE, "jni row allocation failed");
    return nullptr;
  }
  const int columns = api().column_count(statement);
  int rc = SQLITE_OK_VALUE;
  while ((rc = api().step(statement)) == SQLITE_ROW_VALUE) {
    if (env->PushLocalFrame(64) < 0) {
      api().finalize(statement);
      setError(env, db, SQLITE_NOMEM_VALUE, "jni local frame unavailable");
      return nullptr;
    }
    jobject row = newArrayList(env);
    if (!row) {
      env->PopLocalFrame(nullptr);
      api().finalize(statement);
      setError(env, db, SQLITE_NOMEM_VALUE, "jni row allocation failed");
      return nullptr;
    }
    bool conversionFailed = false;
    for (int column = 0; column < columns; ++column) {
      jobject value = nullptr;
      switch (api().column_type(statement, column)) {
        case SQLITE_INTEGER_VALUE: value = boxedLong(env, api().column_int64(statement, column)); break;
        case SQLITE_FLOAT_VALUE: value = boxedDouble(env, api().column_double(statement, column)); break;
        case SQLITE_TEXT_VALUE: value = utf8String(env, api().column_text(statement, column), api().column_bytes(statement, column)); break;
        case SQLITE_BLOB_VALUE: {
          const int length = api().column_bytes(statement, column);
          auto* bytes = env->NewByteArray(length);
          if (!bytes) { conversionFailed = true; break; }
          if (length > 0) {
            const auto* blob = reinterpret_cast<const jbyte*>(api().column_blob(statement, column));
            if (!blob) { env->DeleteLocalRef(bytes); conversionFailed = true; break; }
            env->SetByteArrayRegion(bytes, 0, length, blob);
            if (env->ExceptionCheck()) { env->ExceptionClear(); env->DeleteLocalRef(bytes); conversionFailed = true; break; }
          }
          value = bytes;
          break;
        }
        case SQLITE_NULL_VALUE: default: value = nullptr; break;
      }
      if (api().column_type(statement, column) != SQLITE_NULL_VALUE && !value) conversionFailed = true;
      if (!conversionFailed && !addToList(env, row, value)) conversionFailed = true;
      if (value) env->DeleteLocalRef(value);
      if (conversionFailed) break;
    }
    if (!conversionFailed && !addToList(env, rows, row)) conversionFailed = true;
    env->PopLocalFrame(nullptr);
    if (conversionFailed || env->ExceptionCheck()) {
      if (env->ExceptionCheck()) env->ExceptionClear();
      api().finalize(statement);
      setError(env, db, SQLITE_MISUSE_VALUE, "jni query result construction failed");
      return nullptr;
    }
  }
  const int finalizeRc = api().finalize(statement);
  if (rc != SQLITE_DONE_VALUE || finalizeRc != SQLITE_OK_VALUE) {
    const int code = rc != SQLITE_DONE_VALUE ? rc : finalizeRc;
    setError(env, db, code, api().errmsg(db->db));
    return nullptr;
  }
  return rows;
}

void put(JNIEnv* env, jobject map, const char* key, jobject value) {
  jclass clazz = env->GetObjectClass(map);
  jmethodID method = env->GetMethodID(clazz, "put", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;");
  jstring name = env->NewStringUTF(key);
  jobject previous = env->CallObjectMethod(map, method, name, value);
  if (previous) env->DeleteLocalRef(previous);
  env->DeleteLocalRef(name);
  if (value) env->DeleteLocalRef(value);
  env->DeleteLocalRef(clazz);
}

void putLong(JNIEnv* env, jobject map, const char* key, jlong value) { put(env, map, key, boxedLong(env, value)); }

}  // namespace

extern "C" JNIEXPORT jobject JNICALL
Java_jp_universityschedule_notification_NativeSqliteBridge_identity(
    JNIEnv* env, jclass, jlongArray dartAddresses, jobject expectedLibraryPaths) {
  jclass mapClass = env->FindClass("java/util/HashMap");
  jobject result = env->NewObject(mapClass, env->GetMethodID(mapClass, "<init>", "()V"));
  env->DeleteLocalRef(mapClass);
  const bool ok = ready();
  auto& a = api();
  bool applicationOwned = false;
  if (ok && expectedLibraryPaths) {
    auto paths = static_cast<jobjectArray>(expectedLibraryPaths);
    const jsize count = env->GetArrayLength(paths);
    for (jsize i = 0; i < count && !applicationOwned; ++i) {
      auto candidate = static_cast<jstring>(env->GetObjectArrayElement(paths, i));
      if (candidate) {
        const char* expected = env->GetStringUTFChars(candidate, nullptr);
        applicationOwned = expected && a.library_path == expected;
        if (expected) env->ReleaseStringUTFChars(candidate, expected);
        env->DeleteLocalRef(candidate);
      }
    }
  }
  const bool certified = ok && applicationOwned;
  put(env, result, "ok", env->NewStringUTF(certified ? "true" : "false"));
  put(env, result, "libraryPath", env->NewStringUTF(a.library_path.c_str()));
  put(env, result, "sourceId", env->NewStringUTF(ok ? a.sourceid() : ""));
  put(env, result, "version", env->NewStringUTF(ok ? a.libversion() : ""));
  putLong(env, result, "threadsafe", ok ? a.threadsafe() : 0);
  putLong(env, result, "vfsAddress", ok ? reinterpret_cast<jlong>(a.vfs_find(nullptr)) : 0);
  bool pointersMatch = ok && applicationOwned;
  bool vfsMatch = true;
  if (ok && dartAddresses) {
    const jsize count = env->GetArrayLength(dartAddresses);
    std::vector<jlong> values(static_cast<size_t>(count));
    env->GetLongArrayRegion(dartAddresses, 0, count, values.data());
    std::vector<jlong> native = {
      reinterpret_cast<jlong>(a.open_v2), reinterpret_cast<jlong>(a.prepare_v2),
      reinterpret_cast<jlong>(a.step), reinterpret_cast<jlong>(a.finalize),
      reinterpret_cast<jlong>(a.close_v2),
    };
    if (values.empty()) {
      // An empty address list is an intentional native-only certificate.
      pointersMatch = applicationOwned;
    } else {
      if (values.size() != native.size() + 1) pointersMatch = false;
      for (size_t i = 0; pointersMatch && i < native.size(); ++i) pointersMatch = values[i] == native[i];
      if (pointersMatch && values.size() == native.size() + 1) {
        vfsMatch = values.back() == reinterpret_cast<jlong>(a.vfs_find(nullptr));
      }
    }
  } else if (ok) {
    // An empty address list is the native-first certificate used by cold
    // receivers before a Dart engine exists. It still checks the exact
    // app-owned library, source/VFS and thread-safety metadata above.
    pointersMatch = applicationOwned;
  }
  put(env, result, "pointersMatch", env->NewStringUTF(pointersMatch ? "true" : "false"));
  put(env, result, "vfsMatch", env->NewStringUTF(vfsMatch ? "true" : "false"));
  put(env, result, "reason", env->NewStringUTF(!certified ? "sqlite_asset_unavailable" : (dartAddresses && env->GetArrayLength(dartAddresses) > 0 && (!pointersMatch || !vfsMatch) ? "dart_binding_mismatch" : (pointersMatch && vfsMatch ? "ok" : "native_identity_failed"))));
  return result;
}

extern "C" JNIEXPORT jlong JNICALL
Java_jp_universityschedule_notification_NativeSqliteBridge_open(JNIEnv* env, jclass, jstring path, jboolean readOnly, jboolean create) {
  last_open_error_code = SQLITE_CANTOPEN_VALUE;
  last_open_error_message = "sqlite asset identity unavailable";
  if (!ready()) { throwIllegal(env, last_open_error_message); return 0; }
  const char* chars = env->GetStringUTFChars(path, nullptr);
  if (!chars) {
    if (env->ExceptionCheck()) env->ExceptionClear();
    last_open_error_code = SQLITE_NOMEM_VALUE;
    last_open_error_message = "sqlite path conversion failed";
    throwIllegal(env, last_open_error_message);
    return 0;
  }
  auto* value = new DbHandle();
  const int flags = readOnly ? 0x00000001 : (SQLITE_OPEN_READWRITE_VALUE | (create ? 0x00000004 : 0));
  const int rc = api().open_v2(chars, &value->db, flags, nullptr);
  env->ReleaseStringUTFChars(path, chars);
  if (rc != SQLITE_OK_VALUE || !value->db) {
    const std::string message = value->db ? api().errmsg(value->db) : "sqlite open failed";
    last_open_error_code = rc;
    last_open_error_message = message;
    if (value->db) api().close_v2(value->db);
    delete value;
    throwIllegal(env, message);
    return 0;
  }
  // Native coordinator calls run while scope/registry fences are held. Never
  // sleep behind a competing Dart writer; the caller maps SQLITE_BUSY to one
  // bounded refill after all native cleanup has unwound.
  api().busy_timeout(value->db, 0);
  return reinterpret_cast<jlong>(value);
}

extern "C" JNIEXPORT jint JNICALL
Java_jp_universityschedule_notification_NativeSqliteBridge_exec(JNIEnv* env, jclass, jlong pointer, jstring sql, jobjectArray args) {
  auto* db = handle(pointer); if (!db || !db->db) return SQLITE_MISUSE_VALUE;
  const char* chars = env->GetStringUTFChars(sql, nullptr);
  if (!chars) {
    if (env->ExceptionCheck()) env->ExceptionClear();
    setError(env, db, SQLITE_NOMEM_VALUE, "sqlite SQL conversion failed");
    return db->error_code;
  }
  sqlite3_stmt* statement = nullptr;
  const bool prepared = prepareAndBind(env, db, chars, args, &statement);
  env->ReleaseStringUTFChars(sql, chars);
  if (!prepared) return db->error_code;
  int rc = api().step(statement);
  const int finalizeRc = api().finalize(statement);
  if (rc != SQLITE_DONE_VALUE || finalizeRc != SQLITE_OK_VALUE) {
    db->error_code = rc != SQLITE_DONE_VALUE ? rc : finalizeRc;
    db->error_message = api().errmsg(db->db);
    return db->error_code;
  }
  db->error_code = SQLITE_OK_VALUE; db->error_message.clear(); return SQLITE_OK_VALUE;
}

extern "C" JNIEXPORT jobject JNICALL
Java_jp_universityschedule_notification_NativeSqliteBridge_query(JNIEnv* env, jclass, jlong pointer, jstring sql, jobjectArray args) {
  auto* db = handle(pointer); if (!db || !db->db) return nullptr;
  const char* chars = env->GetStringUTFChars(sql, nullptr);
  if (!chars) {
    if (env->ExceptionCheck()) env->ExceptionClear();
    setError(env, db, SQLITE_NOMEM_VALUE, "sqlite SQL conversion failed");
    return nullptr;
  }
  const std::string statement(chars);
  env->ReleaseStringUTFChars(sql, chars);
  jobject result = query(env, db, statement, args);
  if (result) { db->error_code = SQLITE_OK_VALUE; db->error_message.clear(); }
  return result;
}

extern "C" JNIEXPORT jint JNICALL
Java_jp_universityschedule_notification_NativeSqliteBridge_errorCode(JNIEnv*, jclass, jlong pointer) {
  auto* db = handle(pointer); return db ? db->error_code : last_open_error_code;
}

extern "C" JNIEXPORT jint JNICALL
Java_jp_universityschedule_notification_NativeSqliteBridge_autocommit(JNIEnv*, jclass, jlong pointer) {
  auto* db = handle(pointer);
  if (!db || !db->db || !api().get_autocommit) return -1;
  return api().get_autocommit(db->db);
}

extern "C" JNIEXPORT jstring JNICALL
Java_jp_universityschedule_notification_NativeSqliteBridge_errorMessage(JNIEnv* env, jclass, jlong pointer) {
  auto* db = handle(pointer); return env->NewStringUTF(db ? db->error_message.c_str() : last_open_error_message.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_jp_universityschedule_notification_NativeSqliteBridge_close(JNIEnv*, jclass, jlong pointer) {
  auto* db = handle(pointer); if (!db) return SQLITE_MISUSE_VALUE;
  const int rc = db->db ? api().close_v2(db->db) : SQLITE_OK_VALUE;
  if (rc != SQLITE_OK_VALUE) {
    db->error_code = rc;
    db->error_message = "sqlite close failed";
    return rc;
  }
  delete db;
  return SQLITE_OK_VALUE;
}
