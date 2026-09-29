#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincred.h>
#include <commdlg.h>
#include <commctrl.h>
#include <imm.h>
#include <roapi.h>
#include <appmodel.h>
#include "WindowsNative.h"

static HMODULE bootstrap;
static BOOL runtimeInitialized;
static const WCHAR credentialTarget[] = L"KokoroDesktop/connection/v1";
static const WCHAR imageCredentialTarget[] = L"KokoroDesktop/imgbb/v1";
typedef HRESULT (WINAPI *InitializeFn)(UINT32, PCWSTR, PACKAGE_VERSION);
typedef void (WINAPI *ShutdownFn)(void);

typedef struct KokoroMinimumWindowSize {
    int32_t width;
    int32_t height;
} KokoroMinimumWindowSize;

static const UINT_PTR minimumSizeSubclassID = 0x4B6F6B6F;

static HWND ownedActiveWindow(void) {
    HWND window = GetActiveWindow();
    DWORD process = 0;
    DWORD thread = window ? GetWindowThreadProcessId(window, &process) : 0;
    // SetWindowSubclass must run on the owning window's thread.
    return process == GetCurrentProcessId() && thread == GetCurrentThreadId() ? window : NULL;
}

static BOOL minimumWindowRectangle(HWND window, int32_t width, int32_t height, RECT *rectangle) {
    UINT dpi = GetDpiForWindow(window);
    if (!dpi) dpi = USER_DEFAULT_SCREEN_DPI;
    *rectangle = (RECT){0, 0, MulDiv(width, (int)dpi, USER_DEFAULT_SCREEN_DPI),
                             MulDiv(height, (int)dpi, USER_DEFAULT_SCREEN_DPI)};
    return AdjustWindowRectExForDpi(rectangle, (DWORD)GetWindowLongPtrW(window, GWL_STYLE),
        GetMenu(window) != NULL, (DWORD)GetWindowLongPtrW(window, GWL_EXSTYLE), dpi);
}

static LRESULT CALLBACK minimumSizeSubclass(HWND window, UINT message, WPARAM wParam,
                                            LPARAM lParam, UINT_PTR subclassID, DWORD_PTR reference) {
    KokoroMinimumWindowSize *minimum = (KokoroMinimumWindowSize *)reference;
    if (message == WM_NCDESTROY) {
        RemoveWindowSubclass(window, minimumSizeSubclass, subclassID);
        HeapFree(GetProcessHeap(), 0, minimum);
        return DefSubclassProc(window, message, wParam, lParam);
    }
    LRESULT result = DefSubclassProc(window, message, wParam, lParam);
    if (message == WM_GETMINMAXINFO && minimum && lParam) {
        RECT rectangle;
        if (minimumWindowRectangle(window, minimum->width, minimum->height, &rectangle)) {
            MINMAXINFO *limits = (MINMAXINFO *)lParam;
            LONG width = rectangle.right - rectangle.left;
            LONG height = rectangle.bottom - rectangle.top;
            if (limits->ptMinTrackSize.x < width) limits->ptMinTrackSize.x = width;
            if (limits->ptMinTrackSize.y < height) limits->ptMinTrackSize.y = height;
        }
        return 0;
    }
    return result;
}

