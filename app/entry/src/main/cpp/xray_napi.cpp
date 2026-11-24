// NAPI bridge between ArkTS and the xray-rust C ABI (xray_ffi.h).
//
// The Rust core is linked statically into this module (libxray_ffi.a), so the
// HAP ships a single native library and no dlopen path juggling is needed.
#include <napi/native_api.h>

#include <cstdint>
#include <cstdio>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <vector>
#include <thread>
#include <atomic>

#include "xray_ffi.h"

namespace {

// shared: outbound probes run concurrently on NAPI worker threads while core
// lifecycle calls (start/restart/stop) need exclusive access.
std::shared_mutex g_mutex;
XrayCoreHandle *g_core = nullptr;
std::string g_warnings;
// Set when an FFI call on the live handle fails; the ArkTS watchdog uses it to
// decide that the core must be rebuilt (FlClash-style core restart).
bool g_unhealthy = false;

std::string TakeError(XrayError **err, const char *fallback) {
  std::string message = fallback;
  if (err != nullptr && *err != nullptr) {
    const char *detail = xray_error_message(*err);
    if (detail != nullptr && detail[0] != '\0') {
      message = detail;
    }
    xray_error_free(*err);
    *err = nullptr;
  }
  return message;
}

napi_value Throw(napi_env env, const std::string &message) {
  napi_throw_error(env, nullptr, message.c_str());
  return nullptr;
}

bool GetUtf8(napi_env env, napi_value value, std::string *out) {
  size_t length = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
    return false;
  }
  std::vector<char> buffer(length + 1);
  if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &length) != napi_ok) {
    return false;
  }
  out->assign(buffer.data(), length);
  return true;
}

// Two-pass UTF-8 output helper for the FFI's size-query convention.
template <typename Call>
bool ReadText(Call &&call, std::string *out, std::string *error) {
  size_t needed = 0;
  XrayError *err = nullptr;
  XrayStatus status = call(nullptr, 0, &needed, &err);
  if (status != XRAY_STATUS_OK) {
    *error = TakeError(&err, "size query failed");
    return false;
  }
  std::vector<char> buffer(needed + 1);
  status = call(buffer.data(), buffer.size(), &needed, &err);
  if (status != XRAY_STATUS_OK) {
    *error = TakeError(&err, "read failed");
    return false;
  }
  out->assign(buffer.data(), needed);
  return true;
}

napi_value MakeString(napi_env env, const std::string &value) {
  napi_value result = nullptr;
  napi_create_string_utf8(env, value.c_str(), value.size(), &result);
  return result;
}

struct StartArgs {
  std::string config;
  std::string logDir;
  std::string geodataDir;
  int32_t tunFd = -1;
  int32_t mtu = 1500;
};

bool ParseStartArgs(napi_env env, napi_callback_info info, StartArgs *out, std::string *error) {
  size_t argc = 5;
  napi_value argv[5] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 2) {
    *error = "start(configJson, tunFd, mtu?, logDir?, geodataDir?)";
    return false;
  }
  if (!GetUtf8(env, argv[0], &out->config) ||
      napi_get_value_int32(env, argv[1], &out->tunFd) != napi_ok) {
    *error = "configJson must be a string and tunFd a number";
    return false;
  }
  napi_valuetype type = napi_undefined;
  if (argc > 2 && argv[2] != nullptr) {
    napi_typeof(env, argv[2], &type);
    if (type == napi_number) {
      napi_get_value_int32(env, argv[2], &out->mtu);
    }
  }
  if (argc > 3 && argv[3] != nullptr) {
    napi_typeof(env, argv[3], &type);
    if (type == napi_string) {
      GetUtf8(env, argv[3], &out->logDir);
    }
  }
  if (argc > 4 && argv[4] != nullptr) {
    napi_typeof(env, argv[4], &type);
    if (type == napi_string) {
      GetUtf8(env, argv[4], &out->geodataDir);
    }
  }
  if (out->tunFd < 0) {
    *error = "invalid tun file descriptor";
    return false;
  }
  return true;
}

