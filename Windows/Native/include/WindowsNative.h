#pragma once
#include <stdint.h>
#include <stddef.h>
int32_t KokoroInitializeRuntime(void);
void KokoroShutdownRuntime(void);
// UTF-8 JSON stays in the current user's Windows Credential Manager.
uint32_t KokoroSaveCredential(const uint8_t *bytes, uint32_t count);
uint32_t KokoroLoadCredential(uint8_t *bytes, uint32_t capacity, uint32_t *count);
uint32_t KokoroDeleteCredential(void);
// ImgBB uses a separate Credential Manager target from kokoro.io credentials.
uint32_t KokoroSaveImgBBKey(const uint8_t *bytes, uint32_t count);
uint32_t KokoroLoadImgBBKey(uint8_t *bytes, uint32_t capacity, uint32_t *count);
uint32_t KokoroDeleteImgBBKey(void);
// UTF-16 double-NUL-terminated OPENFILENAME result. ERROR_CANCELLED is harmless.
uint32_t KokoroPickImages(uint16_t *paths, uint32_t capacity, uint32_t *count);
int32_t KokoroIsShiftPressed(void);
int32_t KokoroIsControlPressed(void);
int32_t KokoroIsIMEComposing(void);
// Minimum client size in device-independent points, for this thread's active window.
uint32_t KokoroSetMinimumWindowSize(int32_t width, int32_t height);
// Queries WM_GETMINMAXINFO and removes the current DPI-scaled nonclient frame.
uint32_t KokoroGetMinimumClientSize(int32_t *width, int32_t *height);
// Opens the Windows emoji panel only while this process owns foreground focus.
uint32_t KokoroShowEmojiPanel(void);
int32_t KokoroPumpMessages(void);
void KokoroWaitForMessages(void);