uint32_t KokoroSetMinimumWindowSize(int32_t width, int32_t height) {
    if (width <= 0 || height <= 0 || width > 32767 || height > 32767) return ERROR_INVALID_PARAMETER;
    HWND window = ownedActiveWindow();
    if (!window) return ERROR_INVALID_WINDOW_HANDLE;
    RECT rectangle;
    if (!minimumWindowRectangle(window, width, height, &rectangle)) {
        DWORD error = GetLastError();
        return error ? error : ERROR_GEN_FAILURE;
    }
    DWORD_PTR reference = 0;
    if (GetWindowSubclass(window, minimumSizeSubclass, minimumSizeSubclassID, &reference)) {
        KokoroMinimumWindowSize *minimum = (KokoroMinimumWindowSize *)reference;
        minimum->width = width;
        minimum->height = height;
        return ERROR_SUCCESS;
    }
    KokoroMinimumWindowSize *minimum = HeapAlloc(GetProcessHeap(), 0, sizeof(*minimum));
    if (!minimum) return ERROR_NOT_ENOUGH_MEMORY;
    minimum->width = width;
    minimum->height = height;
    SetLastError(ERROR_SUCCESS);
    if (!SetWindowSubclass(window, minimumSizeSubclass, minimumSizeSubclassID, (DWORD_PTR)minimum)) {
        DWORD error = GetLastError();
        HeapFree(GetProcessHeap(), 0, minimum);
        return error ? error : ERROR_GEN_FAILURE;
    }
    return ERROR_SUCCESS;
}

uint32_t KokoroGetMinimumClientSize(int32_t *width, int32_t *height) {
    if (!width || !height) return ERROR_INVALID_PARAMETER;
    HWND window = ownedActiveWindow();
    if (!window) return ERROR_INVALID_WINDOW_HANDLE;
    DWORD_PTR reference = 0;
    if (!GetWindowSubclass(window, minimumSizeSubclass, minimumSizeSubclassID, &reference)) return ERROR_NOT_FOUND;
    // Query the real window-procedure chain without changing the window size.
    MINMAXINFO limits = {0};
    SendMessageW(window, WM_GETMINMAXINFO, 0, (LPARAM)&limits);
    RECT frame;
    if (!minimumWindowRectangle(window, 0, 0, &frame)) {
        DWORD error = GetLastError();
        return error ? error : ERROR_GEN_FAILURE;
    }
    UINT dpi = GetDpiForWindow(window);
    if (!dpi) dpi = USER_DEFAULT_SCREEN_DPI;
    *width = MulDiv(limits.ptMinTrackSize.x - (frame.right - frame.left), USER_DEFAULT_SCREEN_DPI, (int)dpi);
    *height = MulDiv(limits.ptMinTrackSize.y - (frame.bottom - frame.top), USER_DEFAULT_SCREEN_DPI, (int)dpi);
    return ERROR_SUCCESS;
}