// Caller must hold g_mutex and must have no live handle.
//
// Two attempts: the first enables the core's file logging. If that particular
// step is refused by the host sandbox (it used to abort the whole load on
// HarmonyOS), the second attempt starts the same config without core logging
// instead of failing the tunnel.
bool StartLocked(const StartArgs &args, std::string *error) {
  for (int attempt = 0; attempt < 2; ++attempt) {
    const bool withLogging = attempt == 0 && !args.logDir.empty();
    XrayError *err = nullptr;
    XrayCoreHandle *core = xray_core_new(&err);
    if (core == nullptr) {
      *error = "xray_core_new failed: " + TakeError(&err, "unknown error");
      return false;
    }

#define XRAY_STEP(expression)                                  \
  do {                                                         \
    XrayStatus status_ = (expression);                         \
    if (status_ != XRAY_STATUS_OK) {                           \
      *error = TakeError(&err, #expression);                   \
      xray_core_free(core);                                    \
      return false;                                            \
    }                                                          \
  } while (0)

    if (withLogging) {
      xray_core_set_file_logging(core, args.logDir.c_str(), 1, &err);
      TakeError(&err, "file logging");
    }
    if (!args.geodataDir.empty()) {
      // Best effort: a missing directory must not stop the tunnel; geosite/geoip
      // rules simply fail to compile later and are reported by the config load.
      xray_core_set_geodata_search_dir(core, args.geodataDir.c_str(), &err);
      TakeError(&err, "geodata dir");
    }
    XRAY_STEP(xray_core_set_tun_mtu(core, static_cast<uint32_t>(args.mtu), &err));
    XRAY_STEP(xray_core_set_tun_runtime_profile(core, XRAY_TUN_RUNTIME_PROFILE_MOBILE_PLUS, &err));
    XRAY_STEP(xray_core_set_tun_fd(core, args.tunFd, XRAY_TUN_FD_PACKET_FORMAT_RAW_IP,
                                   XRAY_TUN_FD_CLOSE_POLICY_BORROWED, &err));

    const XrayStatus loadStatus =
        xray_core_load_config_json(core, args.config.c_str(), &err);
    if (loadStatus != XRAY_STATUS_OK) {
      const std::string message = TakeError(&err, "load_config_json");
      xray_core_free(core);
      if (withLogging && message.find("file logging") != std::string::npos) {
        continue;
      }
      *error = message;
      return false;
    }
    g_warnings.clear();
    {
      std::string warningError;
      auto call = [core](char *buffer, size_t length, size_t *written, XrayError **slot) {
        return xray_core_config_warnings(core, buffer, length, written, slot);
      };
      std::string warnings;
      if (ReadText(call, &warnings, &warningError)) {
        g_warnings = warnings;
      }
    }

    XRAY_STEP(xray_core_start(core, &err));
#undef XRAY_STEP

    g_core = core;
    g_unhealthy = false;
    return true;
  }
  *error = "failed to start the core";
  return false;
}

// Caller must hold g_mutex.
void StopLocked() {
  if (g_core == nullptr) {
    return;
  }
  XrayError *err = nullptr;
  xray_core_stop(g_core, &err);
  TakeError(&err, "stop failed");
  xray_core_free(g_core);
  g_core = nullptr;
  g_warnings.clear();
  g_unhealthy = false;
}

napi_value Version(napi_env env, napi_callback_info info) {
  char buffer[32];
  std::snprintf(buffer, sizeof(buffer), "%u.%u", xray_ffi_version_major(),
                xray_ffi_version_minor());
  return MakeString(env, buffer);
}

napi_value Capabilities(napi_env env, napi_callback_info info) {
  napi_value result = nullptr;
  napi_create_double(env, static_cast<double>(xray_ffi_capabilities()), &result);
  return result;
}

napi_value ImportProfile(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 1) {
    return Throw(env, "importProfile(requestJson)");
  }
  std::string request;
  if (!GetUtf8(env, argv[0], &request)) {
    return Throw(env, "importProfile: request must be a string");
  }
  std::string output;
  std::string error;
  auto call = [&request](char *buffer, size_t length, size_t *written, XrayError **err) {
    return xray_profile_import_json(reinterpret_cast<const uint8_t *>(request.data()),
                                    request.size(), buffer, length, written, err);
  };
  if (!ReadText(call, &output, &error)) {
    return Throw(env, "profile import failed: " + error);
  }
  return MakeString(env, output);
}

