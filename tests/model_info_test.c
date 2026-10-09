#include "src/server/server_model_info.h"
#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    server_model_options_reset();
    if (argc > 1) {
        for (int i = 1; i < argc; i++)
            if (!server_model_parse_option(argv[i], &i, argc, argv)) return 3;
        puts(server_served_model_name("fallback"));
        return 0;
    }
    assert(!server_model_has_alias());
    assert(!strcmp(server_served_model_name("engine-model"), "engine-model"));
    char *args[] = {"server", "--served-model-name", "big"};
    int i = 1;
    assert(server_model_parse_option(args[i], &i, 3, args));
    assert(i == 2 && server_model_has_alias());
    assert(!strcmp(server_served_model_name("engine-model"), "big"));
    char *eq[] = {"server", "--served-model-name=org/coder-v2"};
    i = 1;
    assert(server_model_parse_option(eq[i], &i, 2, eq));
    assert(i == 1 && !strcmp(server_served_model_name(NULL), "org/coder-v2"));
    assert(!server_model_parse_option("--port", &i, 2, eq));
    server_model_set_path("/private/checkpoints/model.gguf");
    assert(!strcmp(server_model_root("fallback"), "model.gguf"));
    server_model_set_path("tests/model_info_test.c");
    assert(server_model_created() > 0);
    server_model_set_path(NULL);
    assert(!strcmp(server_model_root("fallback"), "fallback"));
    assert(server_model_created() == 0);
    assert(server_model_token_limit(4096, 0) == 4096);
    assert(server_model_token_limit(4096, INT_MAX) == 4096);
    assert(server_model_token_limit(4096, 256) == 256);
    assert(server_model_token_limit(0, 256) == 0);
    assert(server_model_path_matches("big", "big"));
    assert(server_model_path_matches("org%2Fcoder", "org/coder"));
    assert(!server_model_path_matches("org%2", "org/coder"));
    assert(!server_model_path_matches("big%00", "big"));
    assert(!server_model_path_matches("other", "big"));
    server_model_options_reset();
    assert(!server_model_has_alias());
    puts("PASS: model identity, CLI parsing, timestamp and token limits");
    return 0;
}
