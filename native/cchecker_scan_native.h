/* The C side of `extern module "cchecker_scan"` in scan.agc, made by native-gen.
   Do not edit it: change the .agc and make it again. */
#ifndef CCHECKER_SCAN_NATIVE_H
#define CCHECKER_SCAN_NATIVE_H

#include "agentica_native.h"

#if AN_API_MAJOR != 1
#error "cchecker_scan_native.h needs version 1 of the native API (agentica_native.h)"
#endif
#if AN_API_MINOR < 1
#error "cchecker_scan_native.h needs version 1.1 or later of the native API (agentica_native.h)"
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* A String or Bytes argument, borrowed for the call: copy it to keep it. String data is UTF-8 with no NUL at its
   end. Every header of this version of native-gen has these two, so one file can include several. */
#ifndef NATIVE_GEN_SLICES_1
#define NATIVE_GEN_SLICES_1
typedef struct {
  const char *data;
  size_t len;
} ng_str;
typedef struct {
  const uint8_t *data;
  size_t len;
} ng_buf;
#endif

/* The rows of the type table: the TYPE of an_struct, an_enum and their getters. */
enum { CCHECKER_SCAN_TYPE_Place = 0, CCHECKER_SCAN_TYPE_NativeDump = 1 };

/* The fields of Place, in declared order. */
enum { CCHECKER_SCAN_Place_raw = 0, CCHECKER_SCAN_Place_encoded = 1, CCHECKER_SCAN_Place_inside = 2 };

/* The fields of NativeDump, in declared order. */
enum { CCHECKER_SCAN_NativeDump_decls = 0, CCHECKER_SCAN_NativeDump_oversized = 1, CCHECKER_SCAN_NativeDump_skipped = 2, CCHECKER_SCAN_NativeDump_ended = 3 };

/* The structs and enums as C values. A String or Bytes in them is borrowed, a term lasts for the call: keep them
   in C locals. _get reads a term into OUT; false when it is not one, and then the call has failed with the path of
   the first bad part. A function whose signature does not reach the type reads none ("Point: expected Point").
   _make and the constructors (one per variant) make a term. */

typedef struct {
  ng_str raw;
  ng_str encoded;
  bool inside;
} cchecker_scan_Place;
bool cchecker_scan_Place_get(an_env *env, an_term t, cchecker_scan_Place *out);

typedef struct {
  ng_str decls;
  an_term oversized;
  int64_t skipped;
  bool ended;
} cchecker_scan_NativeDump;
an_term cchecker_scan_NativeDump_make(an_env *env, const cchecker_scan_NativeDump *value);

/* The Lists, Maps, Optionals and Results. A List or Map that is read is a cursor: _next gives 1 for an item, 0 at
   the end, and -1 when the item does not decode: the call has then failed with the path of the item in its own
   List or Map (an item of a List or Map read from another has the path from the inner one, `List[Float].1`),
   after `argument N: ` when the cursor came from an argument (`argument` is then N; it is 0 after _open), and
   every later _next gives -1 too, as after a failed _open. A builder makes one: _begin, then _push (_put for a
   Map), then _end. Cursors and builders hold terms: keep them in C locals, for this call only. An Optional or
   Result that is read is a struct, whose value is zero when there is none and whose error is borrowed as a String
   argument is; _get reads one held as a term. One that is made has _some or _ok (an_none and an_error make the
   others). */

typedef struct {
  an_term term;
  an_list_cursor cursor;
  size_t len;
  size_t at;
  bool failed;
  int argument; /* 1 + the index of the argument of the call it was opened for, or 0 (_open) */
} cchecker_scan_list_Place;
bool cchecker_scan_list_Place_open(an_env *env, an_term t, cchecker_scan_list_Place *out);
int cchecker_scan_list_Place_next(an_env *env, cchecker_scan_list_Place *list, cchecker_scan_Place *out);

an_term cchecker_scan_result_Bool_ok(an_env *env, bool value);

