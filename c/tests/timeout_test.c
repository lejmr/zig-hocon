/* An include from a server that takes the connection and never answers ends
 * the parse with IncludeTimeout after `http_timeout_ms`, not after the 30 s
 * default or never. The server is a socket that listens and never accepts:
 * the system takes the connection, and nobody reads the request. build.zig
 * runs it and checks stdout. */
#define _POSIX_C_SOURCE 200112L
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "hocon.h"

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#include <winsock2.h>
typedef int socklen_t;
static double now(void) { return GetTickCount64() / 1e3; }
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
typedef int SOCKET;
static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}
#endif

int main(void) {
#ifdef _WIN32
    /* "\n" stays "\n": the build compares the output byte for byte. */
    _setmode(_fileno(stdout), _O_BINARY);
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return 1;
#endif
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    socklen_t len = sizeof addr;
    SOCKET server = socket(AF_INET, SOCK_STREAM, 0);
    if (bind(server, (struct sockaddr *)&addr, len) != 0 || listen(server, 1) != 0) return 1;
    if (getsockname(server, (struct sockaddr *)&addr, &len) != 0) return 1;

    char src[64];
    snprintf(src, sizeof src, "include url(\"http://127.0.0.1:%d/hang\")", ntohs(addr.sin_port));
    hocon_options opts = {.size = sizeof(hocon_options), .env = HOCON_ENV_NONE, .resolve = true, .include_dir = ".", .http_timeout_ms = 200};
    hocon_error err = {0};
    double start = now();
    if (hocon_parse_string(src, strlen(src), &opts, &err)) return 1;
    double took = now() - start;
    /* Up to 5 s for a slow machine: far from the 30 s of the default. */
    printf("%s %s\n", err.name, took > 0.1 && took < 5 ? "in time" : "not in time");
    hocon_error_free(&err);
    return 0;
}
