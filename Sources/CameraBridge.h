#ifndef LR1_CAMERA_BRIDGE_H
#define LR1_CAMERA_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/* All calls are serialized by the caller. Returned memory belongs to the caller
 * and must be released with lr1_free. JSON values use UTF-8; numeric camera
 * property values are decimal strings to preserve 64-bit SDK values. */
char *lr1_request(const char *json);
unsigned char *lr1_copy_live_view(int *length);
void lr1_free(void *memory);

#ifdef __cplusplus
}
#endif
#endif
