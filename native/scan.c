/* The scan of src/scan.agc in C: the same state machine over the lines of clang's JSON AST, at the speed of a read.
 * src/scan.agc stays the reference (test/scan_test.agc compares both on real dumps); keep the two in step.
 *
 * Two calls, both short: a dump of 40 MiB takes some hundred milliseconds, which is not worth the hop to the compute
 * pool (measured on the VM of Agentica).
 *   files(path)        the distinct values of the `"file": ` lines, as written (JSON text), for the caller to resolve
 *                      with Paths: where a file is and whether it is in the project stay Agentica's.
 *   scan(path, places, prune)
 *                      the kept declarations as the text of a JSON array, the names (JSON text) of the declarations
 *                      too large to keep that name a function, the count of those that name none, and whether the
 *                      dump ended. A `"file": ` value that `places` lacks is no file of the project. With
 *                      `prune`, the keys that no rule reads are left out (see `pruned`); without it, the text is
 *                      that of the reference.
 *
 * Memory: one line, the current declaration and the result text are held at once, in malloc memory freed before the
 * call returns; the returned terms are the VM's. A line is at most LINE_BYTES (as File.foreach reads it); a longer
 * one, a line that is not UTF-8, or a failed read is an error result. */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "agentica_native.h"

#define LINE_BYTES 16777216
#define MAX_DECL_LINES 1000000

enum { NATIVE_DUMP, PLACE };
enum phase { BETWEEN, OPEN, KEPT, DROPPED, OVERSIZED };

typedef struct {
  char *data;
  size_t len, cap;
  bool failed;
} buf;

static void put(buf *b, const char *s, size_t n) {
  if (b->failed) return;
  if (b->len + n + 1 > b->cap) {
    size_t cap = b->cap ? b->cap : 4096;
    while (b->len + n + 1 > cap) cap *= 2;
    char *data = realloc(b->data, cap);
    if (!data) {
      b->failed = true;
      return;
    }
    b->data = data;
    b->cap = cap;
  }
  memcpy(b->data + b->len, s, n);
  b->len += n;
}

static void puts_(buf *b, const char *s) { put(b, s, strlen(s)); }

typedef struct {
  const char *s;
  size_t n;
} slice;

#define LIT(x) ((slice){x, sizeof(x) - 1})

static bool eq(slice a, slice b) { return a.n == b.n && memcmp(a.s, b.s, a.n) == 0; }
static bool starts(slice a, slice p) { return a.n >= p.n && memcmp(a.s, p.s, p.n) == 0; }
static bool ends(slice a, slice p) { return a.n >= p.n && memcmp(a.s + a.n - p.n, p.s, p.n) == 0; }
static bool has(slice a, char c) { return a.n > 0 && memchr(a.s, c, a.n) != NULL; }

/* String.strip of the VM: space, tab, LF, FF and CR. */
static bool space(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\f' || c == '\r'; }

static slice strip(slice a) {
  /* clang indents with spaces, hundreds of them in a deep expression: eight at a time first. */
  static const char eight[8] = {' ', ' ', ' ', ' ', ' ', ' ', ' ', ' '};
  while (a.n >= 8 && memcmp(a.s, eight, 8) == 0) a.s += 8, a.n -= 8;
  while (a.n > 0 && space(a.s[0])) a.s++, a.n--;
  while (a.n > 0 && space(a.s[a.n - 1])) a.n--;
  return a;
}

/* value_of: the text after the key, without one trailing comma. */
static slice value_of(slice text, slice key) {
  slice v = {text.s + key.n, text.n - key.n};
  if (v.n > 0 && v.s[v.n - 1] == ',') v.n--;
  return v;
}

static bool utf8(const unsigned char *s, size_t n) {
  size_t i = 0;
  while (i < n) {
    /* Nearly all of a dump is ASCII: eight bytes at a time while no byte has its high bit. */
    if (i + 8 <= n) {
      uint64_t word;
      memcpy(&word, s + i, 8);
      if ((word & 0x8080808080808080ULL) == 0) {
        i += 8;
        continue;
      }
    }
    unsigned char c = s[i];
    if (c < 0x80) {
      i++;
      continue;
    }
    size_t k;
    uint32_t cp;
    if (c >= 0xC2 && c <= 0xDF) k = 1, cp = c & 0x1F;
    else if (c >= 0xE0 && c <= 0xEF) k = 2, cp = c & 0x0F;
    else if (c >= 0xF0 && c <= 0xF4) k = 3, cp = c & 0x07;
    else return false;
    if (i + k >= n) return false;
    for (size_t j = 1; j <= k; j++) {
      if ((s[i + j] & 0xC0) != 0x80) return false;
      cp = (cp << 6) | (s[i + j] & 0x3F);
    }
    if ((k == 2 && (cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF))) || (k == 3 && (cp < 0x10000 || cp > 0x10FFFF)))
      return false;
    i += k + 1;
  }
  return true;
}