napi_value Start(napi_env env, napi_callback_info info) {
  StartArgs args;
  std::string error;
  if (!ParseStartArgs(env, info, &args, &error)) {
    return Throw(env, error);
  }
  std::unique_lock<std::shared_mutex> guard(g_mutex);
  if (g_core != nullptr) {
    return Throw(env, "start: a core is already running, call stop() first");
  }
  if (!StartLocked(args, &error)) {
    return Throw(env, error);
  }
  return nullptr;
}

// Rebuilds the core on the same TUN fd after a failed health check.
napi_value Restart(napi_env env, napi_callback_info info) {
  StartArgs args;
  std::string error;
  if (!ParseStartArgs(env, info, &args, &error)) {
    return Throw(env, error);
  }
  std::unique_lock<std::shared_mutex> guard(g_mutex);
  StopLocked();
  if (!StartLocked(args, &error)) {
    return Throw(env, error);
  }
  return nullptr;
}

napi_value Stop(napi_env env, napi_callback_info info) {
  std::unique_lock<std::shared_mutex> guard(g_mutex);
  StopLocked();
  return nullptr;
}

napi_value IsRunning(napi_env env, napi_callback_info info) {
  std::unique_lock<std::shared_mutex> guard(g_mutex);
  napi_value result = nullptr;
  napi_get_boolean(env, g_core != nullptr && !g_unhealthy, &result);
  return result;
}

napi_value Warnings(napi_env env, napi_callback_info info) {
  std::unique_lock<std::shared_mutex> guard(g_mutex);
  return MakeString(env, g_warnings);
}

napi_value Stats(napi_env env, napi_callback_info info) {
  std::unique_lock<std::shared_mutex> guard(g_mutex);
  XrayTunStats stats{};
  stats.struct_size = sizeof(stats);
  double up = 0;
  double down = 0;
  double tcpFlows = 0;
  double udpFlows = 0;
  double drops = 0;
  double packets = 0;
  if (g_core != nullptr) {
    XrayError *err = nullptr;
    const XrayStatus status = xray_tun_stats(g_core, &stats, &err);
    if (status == XRAY_STATUS_OK) {
      up = static_cast<double>(stats.tcp_remote_written_bytes + stats.udp_remote_written_bytes);
      down = static_cast<double>(stats.tcp_remote_read_bytes + stats.udp_remote_read_bytes);
      tcpFlows = static_cast<double>(stats.active_tcp_flows);
      udpFlows = static_cast<double>(stats.active_udp_flows);
      drops = static_cast<double>(stats.dropped_packets + stats.udp_budget_drops);
      packets = static_cast<double>(stats.inbound_packets + stats.outbound_packets);
    } else {
      g_unhealthy = true;
    }
    TakeError(&err, "stats failed");
  }
  napi_value result = nullptr;
  napi_create_object(env, &result);
  auto set = [env, result](const char *name, double value) {
    napi_value v = nullptr;
    napi_create_double(env, value, &v);
    napi_set_named_property(env, result, name, v);
  };
  set("up", up);
  set("down", down);
  set("tcpFlows", tcpFlows);
  set("udpFlows", udpFlows);
  set("drops", drops);
  set("packets", packets);
  return result;
}

