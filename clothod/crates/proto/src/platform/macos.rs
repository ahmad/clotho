use std::path::PathBuf;

/// The per-user temp dir (`/var/folders/.../T/`). Asked from the system rather than read from
/// `$TMPDIR`, which non-interactive SSH sessions may not set: every way of starting clothod
/// must agree on the socket path.
pub fn runtime_base() -> Option<PathBuf> {
    let mut buf = vec![0u8; 1024];
    let n = unsafe { libc::confstr(libc::_CS_DARWIN_USER_TEMP_DIR, buf.as_mut_ptr().cast(), buf.len()) };
    if n == 0 || n > buf.len() {
        return super::env_dir("TMPDIR");
    }
    buf.truncate(n - 1);
    Some(PathBuf::from(String::from_utf8_lossy(&buf).into_owned()))
}

pub fn state_base() -> PathBuf {
    super::default_home().join("Library/Application Support")
}

pub fn process_cwd(pid: u32) -> Option<PathBuf> {
    use std::ffi::CStr;
    let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_vnodepathinfo>() as libc::c_int;
    let n = unsafe {
        libc::proc_pidinfo(
            pid as libc::c_int,
            libc::PROC_PIDVNODEPATHINFO,
            0,
            (&mut info as *mut libc::proc_vnodepathinfo).cast(),
            size,
        )
    };
    if n != size {
        return None;
    }
    let path = unsafe { CStr::from_ptr(info.pvi_cdir.vip_path.as_ptr().cast()) };
    let path = path.to_str().ok()?;
    (!path.is_empty()).then(|| PathBuf::from(path))
}

pub fn peer_uid(fd: std::os::fd::RawFd) -> Option<u32> {
    let mut uid: libc::uid_t = 0;
    let mut gid: libc::gid_t = 0;
    let rc = unsafe { libc::getpeereid(fd, &mut uid, &mut gid) };
    (rc == 0).then_some(uid)
}

pub fn data_base() -> PathBuf {
    state_base()
}

pub fn process_exe(pid: u32) -> Option<PathBuf> {
    let mut buf = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    let n = unsafe { libc::proc_pidpath(pid as libc::c_int, buf.as_mut_ptr().cast(), buf.len() as u32) };
    if n <= 0 {
        return None;
    }
    buf.truncate(n as usize);
    Some(PathBuf::from(String::from_utf8_lossy(&buf).into_owned()))
}

pub fn kill_user_processes() -> Option<bool> {
    Some(false)
}

pub fn have_systemd_run() -> bool {
    false
}

pub fn linger() -> Option<bool> {
    None
}

fn bsdinfo(pid: u32) -> Option<libc::proc_bsdinfo> {
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    let n = unsafe { libc::proc_pidinfo(pid as libc::c_int, libc::PROC_PIDTBSDINFO, 0, (&mut info as *mut libc::proc_bsdinfo).cast(), size) };
    (n == size).then_some(info)
}

/// The terminal's foreground process group (`e_tpgid`).
pub fn terminal_pgrp(pid: u32) -> Option<u32> {
    let info = bsdinfo(pid)?;
    (info.e_tpgid > 0).then_some(info.e_tpgid)
}

pub fn process_name(pid: u32) -> Option<String> {
    let info = bsdinfo(pid)?;
    let name = unsafe { std::ffi::CStr::from_ptr(info.pbi_name.as_ptr()) }.to_string_lossy().into_owned();
    let name = if name.is_empty() { unsafe { std::ffi::CStr::from_ptr(info.pbi_comm.as_ptr()) }.to_string_lossy().into_owned() } else { name };
    (!name.is_empty()).then_some(name)
}

/// argv via sysctl KERN_PROCARGS2: int argc, exec path, NUL padding, then argv strings.
pub fn process_args(pid: u32) -> Vec<String> {
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid as libc::c_int];
    let mut size: libc::size_t = 0;
    unsafe {
        if libc::sysctl(mib.as_mut_ptr(), 3, std::ptr::null_mut(), &mut size, std::ptr::null_mut(), 0) != 0 || size < 4 {
            return Vec::new();
        }
    }
    let mut buf = vec![0u8; size];
    unsafe {
        if libc::sysctl(mib.as_mut_ptr(), 3, buf.as_mut_ptr().cast(), &mut size, std::ptr::null_mut(), 0) != 0 {
            return Vec::new();
        }
    }
    buf.truncate(size);
    let argc = i32::from_ne_bytes(buf[..4].try_into().unwrap()).max(0) as usize;
    let mut rest = &buf[4..];
    // Skip the exec path and the padding after it.
    let Some(end) = rest.iter().position(|&b| b == 0) else { return Vec::new() };
    rest = &rest[end..];
    let start = rest.iter().position(|&b| b != 0).unwrap_or(rest.len());
    rest = &rest[start..];
    rest.split(|&b| b == 0).take(argc).map(|a| String::from_utf8_lossy(a).into_owned()).collect()
}

pub fn parent_pid(pid: u32) -> Option<u32> {
    bsdinfo(pid).map(|i| i.pbi_ppid)
}

pub fn own_processes(uid: u32) -> Vec<super::ProcInfo> {
    let n = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
    if n <= 0 {
        return Vec::new();
    }
    let mut pids = vec![0 as libc::pid_t; n as usize + 64];
    let bytes = (pids.len() * std::mem::size_of::<libc::pid_t>()) as libc::c_int;
    let n = unsafe { libc::proc_listallpids(pids.as_mut_ptr().cast(), bytes) };
    pids.truncate(n.max(0) as usize);
    pids.into_iter()
        .filter(|&p| p > 0)
        .filter_map(|p| {
            let pid = p as u32;
            let info = bsdinfo(pid)?;
            if info.pbi_uid != uid {
                return None;
            }
            Some(super::ProcInfo { pid, exe: process_exe(pid), args: process_args(pid), started: Some(info.pbi_start_tvsec) })
        })
        .collect()
}