/* The lines of a file as File.foreach gives them: without LF or CRLF, a final line without one included. The file is
 * read in blocks into `data`, which grows to hold the longest line (at most LINE_BYTES and its line ending). */
#define BLOCK_BYTES ((size_t)1 << 20)

typedef struct {
  FILE *f;
  char *data;
  size_t cap, start, end;
  bool eof;
  bool any_bytes; /* files() reads only ASCII keys: it leaves the UTF-8 check to scan() */
  const char *error;
} lines;

/* Gives the next line in *line, or *done at the end. On false, `error` says why. */
static bool next_line(lines *r, slice *line, bool *done) {
  for (;;) {
    char *nl = r->end > r->start ? memchr(r->data + r->start, '\n', r->end - r->start) : NULL;
    size_t n;
    char *at = r->data + r->start;
    if (nl) {
      n = (size_t)(nl - at);
      r->start += n + 1;
      if (n > 0 && at[n - 1] == '\r') n--;
    } else if (r->eof) {
      if (r->start == r->end) {
        *done = true;
        return true;
      }
      n = r->end - r->start;
      r->start = r->end;
    } else {
      size_t rest = r->end - r->start;
      if (rest > LINE_BYTES + 1) {
        r->error = "a line of the AST dump is longer than 16777216 bytes";
        return false;
      }
      memmove(r->data, at, rest);
      r->start = 0;
      r->end = rest;
      if (r->cap - r->end < BLOCK_BYTES / 2) {
        size_t cap = r->cap ? r->cap * 2 : BLOCK_BYTES;
        char *grown = realloc(r->data, cap);
        if (!grown) {
          r->error = "out of memory reading the AST dump";
          return false;
        }
        r->data = grown;
        r->cap = cap;
      }
      size_t got = fread(r->data + r->end, 1, r->cap - r->end, r->f);
      r->end += got;
      if (got == 0) {
        if (ferror(r->f)) {
          r->error = "the AST dump could not be read";
          return false;
        }
        r->eof = true;
      }
      continue;
    }
    if (n > LINE_BYTES) {
      r->error = "a line of the AST dump is longer than 16777216 bytes";
      return false;
    }
    if (!r->any_bytes && !utf8((const unsigned char *)at, n)) {
      r->error = "the AST dump is not UTF-8";
      return false;
    }
    *line = (slice){at, n};
    *done = false;
    return true;
  }
}

static bool open_lines(an_env *env, an_term path_term, lines *r, an_term *failure) {
  const char *data;
  size_t len;
  memset(r, 0, sizeof *r);
  if (!an_get_string(env, path_term, &data, &len)) {
    *failure = an_badarg(env, 0);
    return false;
  }
  char *path = malloc(len + 1);
  if (!path) {
    *failure = an_raise(env, "out of memory");
    return false;
  }
  memcpy(path, data, len);
  path[len] = '\0';
  r->f = fopen(path, "rb");
  free(path);
  if (!r->f) {
    static const char message[] = "the AST dump could not be opened";
    *failure = an_error(env, message, sizeof message - 1);
    return false;
  }
  return true;
}

static void close_lines(lines *r) {
  if (r->f) fclose(r->f);
  free(r->data);
}