// HTTP probe through the running core's default outbound, for the in-app
// "test node" action. Answers "is the node usable" without a second app.
napi_value Probe(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 1) {
    return Throw(env, "probe(url, timeoutMs?)");
  }
  std::string url;
  int32_t timeoutMs = 8000;
  if (!GetUtf8(env, argv[0], &url)) {
    return Throw(env, "probe: url must be a string");
  }
  napi_valuetype type = napi_undefined;
  if (argc > 1 && argv[1] != nullptr) {
    napi_typeof(env, argv[1], &type);
    if (type == napi_number) {
      napi_get_value_int32(env, argv[1], &timeoutMs);
    }
  }
  std::unique_lock<std::shared_mutex> guard(g_mutex);
  if (g_core == nullptr) {
    return Throw(env, "probe: core is not running");
  }
  uint64_t delayMs = 0;
  int32_t failureKind = 0;
  uint16_t httpStatus = 0;
  XrayError *err = nullptr;
  const XrayStatus status = xray_core_probe_outbound_url(
      g_core, url.c_str(), static_cast<uint64_t>(timeoutMs), nullptr, &delayMs,
      &failureKind, &httpStatus, &err);
  if (status != XRAY_STATUS_OK) {
    return Throw(env, "probe failed: " + TakeError(&err, "probe error"));
  }
  napi_value result = nullptr;
  napi_create_object(env, &result);
  auto setNumber = [env, result](const char *name, double value) {
    napi_value v = nullptr;
    napi_create_double(env, value, &v);
    napi_set_named_property(env, result, name, v);
  };
  setNumber("delayMs", static_cast<double>(delayMs));
  setNumber("failureKind", static_cast<double>(failureKind));
  setNumber("httpStatus", static_cast<double>(httpStatus));
  return result;
}

// Cancels the probes already in flight (ABI 1.15): the node list calls this as
// soon as another run starts or the page closes, so a probe nobody waits for no
// longer holds a worker (and the core's probe slot) for its full timeout.
napi_value ProbeCancel(napi_env env, napi_callback_info info) {
  std::shared_lock<std::shared_mutex> guard(g_mutex);
  if (g_core == nullptr) {
    return Throw(env, "cancelProbes: core is not running");
  }
  XrayError *err = nullptr;
  const XrayStatus status = xray_core_cancel_inflight_outbound_probes(g_core, &err);
  if (status != XRAY_STATUS_OK) {
    return Throw(env, "cancelProbes failed: " + TakeError(&err, "cancel error"));
  }
  return nullptr;
}

// Result of one tagged probe, filled on a NAPI worker thread.
struct OutboundProbeWork {
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  std::string url;
  std::string tag;
  uint64_t timeoutMs = 8000;
  int32_t status = -1;
  uint64_t delayMs = 0;
  int32_t failureKind = 0;
  uint16_t httpStatus = 0;
  std::string message;
};

void ProbeOutboundExecute(napi_env env, void *data) {
  auto *work = static_cast<OutboundProbeWork *>(data);
  // Shared lock: several probes run at once, while start/restart/stop wait for
  // them before touching (or freeing) the handle.
  std::shared_lock<std::shared_mutex> guard(g_mutex);
  if (g_core == nullptr) {
    work->message = "core is not running";
    return;
  }
  XrayError *err = nullptr;
  work->status = static_cast<int32_t>(xray_core_probe_outbound_url(
      g_core, work->url.c_str(), work->timeoutMs,
      work->tag.empty() ? nullptr : work->tag.c_str(), &work->delayMs,
      &work->failureKind, &work->httpStatus, &err));
  if (work->status != static_cast<int32_t>(XRAY_STATUS_OK)) {
    work->message = TakeError(&err, "probe error");
  }
}

void ProbeOutboundComplete(napi_env env, napi_status status, void *data) {
  auto *work = static_cast<OutboundProbeWork *>(data);
  if (status == napi_ok && work->deferred != nullptr) {
    napi_value result = nullptr;
    napi_create_object(env, &result);
    auto setNumber = [env, result](const char *name, double value) {
      napi_value v = nullptr;
      napi_create_double(env, value, &v);
      napi_set_named_property(env, result, name, v);
    };
    setNumber("status", static_cast<double>(work->status));
    setNumber("delayMs", static_cast<double>(work->delayMs));
    setNumber("failureKind", static_cast<double>(work->failureKind));
    setNumber("httpStatus", static_cast<double>(work->httpStatus));
    napi_value text = nullptr;
    napi_create_string_utf8(env, work->message.c_str(), work->message.size(), &text);
    napi_set_named_property(env, result, "message", text);
    napi_resolve_deferred(env, work->deferred, result);
  }
  if (work->work != nullptr) {
    napi_delete_async_work(env, work->work);
  }
  delete work;
}

