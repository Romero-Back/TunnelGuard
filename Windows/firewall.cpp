#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <initguid.h>
#include <fwpmu.h>
#include <iphlpapi.h>
#include <userenv.h>
#include <cstring>
#include <memory>
#include <vector>

namespace {
const GUID sublayerKey = {0x4cc17cfa, 0xecc7, 0x4750, {0xac, 0x45, 0x52, 0x02, 0x9f, 0x06, 0x3a, 0x91}};
const GUID block4 = {0xcc457dc8, 0xd8ca, 0x470e, {0x8d, 0x1f, 0x3e, 0xc4, 0x95, 0x1b, 0x13, 0x6b}};
const GUID block6 = {0x6b134d31, 0x77bf, 0x4b15, {0xbd, 0xb0, 0x69, 0x99, 0x2a, 0x12, 0x2b, 0xd2}};

struct Engine {
    HANDLE handle = nullptr;
    ~Engine() { if (handle) FwpmEngineClose0(handle); }
    DWORD open(bool dynamic = false) {
        FWPM_SESSION0 session{};
        session.flags = dynamic ? FWPM_SESSION_FLAG_DYNAMIC : 0;
        session.txnWaitTimeoutInMSec = 5000;
        return FwpmEngineOpen0(nullptr, RPC_C_AUTHN_WINNT, nullptr, &session, &handle);
    }
};

struct Transaction {
    HANDLE engine;
    bool active = false;
    ~Transaction() { if (active) FwpmTransactionAbort0(engine); }
    DWORD begin() {
        const auto result = FwpmTransactionBegin0(engine, 0);
        active = result == ERROR_SUCCESS;
        return result;
    }
    DWORD commit() {
        const auto result = FwpmTransactionCommit0(engine);
        if (result == ERROR_SUCCESS) active = false;
        return result;
    }
};

struct AppId {
    FWP_BYTE_BLOB* value = nullptr;
    ~AppId() { FwpmFreeMemory0(reinterpret_cast<void**>(&value)); }
};

struct Handle {
    HANDLE value = nullptr;
    ~Handle() { if (value) CloseHandle(value); }
};

DWORD filter(HANDLE engine, const GUID& layer, const GUID& key, FWP_BYTE_BLOB* app, UINT16 port) {
    FWPM_FILTER_CONDITION0 conditions[5]{};
    conditions[0].fieldKey = FWPM_CONDITION_ALE_APP_ID;
    conditions[0].matchType = FWP_MATCH_EQUAL;
    conditions[0].conditionValue.type = FWP_BYTE_BLOB_TYPE;
    conditions[0].conditionValue.byteBlob = app;

    FWPM_FILTER0 rule{};
    rule.filterKey = key;
    rule.layerKey = layer;
    rule.subLayerKey = sublayerKey;
    rule.filterCondition = conditions;
    rule.numFilterConditions = 1;
    rule.weight.type = FWP_UINT8;
    if (port) {
        rule.displayData.name = const_cast<wchar_t*>(L"TunnelGuard: local verified proxy");
        rule.action.type = FWP_ACTION_PERMIT;
        rule.weight.uint8 = 15;
        conditions[1].fieldKey = FWPM_CONDITION_IP_REMOTE_ADDRESS;
        conditions[1].conditionValue.type = FWP_UINT32;
        conditions[1].conditionValue.uint32 = 0x7f000001;
        conditions[2].fieldKey = FWPM_CONDITION_IP_REMOTE_PORT;
        conditions[2].conditionValue.type = FWP_UINT16;
        conditions[2].conditionValue.uint16 = port;
        conditions[3].fieldKey = FWPM_CONDITION_IP_PROTOCOL;
        conditions[3].conditionValue.type = FWP_UINT8;
        conditions[3].conditionValue.uint8 = IPPROTO_TCP;
        conditions[4].fieldKey = FWPM_CONDITION_FLAGS;
        conditions[4].matchType = FWP_MATCH_FLAGS_ALL_SET;
        conditions[4].conditionValue.type = FWP_UINT32;
        conditions[4].conditionValue.uint32 = FWP_CONDITION_FLAG_IS_LOOPBACK;
        rule.numFilterConditions = 5;
    } else {
        rule.displayData.name = const_cast<wchar_t*>(L"TunnelGuard: block direct app traffic");
        rule.flags = FWPM_FILTER_FLAG_PERSISTENT | FWPM_FILTER_FLAG_CLEAR_ACTION_RIGHT;
        rule.action.type = FWP_ACTION_BLOCK;
        rule.weight.uint8 = 0;
    }
    return FwpmFilterAdd0(engine, &rule, nullptr, nullptr);
}

DWORD existing(HANDLE engine, const GUID& layer, const GUID& key, const FWP_BYTE_BLOB* expected) {
    FWPM_FILTER0* rule = nullptr;
    const auto result = FwpmFilterGetByKey0(engine, &key, &rule);
    if (result != ERROR_SUCCESS) return result;
    bool matches = IsEqualGUID(rule->layerKey, layer) && IsEqualGUID(rule->subLayerKey, sublayerKey)
        && rule->action.type == FWP_ACTION_BLOCK && (rule->flags & FWPM_FILTER_FLAG_PERSISTENT)
        && !(rule->flags & FWPM_FILTER_FLAG_DISABLED) && rule->numFilterConditions == 1;
    if (matches) {
        const auto& condition = rule->filterCondition[0];
        matches = IsEqualGUID(condition.fieldKey, FWPM_CONDITION_ALE_APP_ID)
            && condition.matchType == FWP_MATCH_EQUAL && condition.conditionValue.type == FWP_BYTE_BLOB_TYPE
            && condition.conditionValue.byteBlob != nullptr;
        if (matches && expected) {
            const auto* actual = condition.conditionValue.byteBlob;
            matches = actual->size == expected->size && !std::memcmp(actual->data, expected->data, expected->size);
        }
    }
    FwpmFreeMemory0(reinterpret_cast<void**>(&rule));
    return matches ? ERROR_SUCCESS : ERROR_ALREADY_EXISTS;
}

DWORD addBlock(HANDLE engine, const GUID& layer, const GUID& key, FWP_BYTE_BLOB* app) {
    const auto result = existing(engine, layer, key, app);
    return result == static_cast<DWORD>(FWP_E_FILTER_NOT_FOUND) ? filter(engine, layer, key, app, 0) : result;
}

bool currentUser(HANDLE token, std::vector<BYTE>& info) {
    DWORD size = 0;
    GetTokenInformation(token, TokenUser, nullptr, 0, &size);
    if (!size) return false;
    info.resize(size);
    return GetTokenInformation(token, TokenUser, info.data(), size, &size) != FALSE;
}
}