/* files(path: String) -> Result[List[String]] */
static an_term files(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  lines r;
  an_term failure;
  if (!open_lines(env, argv[0], &r, &failure)) return failure;
  r.any_bytes = true;
  /* Few distinct files (some hundreds), each seen many times: a linear search over the seen ones, last hit first. */
  buf seen = {0};
  size_t *offsets = NULL, count = 0, cap = 0, last = 0;
  bool done = false, failed = false;
  slice line;
  while (next_line(&r, &line, &done) && !done) {
    slice text = strip(line);
    if (!starts(text, LIT("\"file\": "))) continue;
    slice v = value_of(text, LIT("\"file\": "));
    bool found = false;
    for (size_t k = 0; k < count && !found; k++) {
      size_t at = (last + k) % count;
      const char *s = seen.data + offsets[at];
      if (strlen(s) == v.n && memcmp(s, v.s, v.n) == 0) found = true, last = at;
    }
    if (found) continue;
    if (count == cap) {
      cap = cap ? cap * 2 : 64;
      size_t *grown = realloc(offsets, cap * sizeof *offsets);
      if (!grown) {
        failed = true;
        break;
      }
      offsets = grown;
    }
    offsets[count++] = seen.len;
    put(&seen, v.s, v.n);
    put(&seen, "", 1);
  }
  an_term result;
  if (r.error) {
    result = an_error(env, r.error, strlen(r.error));
  } else if (failed || seen.failed) {
    result = an_raise(env, "out of memory");
  } else {
    an_list_builder b;
    an_list_begin(env, &b, count);
    for (size_t k = 0; k < count; k++) {
      const char *s = seen.data + offsets[k];
      an_list_push(env, &b, an_string(env, s, strlen(s)));
    }
    result = an_ok(env, an_list_end(env, &b));
  }
  free(offsets);
  free(seen.data);
  close_lines(&r);
  return result;
}

typedef struct {
  const char *raw, *encoded;
  size_t raw_n, encoded_n;
  bool inside;
} place;

typedef struct {
  place *places;
  size_t count, last;
  /* The state of src/scan.agc, field for field. */
  const char *encoded;
  size_t encoded_n;
  int64_t line;
  bool inside, included, spelling, variable, array, items, functions;
  enum phase phase;
  buf desugared, name;
  buf decl; /* the kept lines of the declaration, joined by LF */
  size_t decl_lines; /* the lines kept, pruned ones included, as the reference counts them for MAX_DECL_LINES */
  bool prune;
  size_t skip_depth; /* > 0 inside the object or list of a pruned key */
  /* A location written in short (prune): the `"loc": {` of a node, or a `"begin": {` or `"end": {` of its
   * `"range": {`. `frames` are the objects open inside it ('E' expansionLoc, 'O' another), `direct` the place at its
   * own level and `expansion` the one in its expansionLoc. */
  bool in_range;
  const char *located_key; /* NULL outside a location */
  char frames[8];
  size_t frame_count;
  bool has_expansion_key, has_direct, has_expansion;
  buf direct, expansion; /* `FILE, LINE, COL` as JSON text */
  slice col; /* the `col` of the location line being kept, set by located() */
  buf marked; /* the location line being written, kept between lines to spare an allocation for each */
  buf out; /* the kept declarations, joined by ",\n" */
  size_t kept;
  buf oversized; /* the names, each ended by a NUL */
  size_t oversized_count;
  int64_t skipped;
  bool ended;
} state;

static void set(buf *b, slice v) {
  b->len = 0;
  put(b, v.s, v.n);
}

/* The keys that no rule reads, which `prune` leaves out of the kept text: the parts of a location that the scan has
 * written into `cc_file` and `cc_line` (or that no rule reads: the offset, the length of the token, the spelling of a
 * macro), and flags of clang that no rule asks for. About a third of the text and of the parsed values. A key that a
 * rule reads must never be here (`rg '"KEY"' src` finds none for each). */
static const char *const pruned[] = {
  "offset",       "tokLen",        "includedFrom",   "file",         "line",           "spellingLoc",
  "valueCategory", "typeAliasDeclId", "isMacroArgExpansion", "mangledName", "isUsed", "isReferenced",
  "isImplicit",   "isPartOfExplicitCast", "canOverflow", "computeResultType", "computeLHSType", "tagUsed",
  "completeDefinition", "previousDecl",
};

/* Whether a stripped line is `"KEY": ...` of a pruned key. */
static bool pruned_key(slice text) {
  if (text.n < 4 || text.s[0] != '"') return false;
  const char *quote = memchr(text.s + 1, '"', text.n - 1);
  if (!quote) return false;
  slice key = {text.s + 1, (size_t)(quote - text.s - 1)};
  if (key.n + 4 > text.n || quote[1] != ':') return false;
  for (size_t k = 0; k < sizeof pruned / sizeof pruned[0]; k++)
    if (eq(key, (slice){pruned[k], strlen(pruned[k])})) return true;
  return false;
}