// HTTP probe through one named outbound of the running core: v2rayNG's "real
// delay" for a single node. The tunnel config carries every saved node as an
// outbound tagged with its ArkTS entry id, so the node list can measure each
// node through the proxy without switching the tunnel.
//
// The probe blocks for up to timeoutMs, so it runs as NAPI async work: a
// synchronous call here would freeze the ArkTS thread for seconds and make the
// requested concurrency pointless. A failed status is resolved in the result
// rather than thrown: the caller falls back to a TCP/UDP probe when the tag is
// not part of the running config.
napi_value ProbeOutbound(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 1) {
    return Throw(env, "probeOutbound(url, timeoutMs?, tag?)");
  }
  std::string url;
  if (!GetUtf8(env, argv[0], &url)) {
    return Throw(env, "probeOutbound: url must be a string");
  }
  int32_t timeoutMs = 8000;
  napi_valuetype type = napi_undefined;
  if (argc > 1 && argv[1] != nullptr) {
    napi_typeof(env, argv[1], &type);
    if (type == napi_number) {
      napi_get_value_int32(env, argv[1], &timeoutMs);
    }
  }
  std::string tag;
  if (argc > 2 && argv[2] != nullptr) {
    napi_typeof(env, argv[2], &type);
    if (type == napi_string) {
      GetUtf8(env, argv[2], &tag);
    }
  }
  if (timeoutMs < 1) {
    timeoutMs = 1;
  }
  if (timeoutMs > 60000) {
    timeoutMs = 60000;
  }

  napi_value promise = nullptr;
  napi_deferred deferred = nullptr;
  if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
    return Throw(env, "probeOutbound: cannot create promise");
  }
  auto *work = new OutboundProbeWork();
  work->deferred = deferred;
  work->url = url;
  work->tag = tag;
  work->timeoutMs = static_cast<uint64_t>(timeoutMs);
  napi_value resourceName = nullptr;
  napi_create_string_utf8(env, "xrayProbeOutbound", NAPI_AUTO_LENGTH, &resourceName);
  if (napi_create_async_work(env, nullptr, resourceName, ProbeOutboundExecute,
                             ProbeOutboundComplete, work, &work->work) != napi_ok ||
      napi_queue_async_work(env, work->work) != napi_ok) {
    if (work->work != nullptr) {
      napi_delete_async_work(env, work->work);
    }
    delete work;
    napi_value errorMessage = nullptr;
    napi_create_string_utf8(env, "probeOutbound: cannot queue work", NAPI_AUTO_LENGTH,
                            &errorMessage);
    napi_reject_deferred(env, deferred, errorMessage);
  }
  return promise;
}


// v2rayNG-style speed test: build a temporary core from a TUN-less config
// (the profile outbounds only), probe each tagged outbound, then tear it down.
// The live tunnel/core are untouched, so the router and the running VPN keep
// their state while the node list is being measured.
struct ProfileProbeSpec {
  std::string tag;
  std::string url;
  int32_t timeoutMs = 8000;
};

struct ProfileProbeOutcome {
  std::string tag;
  int32_t status = -1;
  uint64_t delayMs = 0;
  int32_t failureKind = 0;
  uint16_t httpStatus = 0;
  std::string message;
};

struct ProfileProbeWork {
  std::string config;
  std::string geodata;
  std::string error;
  std::vector<ProfileProbeSpec> specs;
  std::vector<ProfileProbeOutcome> outcomes;
  napi_deferred deferred = nullptr;
  napi_async_work work = nullptr;
};