extern "C" __declspec(dllexport) DWORD tg_lock(const wchar_t* executable) {
    Engine engine;
    auto result = engine.open();
    if (result) return result;
    AppId app;
    if ((result = FwpmGetAppIdFromFileName0(executable, &app.value))) return result;
    Transaction transaction{engine.handle};
    if ((result = transaction.begin())) return result;
    FWPM_SUBLAYER0 layer{};
    layer.subLayerKey = sublayerKey;
    layer.displayData.name = const_cast<wchar_t*>(L"TunnelGuard");
    layer.flags = FWPM_SUBLAYER_FLAG_PERSISTENT;
    layer.weight = 0x7ffa;
    result = FwpmSubLayerAdd0(engine.handle, &layer, nullptr);
    if (result && result != static_cast<DWORD>(FWP_E_ALREADY_EXISTS)) return result;
    if ((result = addBlock(engine.handle, FWPM_LAYER_ALE_AUTH_CONNECT_V4, block4, app.value))) return result;
    if ((result = addBlock(engine.handle, FWPM_LAYER_ALE_AUTH_CONNECT_V6, block6, app.value))) return result;
    return transaction.commit();
}

extern "C" __declspec(dllexport) DWORD tg_status(const wchar_t* executable) {
    Engine engine;
    auto result = engine.open();
    if (result) return result;
    AppId app;
    if ((result = FwpmGetAppIdFromFileName0(executable, &app.value))) return result;
    if ((result = existing(engine.handle, FWPM_LAYER_ALE_AUTH_CONNECT_V4, block4, app.value))) return result;
    return existing(engine.handle, FWPM_LAYER_ALE_AUTH_CONNECT_V6, block6, app.value);
}

extern "C" __declspec(dllexport) DWORD tg_unlock() {
    Engine engine;
    auto result = engine.open();
    if (result) return result;
    Transaction transaction{engine.handle};
    if ((result = transaction.begin())) return result;
    for (const auto* key : {&block4, &block6}) {
        result = FwpmFilterDeleteByKey0(engine.handle, key);
        if (result && result != static_cast<DWORD>(FWP_E_FILTER_NOT_FOUND)) return result;
    }
    return transaction.commit();
}