static bool opens(slice text) { return text.n > 0 && (text.s[text.n - 1] == '{' || text.s[text.n - 1] == '['); }
static bool closes(slice text) { return text.n > 0 && (text.s[0] == '}' || text.s[0] == ']'); }

/* Appends a line to the declaration. A key left out may have been the last of its object: the comma before a closing
 * line goes, so the text stays JSON. */
static void append(state *s, slice text) {
  if (closes(strip(text)) && s->decl.len > 0 && s->decl.data[s->decl.len - 1] == ',') s->decl.len--;
  if (s->decl.len > 0) put(&s->decl, "\n", 1);
  put(&s->decl, text.s, text.n);
}

/* The place of a location line (`"cc_file": ..., "cc_line": ..., "col": ...`), as `FILE, LINE, COL`. */
static void set_place(state *s, buf *at) {
  char number[32];
  int written = snprintf(number, sizeof number, ", %lld, ", (long long)s->line);
  at->len = 0;
  put(at, s->encoded, s->encoded_n);
  put(at, number, (size_t)written);
  put(at, s->col.s, s->col.n);
}

/* The end of a location: the key it was under, with the place that Ast.expanded reads from it (that of its
 * expansionLoc when it has one, else its own; "" and 0 for what it lacks). */
static void close_location(state *s) {
  bool expansion = s->has_expansion_key;
  bool found = expansion ? s->has_expansion : s->has_direct;
  buf *at = expansion ? &s->expansion : &s->direct;
  buf line = {0};
  puts_(&line, s->located_key);
  puts_(&line, "[");
  if (found) put(&line, at->data, at->len);
  else puts_(&line, "\"\", 0, 0");
  puts_(&line, "],");
  if (line.failed) s->out.failed = true;
  append(s, (slice){line.data ? line.data : "", line.len});
  free(line.data);
  s->located_key = NULL;
}

/* A line inside a location of `prune`: only the places and the objects around them matter. */
static void in_location(state *s, slice text) {
  if (starts(text, LIT("\"cc_file\": "))) {
    if (s->frame_count == 0) {
      set_place(s, &s->direct);
      s->has_direct = true;
    } else if (s->frame_count == 1 && s->frames[0] == 'E') {
      set_place(s, &s->expansion);
      s->has_expansion = true;
    }
  } else if (starts(text, LIT("\"expansionLoc\": "))) {
    s->has_expansion_key = true;
    if (opens(text) && s->frame_count < sizeof s->frames) s->frames[s->frame_count++] = 'E';
  } else if (opens(text)) {
    if (s->frame_count < sizeof s->frames) s->frames[s->frame_count++] = 'O';
  } else if (closes(text)) {
    if (s->frame_count > 0) s->frame_count--;
    else close_location(s);
  }
}

static void open_location(state *s, const char *key) {
  s->located_key = key;
  s->frame_count = 0;
  s->has_expansion_key = s->has_direct = s->has_expansion = false;
}

/* `prune` writes the locations of a node in the short form that Ast reads first: `cc_loc`, `cc_begin` and `cc_end`,
 * each `[FILE, LINE, COL]`, in place of `loc` and `range`, which hold some ten values and three objects each. Returns
 * whether the line was taken. An empty location (`{}`) is left out: Ast reads a missing one as "" and 0, as it reads
 * an empty one. */
static bool located_line(state *s, slice text) {
  if (s->located_key) {
    in_location(s, text);
    return true;
  }
  if (s->in_range) {
    if (eq(text, LIT("\"begin\": {"))) open_location(s, "\"cc_begin\": ");
    else if (eq(text, LIT("\"end\": {"))) open_location(s, "\"cc_end\": ");
    else if (closes(text)) s->in_range = false;
    return true;
  }
  if (eq(text, LIT("\"loc\": {"))) {
    open_location(s, "\"cc_loc\": ");
    return true;
  }
  if (eq(text, LIT("\"range\": {"))) {
    s->in_range = true;
    return true;
  }
  return eq(text, LIT("\"loc\": {},")) || eq(text, LIT("\"loc\": {}")) || eq(text, LIT("\"range\": {},")) ||
         eq(text, LIT("\"range\": {}"));
}

