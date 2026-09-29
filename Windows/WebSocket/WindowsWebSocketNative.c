#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>
#include "WindowsWebSocketNative.h"

struct KokoroWebSocket {
    CRITICAL_SECTION lock;
    HINTERNET session, connection, request, socket;
    HINTERNET requestIdentity, socketIdentity;
    HANDLE requestDone, readDone, writeDone, requestClosed, socketClosed;
    DWORD requestError, readError, writeError, readCount;
    WINHTTP_WEB_SOCKET_BUFFER_TYPE readType;
    BOOL cancelled;
};

static void CALLBACK statusCallback(HINTERNET handle, DWORD_PTR context, DWORD status,
                                     void *information, DWORD length) {
    KokoroWebSocket *s = (KokoroWebSocket *)context;
    if (!s) return;
    // These events also keep cancellation from returning a caller's I/O buffer
    // before WinHTTP is finished using it. HANDLE_CLOSING is the final callback.
    if (status == WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING) {
        SetEvent(handle == s->requestIdentity ? s->requestClosed : s->socketClosed);
    } else if (status == WINHTTP_CALLBACK_STATUS_REQUEST_ERROR) {
        WINHTTP_ASYNC_RESULT *result = information;
        if (handle == s->requestIdentity) {
            s->requestError = result->dwError; SetEvent(s->requestDone);
        } else if (length >= sizeof(WINHTTP_WEB_SOCKET_ASYNC_RESULT)) {
            WINHTTP_WEB_SOCKET_ASYNC_RESULT *socketResult = information;
            if (socketResult->Operation == WINHTTP_WEB_SOCKET_RECEIVE_OPERATION) {
                s->readError = result->dwError; SetEvent(s->readDone);
            } else if (socketResult->Operation == WINHTTP_WEB_SOCKET_SEND_OPERATION) {
                s->writeError = result->dwError; SetEvent(s->writeDone);
            }
        }
    } else if (status == WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE || status == WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE) {
        SetEvent(s->requestDone);
    } else if (status == WINHTTP_CALLBACK_STATUS_READ_COMPLETE && length >= sizeof(WINHTTP_WEB_SOCKET_STATUS)) {
        WINHTTP_WEB_SOCKET_STATUS *result = information;
        s->readCount = result->dwBytesTransferred; s->readType = result->eBufferType;
        SetEvent(s->readDone);
    } else if (status == WINHTTP_CALLBACK_STATUS_WRITE_COMPLETE) {
        SetEvent(s->writeDone);
    }
}

KokoroWebSocket *KokoroWebSocketCreate(void) {
    KokoroWebSocket *s = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*s));
    if (!s) return NULL;
    InitializeCriticalSection(&s->lock);
    s->requestDone = CreateEventW(NULL, FALSE, FALSE, NULL);
    s->readDone = CreateEventW(NULL, FALSE, FALSE, NULL);
    s->writeDone = CreateEventW(NULL, FALSE, FALSE, NULL);
    s->requestClosed = CreateEventW(NULL, TRUE, FALSE, NULL);
    s->socketClosed = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!s->requestDone || !s->readDone || !s->writeDone || !s->requestClosed || !s->socketClosed) {
        KokoroWebSocketDestroy(s); return NULL;
    }
    return s;
}

static DWORD waitForOperation(HANDLE done, HANDLE closed) {
    HANDLE events[] = {done, closed};
    DWORD result = WaitForMultipleObjects(2, events, FALSE, INFINITE);
    return result == WAIT_OBJECT_0 ? ERROR_SUCCESS : ERROR_OPERATION_ABORTED;
}

