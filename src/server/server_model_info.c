/* Public model identity is independent of the GGUF filename and tensor layout. */
#include "server_model_info.h"

#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

/* Leave room for /v1/models/ in the HTTP parser's 256-byte path buffer. */
#define SERVED_NAME_MAX 200
static char served_name[SERVED_NAME_MAX + 1];
static const char *model_path = "ds4flash.gguf";

void server_model_options_reset(void) {
    served_name[0] = '\0';
    model_path = "ds4flash.gguf";
}

static bool valid_model_name(const char *name) {
    if (!name || !*name || strlen(name) > SERVED_NAME_MAX) return false;
    for (const unsigned char *p = (const unsigned char *)name; *p; p++) {
        if (!((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') ||
              (*p >= '0' && *p <= '9') || *p == '-' || *p == '_' ||
              *p == '.' || *p == '/' || *p == ':')) return false;
    }
    return true;
}

bool server_model_parse_option(const char *arg, int *index, int argc, char **argv) {
    const char *name;
    if (!strcmp(arg, "--served-model-name")) {
        if (*index + 1 >= argc) {
            fprintf(stderr, "ds4-server: missing value for --served-model-name\n");
            exit(2);
        }
        name = argv[++(*index)];
    } else if (!strncmp(arg, "--served-model-name=", 20)) {
        name = arg + 20;
    } else {
        return false;
    }
    if (!valid_model_name(name)) {
        fprintf(stderr, "ds4-server: --served-model-name requires 1..%d characters "
                        "from A-Z, a-z, 0-9, ., _, -, /, :\n", SERVED_NAME_MAX);
        exit(2);
    }
    memcpy(served_name, name, strlen(name) + 1);
    return true;
}

void server_model_usage(FILE *fp) {
    fprintf(fp, "\nModel identity:\n"
                "  --served-model-name NAME\n"
                "      Public ID in /v1/models and inference responses.\n"
                "      Default: the loaded engine's model ID; run.sh defaults to big.\n");
}

void server_model_set_path(const char *path) {
    /* argv storage outlives all worker threads. Resolve after --chdir is applied. */
    model_path = path;
}

const char *server_served_model_name(const char *fallback) {
    return served_name[0] ? served_name : fallback;
}

bool server_model_has_alias(void) {
    return served_name[0] != '\0';
}

const char *server_model_root(const char *fallback) {
    if (!model_path || !*model_path) return fallback;
    const char *base = strrchr(model_path, '/');
    base = base ? base + 1 : model_path;
    return *base ? base : fallback;
}

int64_t server_model_created(void) {
    struct stat st;
    /* A local checkpoint has no trustworthy training/publication timestamp.
     * Report its file mtime, not an invented release date; 0 means unavailable. */
    return model_path && stat(model_path, &st) == 0 && st.st_mtime > 0 ?
           (int64_t)st.st_mtime : 0;
}

int server_model_token_limit(int context_length, int configured_limit) {
    if (context_length <= 0) return 0;
    return configured_limit > 0 && configured_limit < context_length ?
           configured_limit : context_length;
}

static int hex_digit(unsigned char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

bool server_model_path_matches(const char *path_id, const char *model_id) {
    /* SDKs may percent-encode namespace slashes in the model path parameter. */
    if (!path_id || !model_id) return false;
    while (*path_id) {
        unsigned char c = (unsigned char)*path_id++;
        if (c == '%') {
            if (!path_id[0] || !path_id[1]) return false;
            int hi = hex_digit((unsigned char)path_id[0]);
            int lo = hex_digit((unsigned char)path_id[1]);
            if (hi < 0 || lo < 0) return false;
            c = (unsigned char)((hi << 4) | lo);
            path_id += 2;
            if (!c) return false;
        }
        if (!*model_id || c != (unsigned char)*model_id++) return false;
    }
    return !*model_id;
}