void ProbeProfilesExecute(napi_env, void *data) {
  auto *w = static_cast<ProfileProbeWork *>(data);
  XrayError *err = nullptr;
  XrayCoreHandle *core = xray_core_new(&err);
  if (core == nullptr) {
    w->error = "xray_core_new failed: " + TakeError(&err, "unknown error");
    return;
  }
  if (!w->geodata.empty()) {
    xray_core_set_geodata_search_dir(core, w->geodata.c_str(), &err);
  }
  if (xray_core_load_config_json(core, w->config.c_str(), &err) != XRAY_STATUS_OK) {
    w->error = "probe config rejected: " + TakeError(&err, "config error");
    xray_core_free(core);
    return;
  }
  if (xray_core_start(core, &err) != XRAY_STATUS_OK) {
    w->error = "probe core start failed: " + TakeError(&err, "start error");
    xray_core_stop(core, &err);
    xray_core_free(core);
    return;
  }
  // v2rayN-style: probe many outbounds at once instead of one by one.
  w->outcomes.resize(w->specs.size());
  std::atomic<size_t> next{0};
  auto worker = [&]() {
    for (;;) {
      const size_t index = next.fetch_add(1);
      if (index >= w->specs.size()) {
        return;
      }
      const auto &spec = w->specs[index];
      ProfileProbeOutcome o;
      o.tag = spec.tag;
      XrayError *probeErr = nullptr;
      uint64_t delayMs = 0;
      int32_t failureKind = 0;
      uint16_t httpStatus = 0;
      o.status = static_cast<int32_t>(xray_core_probe_outbound_url(
          core, spec.url.c_str(), static_cast<uint64_t>(spec.timeoutMs),
          spec.tag.empty() ? nullptr : spec.tag.c_str(), &delayMs, &failureKind,
          &httpStatus, &probeErr));
      o.delayMs = delayMs;
      o.failureKind = failureKind;
      o.httpStatus = httpStatus;
      if (o.status != static_cast<int32_t>(XRAY_STATUS_OK)) {
        o.message = TakeError(&probeErr, "probe error");
      }
      w->outcomes[index] = o;
    }
  };
  const size_t hardware = std::thread::hardware_concurrency();
  size_t workers = hardware == 0 ? 8 : hardware * 2;
  if (workers < 8) workers = 8;
  if (workers > 24) workers = 24;
  if (workers > w->specs.size()) workers = w->specs.size();
  std::vector<std::thread> threads;
  for (size_t i = 0; i < workers; i++) {
    threads.emplace_back(worker);
  }
  for (auto &t : threads) {
    t.join();
  }
  xray_core_stop(core, &err);
  xray_core_free(core);
}

void ProbeProfilesComplete(napi_env env, napi_status status, void *data) {
  auto *w = static_cast<ProfileProbeWork *>(data);
  if (status == napi_ok && w->deferred != nullptr) {
    if (!w->error.empty()) {
      napi_value msg = nullptr;
      napi_create_string_utf8(env, w->error.c_str(), NAPI_AUTO_LENGTH, &msg);
      napi_reject_deferred(env, w->deferred, msg);
    } else {
      napi_value array = nullptr;
      napi_create_array_with_length(env, w->outcomes.size(), &array);
      for (size_t i = 0; i < w->outcomes.size(); i++) {
        const auto &o = w->outcomes[i];
        napi_value item = nullptr;
        napi_create_object(env, &item);
        auto setNum = [env, item](const char *name, int32_t value) {
          napi_value v = nullptr;
          napi_create_int32(env, value, &v);
          napi_set_named_property(env, item, name, v);
        };
        napi_value tag = nullptr;
        napi_create_string_utf8(env, o.tag.c_str(), o.tag.size(), &tag);
        napi_set_named_property(env, item, "tag", tag);
        setNum("status", o.status);
        setNum("delayMs", static_cast<int32_t>(o.delayMs));
        setNum("failureKind", o.failureKind);
        setNum("httpStatus", static_cast<int32_t>(o.httpStatus));
        napi_value message = nullptr;
        napi_create_string_utf8(env, o.message.c_str(), o.message.size(), &message);
        napi_set_named_property(env, item, "message", message);
        napi_set_element(env, array, static_cast<uint32_t>(i), item);
      }
      napi_resolve_deferred(env, w->deferred, array);
    }
  }
  if (w->work != nullptr) {
    napi_delete_async_work(env, w->work);
  }
  delete w;
}