static void keep(state *s, slice line) {
  if (s->phase != OPEN && s->phase != KEPT) return;
  slice text = strip(line);
  s->decl_lines++;
  if (s->prune) {
    /* clang opens an object or a list at the end of a line and closes it at the start of its own line. */
    if (s->skip_depth > 0) {
      if (closes(text)) s->skip_depth--;
      if (opens(text)) s->skip_depth++;
      return;
    }
    if (pruned_key(text)) {
      if (opens(text)) s->skip_depth = 1;
      return;
    }
    if (located_line(s, text)) return;
  }
  append(s, text);
}

static void drop_lines(state *s) {
  s->decl.len = 0;
  s->decl_lines = 0;
  s->skip_depth = 0;
  s->in_range = false;
  s->located_key = NULL;
}

static void push_oversized(state *s) {
  put(&s->oversized, s->name.data ? s->name.data : "", s->name.len);
  put(&s->oversized, "", 1);
  s->oversized_count++;
}

static bool plain_word(slice w) {
  static const char *const words[] = {"char",  "short",  "int",      "long",     "unsigned", "signed", "float",
                                      "double", "_Bool", "bool",     "__int128", "const",    "volatile", "static"};
  for (size_t k = 0; k < sizeof words / sizeof words[0]; k++)
    if (eq(w, (slice){words[k], strlen(words[k])})) return true;
  return false;
}

/* plain_array?: the type with `"` made a space and `[` made ` [`, split at spaces; every word that is not empty and
 * does not start with `[` is a plain word. */
static bool plain_array(slice type) {
  if (!has(type, '[') || has(type, '(') || has(type, '*')) return false;
  size_t k = 0;
  while (k < type.n) {
    while (k < type.n && (type.s[k] == ' ' || type.s[k] == '"')) k++;
    if (k >= type.n) break;
    size_t start = k;
    bool bracket = type.s[k] == '[';
    k++;
    while (k < type.n && type.s[k] != ' ' && type.s[k] != '"' && type.s[k] != '[') k++;
    if (!bracket && !plain_word((slice){type.s + start, k - start})) return false;
  }
  return true;
}

static void top_key(state *s, slice line) {
  if (eq(line, LIT("      \"kind\": \"VarDecl\","))) {
    s->variable = true;
  } else if (ends(line, LIT("\"kind\": \"FunctionDecl\","))) {
    s->functions = true;
  } else if (starts(line, LIT("      \"name\": "))) {
    set(&s->name, value_of(strip(line), LIT("\"name\": ")));
  } else if (starts(line, LIT("        \"desugaredQualType\": "))) {
    set(&s->desugared, value_of(line, LIT("        \"desugaredQualType\": ")));
  } else if (starts(line, LIT("        \"qualType\": ")) && s->variable && s->phase == KEPT) {
    slice type = {s->desugared.data, s->desugared.len};
    if (type.n == 0) type = value_of(line, LIT("        \"qualType\": "));
    if (plain_array(type)) {
      s->phase = DROPPED;
      drop_lines(s);
    } else {
      s->array = has(type, '[');
    }
  }
}

static bool one_of(slice v, const char *const *set, size_t n) {
  for (size_t k = 0; k < n; k++)
    if (eq(v, (slice){set[k], strlen(set[k])})) return true;
  return false;
}

static void deeper_key(state *s, slice line, slice text) {
  static const char *const seen_through[] = {"\"ImplicitCastExpr\"", "\"ImplicitValueInitExpr\""};
  static const char *const literals[] = {"\"IntegerLiteral\"", "\"FloatingLiteral\"", "\"CharacterLiteral\""};
  if (s->phase != KEPT) return;
  if (!s->functions && ends(line, LIT("\"kind\": \"FunctionDecl\","))) {
    s->functions = true;
    s->array = false;
    return;
  }
  if (!s->array) return;
  if (eq(line, LIT("          \"kind\": \"InitListExpr\","))) {
    s->items = true;
    return;
  }
  if (!s->items) return;
  if (starts(text, LIT("\"castKind\": ")) && ends(value_of(text, LIT("\"castKind\": ")), LIT("ToPointer\""))) {
    s->array = false;
    return;
  }
  if (!starts(text, LIT("\"kind\": "))) return;
  slice kind = value_of(text, LIT("\"kind\": "));
  if (one_of(kind, seen_through, 2)) return;
  if (one_of(kind, literals, 3)) {
    s->phase = DROPPED;
    drop_lines(s);
    return;
  }
  s->array = false;
}

