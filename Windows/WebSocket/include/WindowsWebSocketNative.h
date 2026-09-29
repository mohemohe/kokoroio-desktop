#pragma once
#include <stdint.h>
typedef struct KokoroWebSocket KokoroWebSocket;
KokoroWebSocket *KokoroWebSocketCreate(void);
// Blocking wrappers over asynchronous WinHTTP. Call on worker queues, never UI.
// One reader and one writer may run concurrently. Cancel is safe from any thread.
uint32_t KokoroWebSocketConnect(KokoroWebSocket *, const uint16_t *host, uint16_t port,
    const uint16_t *path, const uint16_t *headers, int32_t secure);
uint32_t KokoroWebSocketRead(KokoroWebSocket *, uint8_t *bytes, uint32_t capacity,
    uint32_t *count, int32_t *complete);
uint32_t KokoroWebSocketWrite(KokoroWebSocket *, const uint8_t *bytes, uint32_t count);
void KokoroWebSocketCancel(KokoroWebSocket *);
// Only after all Connect/Read/Write calls have returned.
void KokoroWebSocketDestroy(KokoroWebSocket *);
