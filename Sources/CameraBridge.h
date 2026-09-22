#ifndef LR1_CAMERA_BRIDGE_H
#define LR1_CAMERA_BRIDGE_H

#if defined(_WIN32)
#define LR1_BRIDGE_API __declspec(dllexport)
#else
#define LR1_BRIDGE_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* All calls are serialized by the caller. Returned memory belongs to the caller
 * and must be released with lr1_free. JSON values use UTF-8; numeric camera
 * property values are decimal strings to preserve 64-bit SDK values. */
LR1_BRIDGE_API char *lr1_request(const char *json);
LR1_BRIDGE_API unsigned char *lr1_copy_live_view(int *length);
LR1_BRIDGE_API void lr1_free(void *memory);

#ifdef __cplusplus
}
#endif
#endif