/* with_file: `"<built-in>"`-like names and the empty name are no file; the rest are in `places`, or not in the
 * project. */
static const char empty_encoded[] = "\"\"";

static void with_file(state *s, slice value) {
  for (size_t k = 0; k < s->count; k++) {
    size_t at = (s->last + k) % s->count;
    place *p = &s->places[at];
    if (p->raw_n == value.n && memcmp(p->raw, value.s, value.n) == 0) {
      s->last = at;
      s->encoded = p->encoded;
      s->encoded_n = p->encoded_n;
      s->inside = p->inside;
      return;
    }
  }
  /* Not given: the caller resolved every value that files() listed, so this is not reached for a dump that did not
   * change between the calls. It is treated as no file of the project. */
  s->encoded = empty_encoded;
  s->encoded_n = sizeof empty_encoded - 1;
  s->inside = false;
}

/* to_i of the VM for the digits of a line number: an optional sign and decimal digits, nothing else. */
static bool to_int(slice v, int64_t *out) {
  size_t k = 0;
  bool negative = false;
  if (k < v.n && (v.s[k] == '-' || v.s[k] == '+')) negative = v.s[k] == '-', k++;
  if (k == v.n) return false;
  int64_t n = 0;
  for (; k < v.n; k++) {
    if (v.s[k] < '0' || v.s[k] > '9') return false;
    if (n > (INT64_MAX - 9) / 10) return false;
    n = n * 10 + (v.s[k] - '0');
  }
  *out = negative ? -n : n;
  return true;
}

static void located(state *s, slice text) {
  char number[32];
  int written = snprintf(number, sizeof number, "%lld", (long long)s->line);
  buf *marked = &s->marked;
  marked->len = 0;
  puts_(marked, "\"cc_file\": ");
  put(marked, s->encoded, s->encoded_n);
  puts_(marked, ", \"cc_line\": ");
  put(marked, number, (size_t)written);
  puts_(marked, ", ");
  put(marked, text.s, text.n);
  s->col = value_of(text, LIT("\"col\": "));
  if (s->phase == OPEN && !s->spelling) s->phase = s->inside ? KEPT : DROPPED;
  if (marked->failed) s->out.failed = true;
  keep(s, (slice){marked->data ? marked->data : "", marked->len});
}

/* `text` is the line without its indent. */
static void located_or_kept(state *s, slice text) {
  if (s->included) {
    s->included = false;
  } else if (starts(text, LIT("\"includedFrom\": {"))) {
    s->included = true;
  } else if (starts(text, LIT("\"spellingLoc\": {"))) {
    s->spelling = true;
  } else if (starts(text, LIT("\"expansionLoc\": {"))) {
    s->spelling = false;
  } else if (starts(text, LIT("\"file\": "))) {
    with_file(s, value_of(text, LIT("\"file\": ")));
  } else if (starts(text, LIT("\"line\": "))) {
    int64_t n;
    if (to_int(value_of(text, LIT("\"line\": ")), &n)) s->line = n;
  } else if (starts(text, LIT("\"col\": "))) {
    located(s, text);
    return;
  }
  keep(s, text);
}

static void close_decl(state *s) {
  if (s->phase == KEPT) {
    if (s->kept > 0) puts_(&s->out, ",\n");
    append(s, LIT("    }"));
    put(&s->out, s->decl.data, s->decl.len);
    s->kept++;
  } else if (s->phase == OVERSIZED) {
    s->skipped++;
  }
  s->phase = BETWEEN;
  drop_lines(s);
}

