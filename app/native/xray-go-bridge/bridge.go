package main

/*
#include <stdint.h>
#include <stdlib.h>

typedef int32_t (*way_socket_protect_cb)(int32_t fd, void *user_data);

static int32_t invoke_socket_protect(way_socket_protect_cb cb, int32_t fd, void *user_data) {
  if (cb == NULL) {
    return 1;
  }
  return cb(fd, user_data);
}
*/
import "C"

import (
	"bytes"
	"fmt"
	"sync"
	"syscall"
	"unsafe"

	"github.com/xtls/xray-core/core"
	_ "github.com/xtls/xray-core/main/distro/all"
	"github.com/xtls/xray-core/transport/internet"
)

// coreVersion is injected via -ldflags="-X main.coreVersion=..." in GitHub Actions.
var coreVersion = "unknown"

var (
	mu       sync.Mutex
	instance *core.Instance
	lastErr  string

	protectMu       sync.RWMutex
	protectCallback C.way_socket_protect_cb
	protectUserData unsafe.Pointer
)

func init() {
	// Register HarmonyOS VpnExtensionAbility socket protect hook so outbound
	// sockets created by XTLS/Xray-core bypass the TUN loop cleanly.
	internet.RegisterDialerController(func(network, address string, conn syscall.RawConn) error {
		protectMu.RLock()
		cb := protectCallback
		ud := protectUserData
		protectMu.RUnlock()
		if cb == nil {
			return nil
		}
		var protectErr error
		err := conn.Control(func(fd uintptr) {
			if C.invoke_socket_protect(cb, C.int32_t(fd), ud) == 0 {
				protectErr = fmt.Errorf("harmonyos socket protect rejected fd=%d", fd)
			}
		})
		if err != nil {
			return err
		}
		return protectErr
	})
}

//export xray_go_version
func xray_go_version() *C.char {
	return C.CString(coreVersion)
}

//export xray_go_last_error
func xray_go_last_error() *C.char {
	mu.Lock()
	defer mu.Unlock()
	return C.CString(lastErr)
}

//export xray_go_free_string
func xray_go_free_string(s *C.char) {
	if s != nil {
		C.free(unsafe.Pointer(s))
	}
}

//export xray_go_set_socket_protect
func xray_go_set_socket_protect(cb C.way_socket_protect_cb, userData unsafe.Pointer) {
	protectMu.Lock()
	protectCallback = cb
	protectUserData = userData
	protectMu.Unlock()
}

//export xray_go_start_json
func xray_go_start_json(configJSON *C.char) C.int32_t {
	mu.Lock()
	defer mu.Unlock()

	if instance != nil {
		_ = instance.Close()
		instance = nil
	}
	if configJSON == nil {
		lastErr = "empty config json"
		return 1
	}

	raw := C.GoString(configJSON)
	cfg, err := core.LoadConfig("json", bytes.NewReader([]byte(raw)))
	if err != nil {
		lastErr = "load config failed: " + err.Error()
		return 3
	}
	srv, err := core.New(cfg)
	if err != nil {
		lastErr = "create core failed: " + err.Error()
		return 5
	}
	if err := srv.Start(); err != nil {
		_ = srv.Close()
		lastErr = "start core failed: " + err.Error()
		return 5
	}

	instance = srv
	lastErr = ""
	return 0
}

//export xray_go_stop
func xray_go_stop() C.int32_t {
	mu.Lock()
	defer mu.Unlock()
	if instance != nil {
		if err := instance.Close(); err != nil {
			lastErr = "stop core failed: " + err.Error()
			instance = nil
			return 5
		}
		instance = nil
	}
	lastErr = ""
	return 0
}

func main() {}
