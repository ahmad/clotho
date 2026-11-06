package main

/*
#cgo CFLAGS: -DCTN_GO_BUILD
#include <stdlib.h>
#include "clotho_tailnet.h"

static inline int ctn_call_store_read(ctn_store_read_fn f, void *ctx, const char *key, uint8_t **out, size_t *len) {
	return f(ctx, key, out, len);
}
static inline int ctn_call_store_write(ctn_store_write_fn f, void *ctx, const char *key, const uint8_t *data, size_t len) {
	return f(ctx, key, data, len);
}
*/
import "C"

import (
	"fmt"
	"sync"
	"unsafe"

	"tailscale.com/ipn"
)

// callbackStore is an ipn.StateStore over the caller's store_read and store_write (iOS keeps the
// node's state in the Keychain through them). The callbacks are valid until on_closed, so they're
// called under the node's cbMu read lock and refused once the background close is done.
type callbackStore struct {
	n     *node
	read  C.ctn_store_read_fn
	write C.ctn_store_write_fn
	mu    sync.Mutex // one store call at a time: the caller's store needn't be reentrant
}

func (s *callbackStore) ReadState(id ipn.StateKey) ([]byte, error) {
	s.n.cbMu.RLock()
	defer s.n.cbMu.RUnlock()
	if s.n.done {
		return nil, fmt.Errorf("reading %q: the node is closed", id)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	key := C.CString(string(id))
	defer C.free(unsafe.Pointer(key))
	var out *C.uint8_t
	var n C.size_t
	switch C.ctn_call_store_read(s.read, s.n.ctx, key, &out, &n) {
	case 0:
		if out == nil {
			return []byte{}, nil
		}
		b := C.GoBytes(unsafe.Pointer(out), C.int(n))
		C.free(unsafe.Pointer(out))
		return b, nil
	case 1:
		return nil, ipn.ErrStateNotExist
	default:
		return nil, fmt.Errorf("reading %q from the state store failed", id)
	}
}

func (s *callbackStore) WriteState(id ipn.StateKey, bs []byte) error {
	s.n.cbMu.RLock()
	defer s.n.cbMu.RUnlock()
	if s.n.done {
		return fmt.Errorf("writing %q: the node is closed", id)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	key := C.CString(string(id))
	defer C.free(unsafe.Pointer(key))
	var data *C.uint8_t
	if len(bs) > 0 {
		data = (*C.uint8_t)(C.CBytes(bs))
		defer C.free(unsafe.Pointer(data))
	}
	if C.ctn_call_store_write(s.write, s.n.ctx, key, data, C.size_t(len(bs))) != 0 {
		return fmt.Errorf("writing %q to the state store failed", id)
	}
	return nil
}