extern "C" __declspec(dllexport) DWORD tg_allow(const wchar_t* executable, UINT16 port, HANDLE* session) {
    if (!port || !session) return ERROR_INVALID_PARAMETER;
    Engine engine;
    auto result = engine.open(true);
    if (result) return result;
    AppId app;
    if ((result = FwpmGetAppIdFromFileName0(executable, &app.value))) return result;
    Transaction transaction{engine.handle};
    if ((result = transaction.begin())) return result;
    if ((result = existing(engine.handle, FWPM_LAYER_ALE_AUTH_CONNECT_V4, block4, app.value))) return result;
    if ((result = existing(engine.handle, FWPM_LAYER_ALE_AUTH_CONNECT_V6, block6, app.value))) return result;
    if ((result = filter(engine.handle, FWPM_LAYER_ALE_AUTH_CONNECT_V4, GUID{}, app.value, port))) return result;
    if ((result = transaction.commit())) return result;
    *session = engine.handle;
    engine.handle = nullptr;
    return ERROR_SUCCESS;
}

extern "C" __declspec(dllexport) DWORD tg_close(HANDLE session) { return FwpmEngineClose0(session); }

extern "C" __declspec(dllexport) DWORD tg_route(const wchar_t* ipv4, ULONG* index) {
    SOCKADDR_IN address{};
    address.sin_family = AF_INET;
    if (InetPtonW(AF_INET, ipv4, &address.sin_addr) != 1) return ERROR_INVALID_PARAMETER;
    return GetBestInterfaceEx(reinterpret_cast<sockaddr*>(&address), index);
}

extern "C" __declspec(dllexport) DWORD tg_interface(ULONG index, UINT64* identifier) {
    NET_LUID luid{};
    const auto result = ConvertInterfaceIndexToLuid(index, &luid);
    if (!result) *identifier = luid.Value;
    return result;
}

extern "C" __declspec(dllexport) DWORD tg_launch(const wchar_t* executable, wchar_t* command, HANDLE* session) {
    DWORD pid = 0;
    if (!GetWindowThreadProcessId(GetShellWindow(), &pid)) return ERROR_NOT_FOUND;
    Handle shell{OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid)};
    if (!shell.value) return GetLastError();
    Handle shellToken, ownToken, primary;
    if (!OpenProcessToken(shell.value, TOKEN_DUPLICATE | TOKEN_QUERY, &shellToken.value)
        || !OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &ownToken.value)) return GetLastError();
    std::vector<BYTE> shellUser, ownUser;
    if (!currentUser(shellToken.value, shellUser) || !currentUser(ownToken.value, ownUser)) return GetLastError();
    if (!EqualSid(reinterpret_cast<TOKEN_USER*>(shellUser.data())->User.Sid,
                  reinterpret_cast<TOKEN_USER*>(ownUser.data())->User.Sid)) return ERROR_ACCESS_DENIED;
    TOKEN_ELEVATION elevation{};
    DWORD size = 0;
    if (!GetTokenInformation(shellToken.value, TokenElevation, &elevation, sizeof(elevation), &size)) return GetLastError();
    if (elevation.TokenIsElevated) return ERROR_ACCESS_DENIED;
    if (!DuplicateTokenEx(shellToken.value, TOKEN_ASSIGN_PRIMARY | TOKEN_DUPLICATE | TOKEN_QUERY,
                          nullptr, SecurityImpersonation, TokenPrimary, &primary.value)) return GetLastError();
    void* environment = nullptr;
    if (!CreateEnvironmentBlock(&environment, primary.value, FALSE)) return GetLastError();
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.lpDesktop = const_cast<wchar_t*>(L"winsta0\\default");
    PROCESS_INFORMATION process{};
    const BOOL started = CreateProcessWithTokenW(primary.value, 0, executable, command,
                                                  CREATE_UNICODE_ENVIRONMENT, environment,
                                                  nullptr, &startup, &process);
    const DWORD result = started ? ERROR_SUCCESS : GetLastError();
    DestroyEnvironmentBlock(environment);
    if (!started) return result;
    CloseHandle(process.hThread);
    *session = process.hProcess;
    return ERROR_SUCCESS;
}