typedef struct {
  an_list_builder builder;
} cchecker_scan_list_String_builder;
void cchecker_scan_list_String_begin(an_env *env, cchecker_scan_list_String_builder *b, size_t hint);
void cchecker_scan_list_String_push(an_env *env, cchecker_scan_list_String_builder *b, ng_str value);
an_term cchecker_scan_list_String_end(an_env *env, cchecker_scan_list_String_builder *b);

an_term cchecker_scan_result_list_String_ok(an_env *env, an_term value);

an_term cchecker_scan_result_NativeDump_ok(an_env *env, cchecker_scan_NativeDump value);

/* Makes the FIFO at `path` that clang writes its dump into, for `compact`. */
an_term cchecker_scan_fifo(an_env *env, ng_str path);

/* Copies the dump that clang writes into the FIFO `from` to the file `to`, until clang closes it, with the indent of
   each line cut short, and gives the values of its `"file": ` lines for `decls_in`. clang indents a node two spaces
   per level, so the dump of a deep tree (a chain of else-if) is gigabytes of spaces; the copy scans as the dump
   would, and stays the size of the tree. Past `timeout_ms` from the start of the call (a writer that never opens
   the FIFO included) it gives the error TIMED_OUT; another error before a writer opened it starts with UNSTARTED. */
an_term cchecker_scan_compact(an_env *env, ng_str from, ng_str to, int64_t timeout_ms);

an_term cchecker_scan_files(an_env *env, ng_str path);

an_term cchecker_scan_scan(an_env *env, ng_str path, cchecker_scan_list_Place places, bool prune);

#ifdef __cplusplus
}
#endif

#endif

/* Outside the include guard, so a file that included the header before it defined the switch still gets this
   part; its own guard keeps it to one copy. */
#if defined(CCHECKER_SCAN_NATIVE_IMPLEMENTATION) && !defined(CCHECKER_SCAN_NATIVE_IMPLEMENTATION_DONE)
#define CCHECKER_SCAN_NATIVE_IMPLEMENTATION_DONE
/* Declared with C linkage, so a module built as C++ exports it under its C name. */
#ifdef __cplusplus
extern "C" {
#endif
AN_EXPORT const an_module *agentica_native_init(const an_api *api);
#ifdef __cplusplus
}
#endif

#ifndef NATIVE_GEN_FAIL_1
#define NATIVE_GEN_FAIL_1
#include <stdio.h>
#include <string.h>

/* Where a decode failed: the path from the outer value in, and the type that was expected there. */
typedef struct {
  char path[192];
  size_t len;
  bool cut;
  const char *expected;
} ng_fail;

static inline bool ng_expected(ng_fail *fail, const char *expected) {
  fail->path[0] = '\0';
  fail->len = 0;
  fail->cut = false;
  fail->expected = expected;
  return false;
}

/* Puts SEGMENT in front of the path. The first one that does not fit becomes "..." and ends the path, which
   keeps its inner part. */
static inline bool ng_at(ng_fail *fail, const char *segment) {
  size_t n = strlen(segment), dot = fail->len > 0 ? 1 : 0;
  if (fail->cut) return false;
  if (n + dot + fail->len >= sizeof fail->path) {
    fail->cut = true;
    segment = "...";
    n = 3;
    if (n + dot + fail->len >= sizeof fail->path) return false;
  }
  memmove(fail->path + n + dot, fail->path, fail->len + 1);
  memcpy(fail->path, segment, n);
  if (dot) fail->path[n] = '.';
  fail->len += n + dot;
  return false;
}

static inline bool ng_leaf(ng_fail *fail, const char *expected, const char *segment) {
  ng_expected(fail, expected);
  return ng_at(fail, segment);
}

/* Fails the call with "WHERE TYPE.PATH: expected X". */
static inline bool ng_raise(an_env *env, const char *where, const char *type, ng_fail *fail) {
  char message[256];
  ng_at(fail, type);
  snprintf(message, sizeof message, "%s%s: expected %s", where, fail->path, fail->expected);
  an_raise(env, message);
  return false;
}

/* Fails the call at item INDEX (and PART of it, "key" or "value", or NULL) of a List or Map; -1 for _next. */
static inline int ng_fail_item(an_env *env, ng_fail *fail, const char *type, size_t index, const char *part) {
  char segment[48];
  if (part)
    snprintf(segment, sizeof segment, "%zu.%s", index, part);
  else
    snprintf(segment, sizeof segment, "%zu", index);
  ng_at(fail, segment);
  ng_raise(env, "", type, fail);
  return -1;
}