// probeProfiles(configJson, probes, geodataDir?)
// - configJson: the full tunnel JSON with inbounds removed
// - probes: [{tag,url,timeoutMs}]
// - geodataDir: optional geosite/geoip search dir
napi_value ProbeProfiles(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 2) {
    return Throw(env, "probeProfiles(configJson, probes, geodataDir?)");
  }
  std::string config;
  if (!GetUtf8(env, argv[0], &config)) {
    return Throw(env, "probeProfiles: config must be a string");
  }
  bool isArray = false;
  if (napi_is_array(env, argv[1], &isArray) != napi_ok || !isArray) {
    return Throw(env, "probeProfiles: probes must be an array");
  }
  uint32_t count = 0;
  napi_get_array_length(env, argv[1], &count);
  auto *work = new ProfileProbeWork();
  work->config = config;
  if (argc > 2 && argv[2] != nullptr) {
    napi_valuetype type = napi_undefined;
    napi_typeof(env, argv[2], &type);
    if (type == napi_string) {
      GetUtf8(env, argv[2], &work->geodata);
    }
  }
  for (uint32_t i = 0; i < count; i++) {
    napi_value item = nullptr;
    if (napi_get_element(env, argv[1], i, &item) != napi_ok || item == nullptr) {
      continue;
    }
    ProfileProbeSpec spec;
    napi_value tag = nullptr;
    napi_value url = nullptr;
    napi_value timeout = nullptr;
    if (napi_get_named_property(env, item, "tag", &tag) == napi_ok) {
      GetUtf8(env, tag, &spec.tag);
    }
    if (napi_get_named_property(env, item, "url", &url) == napi_ok) {
      GetUtf8(env, url, &spec.url);
    }
    if (napi_get_named_property(env, item, "timeoutMs", &timeout) == napi_ok) {
      napi_valuetype t = napi_undefined;
      napi_typeof(env, timeout, &t);
      if (t == napi_number) {
        napi_get_value_int32(env, timeout, &spec.timeoutMs);
      }
    }
    if (spec.url.empty()) {
      continue;
    }
    if (spec.timeoutMs < 1) spec.timeoutMs = 1;
    if (spec.timeoutMs > 60000) spec.timeoutMs = 60000;
    work->specs.push_back(spec);
  }
  napi_value promise = nullptr;
  napi_deferred deferred = nullptr;
  if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
    delete work;
    return Throw(env, "probeProfiles: cannot create promise");
  }
  work->deferred = deferred;
  napi_value resourceName = nullptr;
  napi_create_string_utf8(env, "xrayProbeProfiles", NAPI_AUTO_LENGTH, &resourceName);
  if (napi_create_async_work(env, nullptr, resourceName, ProbeProfilesExecute,
                             ProbeProfilesComplete, work, &work->work) != napi_ok ||
      napi_queue_async_work(env, work->work) != napi_ok) {
    if (work->work != nullptr) {
      napi_delete_async_work(env, work->work);
    }
    delete work;
    napi_value msg = nullptr;
    napi_create_string_utf8(env, "probeProfiles: cannot queue work", NAPI_AUTO_LENGTH, &msg);
    napi_reject_deferred(env, deferred, msg);
  }
  return promise;
}

// Live connection inventory of the running core: one JSON document with
// {schemaVersion, revision, connections:[{id,state,inboundTag,outboundTag,
// network,addressType,address,port,startedUnixMs}]}.
napi_value ConnectionSnapshot(napi_env env, napi_callback_info info) {
  std::shared_lock<std::shared_mutex> guard(g_mutex);
  if (g_core == nullptr) {
    return Throw(env, "connectionSnapshot: core is not running");
  }
  // The document grows while connections come and go, and the call needs room
  // for a trailing NUL, so keep a margin and retry when the snapshot grew
  // between the sizing call and the copy.
  size_t needed = 0;
  XrayError *err = nullptr;
  if (xray_core_connection_snapshot_json(g_core, nullptr, 0, &needed, &err) != XRAY_STATUS_OK) {
    return Throw(env, "connectionSnapshot failed: " + TakeError(&err, "snapshot error"));
  }
  std::string json;
  for (int attempt = 0; attempt < 4; ++attempt) {
    const size_t capacity = needed + 256;
    json.assign(capacity, '\0');
    size_t written = 0;
    err = nullptr;
    XrayStatus status = xray_core_connection_snapshot_json(g_core, json.data(), capacity, &written, &err);
    if (status == XRAY_STATUS_OK) {
      json.resize(written);
      napi_value result = nullptr;
      napi_create_string_utf8(env, json.c_str(), json.size(), &result);
      return result;
    }
    if (written > 0) {
      needed = written;
      continue;
    }
    return Throw(env, "connectionSnapshot failed: " + TakeError(&err, "snapshot error"));
  }
  return Throw(env, "connectionSnapshot failed: snapshot kept growing");
}

