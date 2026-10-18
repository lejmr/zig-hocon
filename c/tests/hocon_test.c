/* libhocon from C, the way a C program uses it: app.conf with its include, a
 * variable from a map, every getter, JSON, a missing key, and broken.conf's
 * error with its place. build.zig runs it on those two and checks stdout. */
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#include "hocon.h"

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

static const char *code_name(int code) {
    switch (code) {
    case HOCON_OK: return "HOCON_OK";
    case HOCON_ERR_MISSING: return "HOCON_ERR_MISSING";
    case HOCON_ERR_WRONG_TYPE: return "HOCON_ERR_WRONG_TYPE";
    default: return "another error";
    }
}

int main(int argc, char **argv) {
    if (argc != 3) return 2;
#ifdef _WIN32
    /* "\n" stays "\n": the build compares the output byte for byte. */
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    const char *vars[] = {"BADGER_PORT=9090", NULL};
    hocon_options opts = {HOCON_ENV_MAP, vars, true, NULL};
    hocon_error err = {0};

    hocon_doc *doc = hocon_parse_file(argv[1], &opts, &err);
    if (!doc) {
        printf("%s\n", err.name);
        return 1;
    }

    int64_t port, ns;
    uint64_t bytes;
    int32_t years, months, days;
    const char *motto;
    size_t motto_len;
    if (hocon_get_int(doc, "port", &port) != HOCON_OK) return 1;
    if (hocon_get_string(doc, "motto", &motto, &motto_len) != HOCON_OK) return 1;
    if (hocon_get_duration_ns(doc, "timeout", &ns) != HOCON_OK) return 1;
    if (hocon_get_bytes(doc, "cache", &bytes) != HOCON_OK) return 1;
    if (hocon_get_period(doc, "retention", &years, &months, &days) != HOCON_OK) return 1;
    printf("port = %" PRId64 "\n", port);
    printf("motto = %.*s\n", (int)motto_len, motto);
    printf("timeout = %" PRId64 " ns\n", ns);
    printf("cache = %" PRIu64 " bytes\n", bytes);
    printf("retention = %dy %dmo %dd\n", (int)years, (int)months, (int)days);

    char *json = hocon_to_json(doc, "", NULL);
    printf("json = %s\n", json);
    hocon_free_string(json);

    int64_t pool;
    printf("pool = %s\n", code_name(hocon_get_int(doc, "db.pool", &pool)));
    hocon_free(doc);

    if (hocon_parse_file(argv[2], &opts, &err)) return 1;
    printf("%s:%zu:%zu: %s\n%s\n", err.file, err.line, err.column, err.name, err.source_line);
    hocon_error_free(&err);
    return 0;
}