static inline an_term ng_fail_argument(an_env *env, ng_fail *fail, const char *type, int index) {
  char where[32];
  snprintf(where, sizeof where, "argument %d: ", index + 1);
  ng_raise(env, where, type, fail);
  return an_void(env);
}
#endif

/* A block of its own: the block above is the same in every header since 0.1.0, so a file that includes an older
   header first keeps that copy, and this one still comes in. */
#ifndef NATIVE_GEN_FAIL_ITEM_2
#define NATIVE_GEN_FAIL_ITEM_2
/* As ng_fail_item, with the "argument N: " prefix when ARGUMENT (1 + the index of the argument the cursor was
   opened for) is not 0. */
static inline int ng_fail_cursor_item(an_env *env, ng_fail *fail, const char *type, int argument, size_t index,
                                      const char *part) {
  char segment[48];
  char where[32] = "";
  if (part)
    snprintf(segment, sizeof segment, "%zu.%s", index, part);
  else
    snprintf(segment, sizeof segment, "%zu", index);
  if (argument) snprintf(where, sizeof where, "argument %d: ", argument);
  ng_at(fail, segment);
  ng_raise(env, where, type, fail);
  return -1;
}
#endif

static bool cchecker_scan_native_get_Place(an_env *env, an_term t, cchecker_scan_Place *out, ng_fail *fail) {
  an_term x;
  if (!an_get_field(env, t, CCHECKER_SCAN_TYPE_Place, 0, &x)) return ng_expected(fail, "Place");
  if (!an_get_string(env, x, &out->raw.data, &out->raw.len)) return ng_leaf(fail, "String", "raw");
  if (!an_get_field(env, t, CCHECKER_SCAN_TYPE_Place, 1, &x)) return ng_expected(fail, "Place");
  if (!an_get_string(env, x, &out->encoded.data, &out->encoded.len)) return ng_leaf(fail, "String", "encoded");
  if (!an_get_field(env, t, CCHECKER_SCAN_TYPE_Place, 2, &x)) return ng_expected(fail, "Place");
  if (!an_get_bool(env, x, &out->inside)) return ng_leaf(fail, "Bool", "inside");
  return true;
}

bool cchecker_scan_Place_get(an_env *env, an_term t, cchecker_scan_Place *out) {
  ng_fail fail;
  return cchecker_scan_native_get_Place(env, t, out, &fail) || ng_raise(env, "", "Place", &fail);
}

an_term cchecker_scan_NativeDump_make(an_env *env, const cchecker_scan_NativeDump *value) {
  an_term fields[4];
  fields[0] = an_string(env, value->decls.data, value->decls.len);
  fields[1] = value->oversized;
  fields[2] = an_int(env, value->skipped);
  fields[3] = an_bool(env, value->ended);
  return an_struct(env, CCHECKER_SCAN_TYPE_NativeDump, fields);
}

static bool cchecker_scan_native_item_Place(an_env *env, an_term x, cchecker_scan_Place *out, ng_fail *fail) {
  return cchecker_scan_native_get_Place(env, x, &(*out), fail);
}

static bool cchecker_scan_native_open_list_Place(an_env *env, an_term t, cchecker_scan_list_Place *out, ng_fail *fail) {
  memset(out, 0, sizeof *out);
  out->term = t;
  if (an_list_cursor_begin(env, t, &out->cursor, &out->len)) return true;
  out->failed = true;
  return ng_expected(fail, "List[Place]");
}

bool cchecker_scan_list_Place_open(an_env *env, an_term t, cchecker_scan_list_Place *out) {
  ng_fail fail;
  return cchecker_scan_native_open_list_Place(env, t, out, &fail) || ng_raise(env, "", "List[Place]", &fail);
}