uint32_t KokoroWebSocketConnect(KokoroWebSocket *s, const uint16_t *host, uint16_t port,
    const uint16_t *path, const uint16_t *headers, int32_t secure) {
    DWORD error = ERROR_SUCCESS;
    EnterCriticalSection(&s->lock);
    if (s->cancelled) { error = ERROR_OPERATION_ABORTED; goto unlock; }
    s->session = WinHttpOpen(L"KokoroDesktop", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
        WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, WINHTTP_FLAG_ASYNC);
    if (!s->session) { error = GetLastError(); goto unlock; }
    WinHttpSetTimeouts(s->session, 10000, 10000, 30000, 30000);
    s->connection = WinHttpConnect(s->session, (PCWSTR)host, port, 0);
    if (!s->connection) { error = GetLastError(); goto unlock; }
    s->request = WinHttpOpenRequest(s->connection, L"GET", (PCWSTR)path, NULL,
        WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, secure ? WINHTTP_FLAG_SECURE : 0);
    if (!s->request) { error = GetLastError(); goto unlock; }
    // Match the existing URLSession policy: no token-bearing redirects, cookies
    // or automatic Windows credentials. TLS verification stays enabled.
    DWORD disabled = WINHTTP_DISABLE_REDIRECTS | WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_AUTHENTICATION;
    if (!WinHttpSetOption(s->request, WINHTTP_OPTION_DISABLE_FEATURE, &disabled, sizeof(disabled)) ||
        !WinHttpSetOption(s->request, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, NULL, 0)) {
        error = GetLastError(); goto unlock;
    }
    DWORD_PTR context = (DWORD_PTR)s;
    if (!WinHttpSetOption(s->request, WINHTTP_OPTION_CONTEXT_VALUE, &context, sizeof(context)) ||
        WinHttpSetStatusCallback(s->request, statusCallback,
            WINHTTP_CALLBACK_FLAG_ALL_COMPLETIONS | WINHTTP_CALLBACK_FLAG_HANDLES, 0) == WINHTTP_INVALID_STATUS_CALLBACK) {
        error = GetLastError(); goto unlock;
    }
    s->requestIdentity = s->request;
    if (!WinHttpSendRequest(s->request, (PCWSTR)headers, (DWORD)-1L,
        WINHTTP_NO_REQUEST_DATA, 0, 0, context)) error = GetLastError();
unlock:
    LeaveCriticalSection(&s->lock);
    if (error) return error;
    error = waitForOperation(s->requestDone, s->requestClosed);
    if (error || s->requestError) return error ? error : s->requestError;

    EnterCriticalSection(&s->lock);
    if (s->cancelled) error = ERROR_OPERATION_ABORTED;
    else if (!WinHttpReceiveResponse(s->request, NULL)) error = GetLastError();
    LeaveCriticalSection(&s->lock);
    if (error) return error;
    error = waitForOperation(s->requestDone, s->requestClosed);
    if (error || s->requestError) return error ? error : s->requestError;

    EnterCriticalSection(&s->lock);
    if (s->cancelled) { error = ERROR_OPERATION_ABORTED; goto upgraded; }
    DWORD status = 0, size = sizeof(status);
    if (!WinHttpQueryHeaders(s->request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
        NULL, &status, &size, NULL)) { error = GetLastError(); goto upgraded; }
    if (status != 101) { error = ERROR_WINHTTP_INVALID_SERVER_RESPONSE; goto upgraded; }
    s->socket = WinHttpWebSocketCompleteUpgrade(s->request, (DWORD_PTR)s);
    if (!s->socket) { error = GetLastError(); goto upgraded; }
    s->socketIdentity = s->socket;
    // The socket inherits the request's callback. Both handles have independent
    // closing notifications, so their callback context outlives cancellation.
    WinHttpCloseHandle(s->request); s->request = NULL;
upgraded:
    LeaveCriticalSection(&s->lock);
    return error;
}

uint32_t KokoroWebSocketRead(KokoroWebSocket *s, uint8_t *bytes, uint32_t capacity,
    uint32_t *count, int32_t *complete) {
    EnterCriticalSection(&s->lock);
    s->readError = 0;
    DWORD error = s->cancelled || !s->socket ? ERROR_OPERATION_ABORTED :
        WinHttpWebSocketReceive(s->socket, bytes, capacity, NULL, NULL);
    LeaveCriticalSection(&s->lock);
    if (error) return error;
    error = waitForOperation(s->readDone, s->socketClosed);
    if (error || s->readError) return error ? error : s->readError;
    if (s->readType == WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE) return ERROR_CONNECTION_ABORTED;
    *count = s->readCount;
    *complete = s->readType == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE ||
                s->readType == WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE;
    return ERROR_SUCCESS;
}

uint32_t KokoroWebSocketWrite(KokoroWebSocket *s, const uint8_t *bytes, uint32_t count) {
    EnterCriticalSection(&s->lock);
    s->writeError = 0;
    DWORD error = s->cancelled || !s->socket ? ERROR_OPERATION_ABORTED :
        WinHttpWebSocketSend(s->socket, WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE, (void *)bytes, count);
    LeaveCriticalSection(&s->lock);
    if (error) return error;
    error = waitForOperation(s->writeDone, s->socketClosed);
    return error ? error : s->writeError;
}

void KokoroWebSocketCancel(KokoroWebSocket *s) {
    EnterCriticalSection(&s->lock);
    s->cancelled = TRUE;
    if (s->request) { WinHttpCloseHandle(s->request); s->request = NULL; }
    if (s->socket) { WinHttpCloseHandle(s->socket); s->socket = NULL; }
    LeaveCriticalSection(&s->lock);
}

void KokoroWebSocketDestroy(KokoroWebSocket *s) {
    if (!s) return;
    KokoroWebSocketCancel(s);
    if (s->requestIdentity) WaitForSingleObject(s->requestClosed, INFINITE);
    if (s->socketIdentity) WaitForSingleObject(s->socketClosed, INFINITE);
    if (s->connection) WinHttpCloseHandle(s->connection);
    if (s->session) WinHttpCloseHandle(s->session);
    if (s->requestDone) CloseHandle(s->requestDone);
    if (s->readDone) CloseHandle(s->readDone);
    if (s->writeDone) CloseHandle(s->writeDone);
    if (s->requestClosed) CloseHandle(s->requestClosed);
    if (s->socketClosed) CloseHandle(s->socketClosed);
    DeleteCriticalSection(&s->lock);
    HeapFree(GetProcessHeap(), 0, s);
}
