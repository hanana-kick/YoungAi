/* Model-free harness for the production serializer extracted by local-serving.sh.
 * Only the surrounding engine, HTTP transport and buffer are test doubles. */
#include "src/server/server_model_info.h"
#include <assert.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

typedef struct { char *ptr; size_t len; } buf;
typedef struct { void *engine; int default_tokens, max_output_tokens; bool enable_cors; } server;
static char *response;
static void buf_puts(buf *b, const char *s) {
    size_t n = strlen(s);
    char *p = realloc(b->ptr, b->len + n + 1);
    assert(p); b->ptr = p;
    memcpy(p + b->len, s, n + 1); b->len += n;
}
static void buf_putc(buf *b, char c) { char s[] = {c, 0}; buf_puts(b, s); }
static void buf_printf(buf *b, const char *fmt, ...) {
    va_list ap, copy; va_start(ap, fmt); va_copy(copy, ap);
    int n = vsnprintf(NULL, 0, fmt, copy); va_end(copy); assert(n >= 0);
    char *s = malloc((size_t)n + 1); assert(s);
    vsnprintf(s, (size_t)n + 1, fmt, ap); va_end(ap);
    buf_puts(b, s); free(s);
}
static void json_escape(buf *b, const char *s) {
    buf_putc(b, '"');
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') { buf_putc(b, '\\'); buf_putc(b, (char)c); }
        else if (c < 32) buf_printf(b, "\\u%04x", c);
        else buf_putc(b, (char)c);
    }
    buf_putc(b, '"');
}
static void buf_free(buf *b) { free(b->ptr); memset(b, 0, sizeof(*b)); }
static const char *server_model_id_from_engine(void *e) { (void)e; return "engine-id"; }
static const char *ds4_engine_model_name(void *e) { (void)e; return "GGUF \"model\""; }
static int server_ctx_size(const server *s) { (void)s; return 4096; }
static bool http_response(int fd, bool cors, int status, const char *type, const char *text) {
    (void)fd; (void)cors; assert(status == 200); assert(!strcmp(type, "application/json"));
    free(response); response = malloc(strlen(text) + 1); assert(response); strcpy(response, text);
    return true;
}
#include "model_json.inc"

int main(void) {
    char *argv[] = {"server", "--served-model-name", "big"}; int i = 1;
    server_model_parse_option(argv[1], &i, 3, argv);
    server_model_set_path("tests/model_info_test.c");
    server s = {.default_tokens = 128, .max_output_tokens = 0};
    assert(send_models(&s, 0)); fputs(response, stdout);
    assert(send_model(&s, 0, public_model_id(&s))); fputs(response, stdout);
    s.max_output_tokens = 512;
    assert(send_models(&s, 0)); fputs(response, stdout);
    s.default_tokens = INT_MAX;
    assert(send_models(&s, 0)); fputs(response, stdout);
    free(response);
    return 0;
}