static void step(state *s, slice line) {
  if (eq(line, LIT("    {"))) {
    /* The first line is kept as it is, with its indent. */
    s->phase = OPEN;
    drop_lines(s);
    put(&s->decl, line.s, line.n);
    s->decl_lines = 1;
    s->variable = s->array = s->items = s->functions = false;
    s->desugared.len = 0;
    s->name.len = 0;
    return;
  }
  if ((eq(line, LIT("    }")) || eq(line, LIT("    },"))) && s->phase != BETWEEN) {
    close_decl(s);
    return;
  }
  if (s->phase == BETWEEN) {
    s->ended = eq(line, LIT("}"));
    return;
  }
  if (s->phase == KEPT && s->decl_lines >= MAX_DECL_LINES) {
    if (s->functions) {
      s->phase = DROPPED;
      push_oversized(s);
    } else {
      s->phase = OVERSIZED;
    }
    drop_lines(s);
    return;
  }
  if (s->phase == OVERSIZED) {
    if (ends(line, LIT("\"kind\": \"FunctionDecl\","))) {
      s->phase = DROPPED;
      push_oversized(s);
    }
    return;
  }
  slice text = strip(line);
  if (starts(line, LIT("      \"")) || starts(line, LIT("        \""))) {
    top_key(s, line);
  } else {
    deeper_key(s, line, text);
  }
  if (s->phase == DROPPED) return;
  located_or_kept(s, text);
}

/* scan(path: String, places: List[Place], prune: Bool) -> Result[NativeDump] */
static an_term scan(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  an_list_cursor c;
  size_t count;
  state s;
  memset(&s, 0, sizeof s);
  if (!an_get_bool(env, argv[2], &s.prune)) return an_badarg(env, 2);
  if (!an_list_cursor_begin(env, argv[1], &c, &count)) return an_badarg(env, 1);
  s.encoded = empty_encoded;
  s.encoded_n = sizeof empty_encoded - 1;
  s.places = calloc(count ? count : 1, sizeof *s.places);
  if (!s.places) return an_raise(env, "out of memory");
  /* The strings of the places are borrowed from the argument, which lives until the call returns. */
  an_term item, field;
  while (an_list_next(env, &c, &item)) {
    place *p = &s.places[s.count];
    if (!an_get_field(env, item, PLACE, 0, &field) || !an_get_string(env, field, &p->raw, &p->raw_n) ||
        !an_get_field(env, item, PLACE, 1, &field) || !an_get_string(env, field, &p->encoded, &p->encoded_n) ||
        !an_get_field(env, item, PLACE, 2, &field) || !an_get_bool(env, field, &p->inside)) {
      free(s.places);
      return an_badarg(env, 1);
    }
    s.count++;
  }
  an_term result;
  lines r;
  if (!open_lines(env, argv[0], &r, &result)) {
    free(s.places);
    return result;
  }
  puts_(&s.out, "[");
  bool done = false;
  slice line;
  while (next_line(&r, &line, &done) && !done) step(&s, line);
  puts_(&s.out, "]");
  bool failed = s.out.failed || s.decl.failed || s.name.failed || s.desugared.failed || s.oversized.failed ||
                s.direct.failed || s.expansion.failed || s.marked.failed;
  if (r.error) {
    result = an_error(env, r.error, strlen(r.error));
  } else if (failed) {
    result = an_raise(env, "out of memory");
  } else {
    an_list_builder b;
    an_list_begin(env, &b, s.oversized_count);
    for (size_t at = 0; at < s.oversized.len;) {
      size_t n = strlen(s.oversized.data + at);
      an_list_push(env, &b, an_string(env, s.oversized.data + at, n));
      at += n + 1;
    }
    an_term fields[4] = {an_string(env, s.out.data, s.out.len), an_list_end(env, &b), an_int(env, s.skipped),
                         an_bool(env, s.ended)};
    result = an_ok(env, an_struct(env, NATIVE_DUMP, fields));
  }
  free(s.places);
  free(s.decl.data);
  free(s.out.data);
  free(s.name.data);
  free(s.desugared.data);
  free(s.direct.data);
  free(s.marked.data);
  free(s.expansion.data);
  free(s.oversized.data);
  close_lines(&r);
  return result;
}

static const an_type types[] = {
  {"NativeDump", AN_STRUCT, "decls: String, oversized: List[String], skipped: Int, ended: Bool"},
  {"Place", AN_STRUCT, "raw: String, encoded: String, inside: Bool"},
};

static const an_function functions[] = {
  {"files", "(String) -> Result[List[String]]", files, AN_SHORT},
  {"scan", "(String, List[Place], Bool) -> Result[NativeDump]", scan, AN_SHORT},
};

AN_MODULE_TYPES("cchecker_scan", functions, types, NULL)