// Drops one entry of the live inventory by id.
napi_value CloseConnection(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 1) {
    return Throw(env, "closeConnection(connectionId)");
  }
  double raw = 0;
  if (napi_get_value_double(env, argv[0], &raw) != napi_ok || raw <= 0) {
    return Throw(env, "closeConnection: id must be a positive number");
  }
  std::unique_lock<std::shared_mutex> guard(g_mutex);
  if (g_core == nullptr) {
    return Throw(env, "closeConnection: core is not running");
  }
  XrayError *err = nullptr;
  if (xray_core_close_connection(g_core, static_cast<uint64_t>(raw), &err) != XRAY_STATUS_OK) {
    return Throw(env, "closeConnection failed: " + TakeError(&err, "close error"));
  }
  napi_value result = nullptr;
  napi_get_boolean(env, true, &result);
  return result;
}

// Swaps the routing table of the running core for new flows only. Used by the
// GFW / bypass / global mode switch: the outbound set stays identical, so the
// tunnel keeps running and nothing is re-dialed.
napi_value ReplaceRouting(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 1) {
    return Throw(env, "replaceRouting(routingJson)");
  }
  std::string json;
  if (!GetUtf8(env, argv[0], &json)) {
    return Throw(env, "replaceRouting: routing must be a string");
  }
  std::unique_lock<std::shared_mutex> guard(g_mutex);
  if (g_core == nullptr) {
    return Throw(env, "replaceRouting: core is not running");
  }
  XrayError *err = nullptr;
  if (xray_core_replace_routing_policy_json(g_core, json.c_str(), &err) != XRAY_STATUS_OK) {
    return Throw(env, "replaceRouting failed: " + TakeError(&err, "routing error"));
  }
  napi_value result = nullptr;
  napi_get_boolean(env, true, &result);
  return result;
}

// Network-change rebind for carriers that can move their UDP socket without a
// restart (Hysteria 2 and every other live QUIC carrier, plus WireGuard).
napi_value Rebind(napi_env env, napi_callback_info info) {
  std::unique_lock<std::shared_mutex> guard(g_mutex);
  uint64_t hysteriaAccepted = 0;
  uint64_t wireGuardAccepted = 0;
  if (g_core != nullptr) {
    XrayError *err = nullptr;
    if (xray_core_rebind_hysteria(g_core, &hysteriaAccepted, &err) != XRAY_STATUS_OK) {
      g_unhealthy = true;
    }
    TakeError(&err, "rebind hysteria failed");
    if (xray_core_rebind_wireguard(g_core, &wireGuardAccepted, &err) != XRAY_STATUS_OK) {
      g_unhealthy = true;
    }
    TakeError(&err, "rebind wireguard failed");
  }
  napi_value result = nullptr;
  napi_create_double(env, static_cast<double>(hysteriaAccepted + wireGuardAccepted), &result);
  return result;
}

}  // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"version", nullptr, Version, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"capabilities", nullptr, Capabilities, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"importProfile", nullptr, ImportProfile, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"restart", nullptr, Restart, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"isRunning", nullptr, IsRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"warnings", nullptr, Warnings, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"stats", nullptr, Stats, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"rebind", nullptr, Rebind, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"probe", nullptr, Probe, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"probeOutbound", nullptr, ProbeOutbound, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"probeProfiles", nullptr, ProbeProfiles, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"cancelProbes", nullptr, ProbeCancel, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"replaceRouting", nullptr, ReplaceRouting, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"connectionSnapshot", nullptr, ConnectionSnapshot, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"closeConnection", nullptr, CloseConnection, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}
EXTERN_C_END

static napi_module xrayModule = {
    1,
    0,
    nullptr,
    Init,
    // Must match the shared library name libentry.so minus the lib/.so parts.
    "entry",
    nullptr,
    {0},
};

extern "C" __attribute__((constructor)) void RegisterXrayModule(void) {
  napi_module_register(&xrayModule);
}