int cchecker_scan_list_Place_next(an_env *env, cchecker_scan_list_Place *list, cchecker_scan_Place *out) {
  an_term x;
  ng_fail fail;
  size_t at = list->at;
  if (list->failed) return -1;
  if (!an_list_next(env, &list->cursor, &x)) return 0;
  list->at++;
  if (cchecker_scan_native_item_Place(env, x, out, &fail)) return 1;
  list->failed = true;
  return ng_fail_cursor_item(env, &fail, "List[Place]", list->argument, at, NULL);
}

an_term cchecker_scan_result_Bool_ok(an_env *env, bool value) {
  return an_ok(env, an_bool(env, value));
}

void cchecker_scan_list_String_begin(an_env *env, cchecker_scan_list_String_builder *b, size_t hint) { an_list_begin(env, &b->builder, hint); }

void cchecker_scan_list_String_push(an_env *env, cchecker_scan_list_String_builder *b, ng_str value) {
  an_list_push(env, &b->builder, an_string(env, value.data, value.len));
}

an_term cchecker_scan_list_String_end(an_env *env, cchecker_scan_list_String_builder *b) { return an_list_end(env, &b->builder); }

an_term cchecker_scan_result_list_String_ok(an_env *env, an_term value) {
  return an_ok(env, value);
}

an_term cchecker_scan_result_NativeDump_ok(an_env *env, cchecker_scan_NativeDump value) {
  return an_ok(env, cchecker_scan_NativeDump_make(env, &value));
}

static an_term cchecker_scan_native_fifo(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  ng_str a0;
  if (!an_get_string(env, argv[0], &a0.data, &a0.len)) return an_badarg(env, 0);
  return cchecker_scan_fifo(env, a0);
}

static an_term cchecker_scan_native_compact(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  ng_str a0;
  if (!an_get_string(env, argv[0], &a0.data, &a0.len)) return an_badarg(env, 0);
  ng_str a1;
  if (!an_get_string(env, argv[1], &a1.data, &a1.len)) return an_badarg(env, 1);
  int64_t a2;
  if (!an_get_int(env, argv[2], &a2)) return an_badarg(env, 2);
  return cchecker_scan_compact(env, a0, a1, a2);
}

static an_term cchecker_scan_native_files(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  ng_str a0;
  if (!an_get_string(env, argv[0], &a0.data, &a0.len)) return an_badarg(env, 0);
  return cchecker_scan_files(env, a0);
}

static an_term cchecker_scan_native_scan(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  ng_fail fail;
  ng_str a0;
  if (!an_get_string(env, argv[0], &a0.data, &a0.len)) return an_badarg(env, 0);
  cchecker_scan_list_Place a1;
  if (!cchecker_scan_native_open_list_Place(env, argv[1], &a1, &fail))
    return ng_fail_argument(env, &fail, "List[Place]", 1);
  a1.argument = 2;
  bool a2;
  if (!an_get_bool(env, argv[2], &a2)) return an_badarg(env, 2);
  return cchecker_scan_scan(env, a0, a1, a2);
}

static const an_function cchecker_scan_native_functions[] = {
  {"fifo", "(String) -> Result[Bool]", cchecker_scan_native_fifo, AN_DIRTY},
  {"compact", "(String, String, Int) -> Result[List[String]]", cchecker_scan_native_compact, AN_DIRTY},
  {"files", "(String) -> Result[List[String]]", cchecker_scan_native_files, AN_DIRTY},
  {"scan", "(String, List[Place], Bool) -> Result[NativeDump]", cchecker_scan_native_scan, AN_DIRTY},
};

static const an_type cchecker_scan_native_types[] = {
  {"Place", AN_STRUCT, "raw: String, encoded: String, inside: Bool"},
  {"NativeDump", AN_STRUCT, "decls: String, oversized: List[String], skipped: Int, ended: Bool"},
};

/* Ends the module's one .c file: the tables and agentica_native_init. LOAD is NULL or a const char *(*)(void)
   that runs once at the first call, and refuses the module with the message it returns. */
#define CCHECKER_SCAN_NATIVE_MODULE(LOAD) AN_MODULE_TABLES("cchecker_scan", cchecker_scan_native_functions, 4, cchecker_scan_native_types, 2, NULL, 0, LOAD)
#endif
