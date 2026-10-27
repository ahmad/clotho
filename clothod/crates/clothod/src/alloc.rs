//! The global allocator, counting live heap bytes so `debug.stats` can tell memory the program
//! holds from memory the allocator keeps after it was freed.

use std::alloc::{GlobalAlloc, Layout};
use std::sync::atomic::{AtomicUsize, Ordering};

/// Linux: mimalloc. musl's malloc, under the churn of a busy daemon (64 KiB output frames, VT
/// rows), kept gigabytes of anonymous mappings while the live heap stayed ~165 MB (soak: 24 GB
/// RSS in an hour). macOS: the system allocator, which measured fine.
#[cfg(target_os = "linux")]
pub type Inner = mimalloc::MiMalloc;
#[cfg(not(target_os = "linux"))]
pub type Inner = std::alloc::System;

#[cfg(target_os = "linux")]
pub const INNER: Inner = mimalloc::MiMalloc;
#[cfg(not(target_os = "linux"))]
pub const INNER: Inner = std::alloc::System;

/// Make mimalloc return freed memory promptly. Measured on 40 panes: with its defaults the holder
/// kept ~2 MB a pane (vs 0.25 with musl); with these, 0.28 MB, and serve 5.1 MB vs musl's 6.6.
/// Call first thing in main. The option numbers are mimalloc v3's (`mimalloc.h`, `mi_option_e`;
/// libmimalloc-sys builds v3 unless its `v2` feature is on), which the bindings don't name.
pub fn tune() {
    #[cfg(target_os = "linux")]
    unsafe {
        const ARENA_EAGER_COMMIT: libmimalloc_sys::mi_option_t = 4;
        const PURGE_DELAY: libmimalloc_sys::mi_option_t = 15;
        libmimalloc_sys::mi_option_set(ARENA_EAGER_COMMIT, 0);
        libmimalloc_sys::mi_option_set(PURGE_DELAY, 0);
    }
}

pub struct Counting(pub Inner);

static LIVE: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);

fn grew(n: usize) {
    let live = LIVE.fetch_add(n, Ordering::Relaxed) + n;
    if live > PEAK.load(Ordering::Relaxed) {
        PEAK.fetch_max(live, Ordering::Relaxed);
    }
}

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        let p = unsafe { self.0.alloc(l) };
        if !p.is_null() {
            grew(l.size());
        }
        p
    }
    unsafe fn alloc_zeroed(&self, l: Layout) -> *mut u8 {
        let p = unsafe { self.0.alloc_zeroed(l) };
        if !p.is_null() {
            grew(l.size());
        }
        p
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        LIVE.fetch_sub(l.size(), Ordering::Relaxed);
        unsafe { self.0.dealloc(p, l) }
    }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, new: usize) -> *mut u8 {
        let q = unsafe { self.0.realloc(p, l, new) };
        if !q.is_null() {
            if new >= l.size() {
                grew(new - l.size());
            } else {
                LIVE.fetch_sub(l.size() - new, Ordering::Relaxed);
            }
        }
        q
    }
}

/// Bytes currently allocated, and the most ever allocated at once.
pub fn heap() -> (usize, usize) {
    (LIVE.load(Ordering::Relaxed), PEAK.load(Ordering::Relaxed))
}
