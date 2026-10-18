/*
 * libhocon: zig-hocon behind a C ABI.
 *
 * A document is parsed once into an opaque `hocon_doc`, read through getters
 * or as JSON / HOCON text, and freed with `hocon_free`. Everything the library
 * hands out is freed by the library: strings with `hocon_free_string`, a
 * filled-in error with `hocon_error_free`.
 *
 * A file or a string is read up to 64 MiB. An include names a file, found
 * next to the file that includes it, or an http(s) URL, which is fetched in
 * `http_timeout_ms` or fails the parse with "IncludeTimeout".
 *
 * A path is text, as in a config file: `db.host`, `a."b.c"`; "" is the root.
 * The conversions are the ones `hocon.parseFromValue` makes in Zig: `"5"` is
 * an int, `yes` a bool, `1.5` is not an int, `null` is missing.
 *
 * A doc is used by one thread at a time; different docs need no locking.
 * Parsing, resolving and writing recurse once per level of nesting, up to
 * 500 levels: give the thread that calls in 4 MiB of stack (what a Debug
 * build needs at that depth), or a deep document can overflow it.
 *
 * An http(s) include is fetched on two threads of the library's own, which
 * the parse joins before it returns. A parse sets SIGIO and SIGPIPE to a
 * handler that does nothing, and leaves them so: SIGIO wakes the fetch when
 * its time is up, and a write to a closed connection fails instead of
 * ending the process.
 */
#ifndef HOCON_H
#define HOCON_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct hocon_doc hocon_doc;

/* What a call returns: 0, or why it failed. */
enum {
    HOCON_OK = 0,
    /* The text is not valid HOCON, or an include failed. */
    HOCON_ERR_PARSE = 1,
    /* A substitution with no value, a cycle; or, in a document read without
     * resolving (or with HOCON_ENV_KEEP), a value that still waits for one. */
    HOCON_ERR_SUBSTITUTION = 2,
    /* Nothing at the path, or `null` there. */
    HOCON_ERR_MISSING = 3,
    /* The value is there and is not of the type asked for, or the path goes
     * through a value that is not an object: `a.b` where `a = 5`. */
    HOCON_ERR_WRONG_TYPE = 4,
    /* The file cannot be read. */
    HOCON_ERR_IO = 5,
    /* The path is not a valid path: `a..b`. */
    HOCON_ERR_BAD_PATH = 6,
    /* `hocon_to_json` only: more than 256 lists and objects deep, which JSON
     * is not written for. */
    HOCON_ERR_TOO_DEEP = 7,
    /* Out of memory, a NULL argument, options that make no sense. */
    HOCON_ERR_OTHER = 8,
};

/* Where `${NAME}` looks when NAME is not in the document. */
enum {
    /* The variables of this process, as they are when the parse starts. */
    HOCON_ENV_PROCESS = 0,
    /* Nowhere: `${NAME}` is an error, `${?NAME}` is left out. */
    HOCON_ENV_NONE = 1,
    /* `env_vars`, a NULL-terminated array of "KEY=VALUE" like `environ`.
     * An entry that is not KEY=VALUE is skipped; NULL is no variables. */
    HOCON_ENV_MAP = 2,
    /* Later: the substitution stays in the document, everything else is
     * resolved; `hocon_to_hocon` writes it out to be read where it runs. */
    HOCON_ENV_KEEP = 3,
};

typedef struct hocon_options {
    /* sizeof(hocon_options). The library reads the fields that fit in it and
     * takes the default for the rest, so a program built against an older
     * header keeps working with a newer library. Less than a size_t is
     * HOCON_ERR_OTHER. */
    size_t size;
    int env; /* HOCON_ENV_* */
    const char *const *env_vars;
    /* false reads the document without resolving it: every `${…}` stays as
     * written, `hocon_to_hocon` prints it, getters reach what has none. */
    bool resolve;
    /* For `hocon_parse_string`: where an include in the string is found.
     * NULL makes an include an error. A file's includes are always found
     * next to the file, so `hocon_parse_file` does not read it. */
    const char *include_dir;
    /* How long one fetch of an http(s) include may take, from connecting to
     * the last byte, in milliseconds; 0 is 30 s. */
    uint32_t http_timeout_ms;
} hocon_options;

/* Why a parse, or a call on a doc (`hocon_last_error`), failed. The strings
 * but `name` are the library's; free a parse's with `hocon_error_free`. */
typedef struct hocon_error {
    int code;          /* HOCON_OK while nothing failed */
    const char *name;  /* "Unresolved", "UnexpectedToken"…; static */
    char *file;        /* as it was named; "" for the string itself; NULL with no place */
    size_t line;       /* 1-based; 0 with no place */
    size_t column;     /* 1-based, in code points */
    char *source_line; /* the line, as written; NULL with no place */
    char *key_path;    /* a call on a doc: the path it was given; else NULL */
    char *expected;    /* a getter: what it wanted, "i64", "duration"; else NULL */
} hocon_error;

/* NULL `opts` is HOCON_ENV_PROCESS, resolved. On failure NULL, and `err`
 * (when not NULL) says why; on success its code is HOCON_OK. `err` needs no
 * zeroing before. */
hocon_doc *hocon_parse_file(const char *path, const hocon_options *opts, hocon_error *err);
hocon_doc *hocon_parse_string(const char *src, size_t len, const hocon_options *opts, hocon_error *err);

int hocon_get_int(hocon_doc *h, const char *path, int64_t *out);
int hocon_get_float(hocon_doc *h, const char *path, double *out);
int hocon_get_bool(hocon_doc *h, const char *path, bool *out);
/* The text, valid until `hocon_free`; not NUL-terminated. */
int hocon_get_string(hocon_doc *h, const char *path, const char **out, size_t *len);
/* `30s`, `2 minutes`; a number alone is milliseconds. Saturates at INT64_MAX. */
int hocon_get_duration_ns(hocon_doc *h, const char *path, int64_t *out);
/* `512MB`, `1.5 GiB`; a number alone is bytes. */
int hocon_get_bytes(hocon_doc *h, const char *path, uint64_t *out);
/* `3mo`, `2w`; a number alone is days, weeks are days. */
int hocon_get_period(hocon_doc *h, const char *path, int32_t *years, int32_t *months, int32_t *days);
/* HOCON_OK when there is an object at `path`. */
int hocon_get_config(hocon_doc *h, const char *path);

/* Why the last call on `h` that failed failed, as a parse error says it: a
 * value that does not convert is pointed at where it is written,
 * `app.conf:3:8: InvalidCharacter at db.pool: expected i64`. Code HOCON_OK
 * while no call has failed; a call that succeeds leaves it as it was. NULL
 * for a NULL doc. The doc's own: valid until the next call on `h`
 * fails, or `hocon_free`; not for `hocon_error_free`. */
const hocon_error *hocon_last_error(hocon_doc *h);

/* The value at `path` as compact JSON / as HOCON, or NULL and `*code` (when
 * not NULL) says why. Free it with `hocon_free_string`. A `${…}` is written
 * as HOCON only at the root: below it, it is HOCON_ERR_SUBSTITUTION. */
char *hocon_to_json(hocon_doc *h, const char *path, int *code);
char *hocon_to_hocon(hocon_doc *h, const char *path, int *code);

void hocon_free_string(char *s);
void hocon_error_free(hocon_error *err);
void hocon_free(hocon_doc *h);

#ifdef __cplusplus
}
#endif

#endif