int32_t KokoroInitializeRuntime(void) {
    HRESULT hr = RoInitialize(RO_INIT_SINGLETHREADED);
    if (FAILED(hr)) return hr;
    runtimeInitialized = TRUE;
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    // Resolve the bootstrap beside the executable, never from the working directory.
    WCHAR path[32768];
    DWORD length = GetModuleFileNameW(NULL, path, 32768);
    if (!length || length >= 32768) return E_FAIL;
    WCHAR *separator = wcsrchr(path, L'\\');
    if (!separator) return E_FAIL;
    wcscpy_s(separator + 1, 32768 - (separator + 1 - path), L"Microsoft.WindowsAppRuntime.Bootstrap.dll");
    bootstrap = LoadLibraryExW(path, NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (!bootstrap) return HRESULT_FROM_WIN32(GetLastError());
    InitializeFn initialize = (InitializeFn)GetProcAddress(bootstrap, "MddBootstrapInitialize");
    if (!initialize) return E_NOINTERFACE;
    PACKAGE_VERSION minimum = {0};
    return initialize(0x00010007, L"", minimum);
}

void KokoroShutdownRuntime(void) {
    if (bootstrap) {
        ShutdownFn shutdown = (ShutdownFn)GetProcAddress(bootstrap, "MddBootstrapShutdown");
        if (shutdown) shutdown();
        FreeLibrary(bootstrap);
        bootstrap = NULL;
    }
    if (runtimeInitialized) { RoUninitialize(); runtimeInitialized = FALSE; }
}

static uint32_t saveCredential(PCWSTR target, const uint8_t *bytes, uint32_t count) {
    if (count > CRED_MAX_CREDENTIAL_BLOB_SIZE) return ERROR_BAD_LENGTH;
    CREDENTIALW credential = {0};
    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = (LPWSTR)target;
    credential.UserName = L"KokoroDesktop";
    credential.CredentialBlob = (LPBYTE)bytes;
    credential.CredentialBlobSize = count;
    credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
    return CredWriteW(&credential, 0) ? ERROR_SUCCESS : GetLastError();
}

static uint32_t loadCredential(PCWSTR target, uint8_t *bytes, uint32_t capacity, uint32_t *count) {
    PCREDENTIALW credential = NULL;
    if (!CredReadW(target, CRED_TYPE_GENERIC, 0, &credential)) return GetLastError();
    *count = credential->CredentialBlobSize;
    DWORD result = capacity < *count ? ERROR_INSUFFICIENT_BUFFER : ERROR_SUCCESS;
    if (result == ERROR_SUCCESS) memcpy(bytes, credential->CredentialBlob, *count);
    CredFree(credential);
    return result;
}

static uint32_t deleteCredential(PCWSTR target) {
    if (CredDeleteW(target, CRED_TYPE_GENERIC, 0)) return ERROR_SUCCESS;
    DWORD error = GetLastError();
    return error == ERROR_NOT_FOUND ? ERROR_SUCCESS : error;
}

uint32_t KokoroSaveCredential(const uint8_t *bytes, uint32_t count) { return saveCredential(credentialTarget, bytes, count); }
uint32_t KokoroLoadCredential(uint8_t *bytes, uint32_t capacity, uint32_t *count) { return loadCredential(credentialTarget, bytes, capacity, count); }
uint32_t KokoroDeleteCredential(void) { return deleteCredential(credentialTarget); }
uint32_t KokoroSaveImgBBKey(const uint8_t *bytes, uint32_t count) { return saveCredential(imageCredentialTarget, bytes, count); }
uint32_t KokoroLoadImgBBKey(uint8_t *bytes, uint32_t capacity, uint32_t *count) { return loadCredential(imageCredentialTarget, bytes, capacity, count); }
uint32_t KokoroDeleteImgBBKey(void) { return deleteCredential(imageCredentialTarget); }

uint32_t KokoroPickImages(uint16_t *paths, uint32_t capacity, uint32_t *count) {
    if (!paths || !count || capacity < 2) return ERROR_INVALID_PARAMETER;
    *count = 0;
    paths[0] = 0;
    HWND owner = GetActiveWindow();
    if (!owner) {
        owner = GetForegroundWindow();
        DWORD process = 0;
        GetWindowThreadProcessId(owner, &process);
        if (process != GetCurrentProcessId()) owner = NULL;
    }
    if (!owner) return ERROR_INVALID_WINDOW_HANDLE;
    static const WCHAR filter[] = L"Images (*.jpg;*.jpeg;*.png;*.gif;*.webp;*.bmp)\0*.jpg;*.jpeg;*.png;*.gif;*.webp;*.bmp\0\0";
    OPENFILENAMEW dialog = {0};
    dialog.lStructSize = sizeof(dialog);
    dialog.hwndOwner = owner;
    dialog.lpstrFilter = filter;
    dialog.lpstrFile = (LPWSTR)paths;
    dialog.nMaxFile = capacity;
    dialog.lpstrTitle = L"アップロードする画像を選択";
    dialog.Flags = OFN_EXPLORER | OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST |
        OFN_ALLOWMULTISELECT | OFN_NOCHANGEDIR | OFN_DONTADDTORECENT;
    if (!GetOpenFileNameW(&dialog)) {
        DWORD error = CommDlgExtendedError();
        return error ? error : ERROR_CANCELLED;
    }
    // Single selection: absolute path + NUL. Multi-selection: directory + NUL,
    // then each basename + NUL, terminated by an extra NUL. Swift decodes both.
    for (uint32_t index = 0; index + 1 < capacity; ++index) {
        if (!paths[index] && !paths[index + 1]) {
            *count = index + 2;
            return ERROR_SUCCESS;
        }
    }
    return ERROR_INSUFFICIENT_BUFFER;
}

int32_t KokoroIsShiftPressed(void) { return (GetKeyState(VK_SHIFT) & 0x8000) != 0; }
int32_t KokoroIsControlPressed(void) { return (GetKeyState(VK_CONTROL) & 0x8000) != 0; }

int32_t KokoroIsIMEComposing(void) {
    HWND focused = GetFocus();
    if (!focused) return 0;
    HIMC context = ImmGetContext(focused);
    if (!context) return 0;
    LONG length = ImmGetCompositionStringW(context, GCS_COMPSTR, NULL, 0);
    ImmReleaseContext(focused, context);
    return length > 0;
}

uint32_t KokoroShowEmojiPanel(void) {
    // The caller first focuses its text editor. Never send this shortcut to a
    // different foreground application, even if activation changed meanwhile.
    HWND foreground = GetForegroundWindow();
    DWORD process = 0;
    if (!foreground || !GetWindowThreadProcessId(foreground, &process) ||
        process != GetCurrentProcessId() || !GetFocus()) return ERROR_INVALID_WINDOW_HANDLE;

    // Leave the user's physical key state intact. An already-held Windows key
    // participates in the shortcut, without us pressing or releasing it.
    BOOL windowsHeld = (GetAsyncKeyState(VK_LWIN) & 0x8000) ||
                       (GetAsyncKeyState(VK_RWIN) & 0x8000);
    if ((GetAsyncKeyState(VK_CONTROL) & 0x8000) ||
        (GetAsyncKeyState(VK_MENU) & 0x8000) ||
        (GetAsyncKeyState(VK_SHIFT) & 0x8000) ||
        (GetAsyncKeyState(VK_OEM_PERIOD) & 0x8000)) return ERROR_BUSY;

    // Windows documents Win + period as the OS emoji-panel shortcut. One
    // SendInput batch keeps its down/up pairs together in the input stream.
    INPUT inputs[4] = {0};
    UINT count = 0;
    if (!windowsHeld) {
        inputs[count].type = INPUT_KEYBOARD;
        inputs[count++].ki.wVk = VK_LWIN;
    }
    UINT periodDown = count;
    inputs[count].type = INPUT_KEYBOARD;
    inputs[count++].ki.wVk = VK_OEM_PERIOD;
    UINT periodUp = count;
    inputs[count].type = INPUT_KEYBOARD;
    inputs[count].ki.wVk = VK_OEM_PERIOD;
    inputs[count++].ki.dwFlags = KEYEVENTF_KEYUP;
    if (!windowsHeld) {
        inputs[count].type = INPUT_KEYBOARD;
        inputs[count].ki.wVk = VK_LWIN;
        inputs[count++].ki.dwFlags = KEYEVENTF_KEYUP;
    }
    if (GetForegroundWindow() != foreground) return ERROR_INVALID_WINDOW_HANDLE;
    SetLastError(ERROR_SUCCESS);
    UINT inserted = SendInput(count, inputs, sizeof(INPUT));
    if (inserted == count) return ERROR_SUCCESS;
    DWORD error = GetLastError();

    // If insertion was partial, release only keys this call actually pressed.
    // Never emit a Windows key-up for a key the user was already holding.
    INPUT releases[2] = {0};
    UINT releaseCount = 0;
    if (inserted > periodDown && inserted <= periodUp) {
        releases[releaseCount].type = INPUT_KEYBOARD;
        releases[releaseCount].ki.wVk = VK_OEM_PERIOD;
        releases[releaseCount++].ki.dwFlags = KEYEVENTF_KEYUP;
    }
    if (!windowsHeld && inserted > 0) {
        releases[releaseCount].type = INPUT_KEYBOARD;
        releases[releaseCount].ki.wVk = VK_LWIN;
        releases[releaseCount++].ki.dwFlags = KEYEVENTF_KEYUP;
    }
    if (releaseCount) SendInput(releaseCount, releases, sizeof(INPUT));
    return error ? error : ERROR_GEN_FAILURE;
}

static uint64_t messagePumpCount;
uint64_t KokoroMessagePumpCount(void) { return messagePumpCount; }
double KokoroProcessCPUSeconds(void) {
    FILETIME created, exited, kernel, user;
    if (!GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user)) return 0;
    ULARGE_INTEGER k, u;
    k.LowPart = kernel.dwLowDateTime; k.HighPart = kernel.dwHighDateTime;
    u.LowPart = user.dwLowDateTime; u.HighPart = user.dwHighDateTime;
    return (double)(k.QuadPart + u.QuadPart) / 10000000.0;
}
double KokoroThreadCPUSeconds(void) {
    FILETIME created, exited, kernel, user;
    if (!GetThreadTimes(GetCurrentThread(), &created, &exited, &kernel, &user)) return 0;
    ULARGE_INTEGER k, u;
    k.LowPart = kernel.dwLowDateTime; k.HighPart = kernel.dwHighDateTime;
    u.LowPart = user.dwLowDateTime; u.HighPart = user.dwHighDateTime;
    return (double)(k.QuadPart + u.QuadPart) / 10000000.0;
}

