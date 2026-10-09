#ifndef DS4_SERVER_MODEL_INFO_H
#define DS4_SERVER_MODEL_INFO_H

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

/* Configure before starting HTTP workers; readers never mutate these values. */
void server_model_options_reset(void);
bool server_model_parse_option(const char *arg, int *index, int argc, char **argv);
void server_model_usage(FILE *fp);
void server_model_set_path(const char *path);
const char *server_served_model_name(const char *fallback);
bool server_model_has_alias(void);
bool server_model_path_matches(const char *path_id, const char *model_id);
const char *server_model_root(const char *fallback);
int64_t server_model_created(void);
int server_model_token_limit(int context_length, int configured_limit);

#endif