int32_t KokoroPumpMessages(void) {
    ++messagePumpCount;
    typedef BOOL (WINAPI *PreTranslateFn)(const MSG *);
    static PreTranslateFn preTranslate;
    if (!preTranslate) {
        HMODULE windowing = GetModuleHandleW(L"Microsoft.UI.Windowing.Core.dll");
        if (windowing) preTranslate = (PreTranslateFn)GetProcAddress(windowing, "ContentPreTranslateMessage");
    }
    MSG message;
    // Yield to Swift even during a sustained stream of native messages.
    for (unsigned count = 0; count < 256 && PeekMessageW(&message, NULL, 0, 0, PM_REMOVE); ++count) {
        if (message.message == WM_QUIT) return 0;
        if (!preTranslate || !preTranslate(&message)) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
    return 1;
}

void KokoroWaitForMessages(uint32_t timeoutMilliseconds) {
    // Swift 6.4's dispatch.dll exposes the auto-reset event that CoreFoundation
    // waits on. libdispatch owns its lifetime; never close this borrowed handle.
    typedef HANDLE (*MainQueueHandleFn)(void);
    static HANDLE mainQueueEvent;
    static BOOL resolved;
    if (!resolved) {
        HMODULE dispatch = GetModuleHandleW(L"dispatch.dll");
        MainQueueHandleFn getHandle = dispatch ? (MainQueueHandleFn)GetProcAddress(
            dispatch, "_dispatch_get_main_queue_handle_4CF") : NULL;
        if (getHandle) mainQueueEvent = getHandle();
        resolved = TRUE;
    }
    // Respect Foundation's next timer deadline. The caller caps this at one
    // second for other RunLoop sources; keep the old bounded fallback if a
    // future runtime removes this SPI, so async work cannot become stuck.
    DWORD timeout = mainQueueEvent ? timeoutMilliseconds : min(timeoutMilliseconds, 10);
    DWORD result = MsgWaitForMultipleObjectsEx(mainQueueEvent ? 1 : 0,
        mainQueueEvent ? &mainQueueEvent : NULL, timeout, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
    if (mainQueueEvent && result == WAIT_OBJECT_0) {
        // Our wait consumed the auto-reset signal. Hand it back so the next
        // Foundation RunLoop pass can observe it and drain DispatchQueue.main.
        SetEvent(mainQueueEvent);
    }
    if (result == WAIT_FAILED) {
        mainQueueEvent = NULL;
        Sleep(10); // A failed wait must never turn into a busy loop.
    }
}
