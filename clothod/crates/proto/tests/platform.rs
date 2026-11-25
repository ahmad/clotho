//! Process groups and sessions as the daemon asks about them (who a pane's status ends with),
//! with real processes. A test binary of its own: these tests fork, and a forked child holds
//! every open file of the process until it execs, which the lock tests among the crate's unit
//! tests must not meet.

use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use clotho_proto::platform::*;

fn eventually(what: &str, cond: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !cond() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn sh(script: &str) -> Command {
    let mut c = Command::new("/bin/sh");
    c.arg("-c").arg(script).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    c
}

/// "Is anything but the leader itself running": in its own group, or anywhere in its session.
fn session_peer_running(leader: u32, own_group: bool) -> bool {
    prompt_peer_running(leader, leader, own_group, &[leader])
}

fn kill_group(pgrp: u32) {
    unsafe { libc::kill(-(pgrp as libc::pid_t), libc::SIGKILL) };
}

/// A group outlives its leader: it runs while any member does, and a member that has exited
/// and was not collected (a zombie) is not one.
#[test]
fn a_process_group_runs_while_any_member_does() {
    // The leader exits at once and leaves a member behind (as `true | worker` does).
    let mut leader = sh("sleep 30 & exit 0").process_group(0).spawn().unwrap();
    let g = leader.id();
    leader.wait().unwrap();
    assert!(!process_running(g), "the leader is gone");
    assert!(process_group_running(g), "its group is not: a member still runs");
    // Stopped is not exited.
    unsafe { libc::kill(-(g as libc::pid_t), libc::SIGSTOP) };
    std::thread::sleep(Duration::from_millis(100));
    assert!(process_group_running(g), "a stopped member is alive");
    kill_group(g);
    eventually("the group to end", || !process_group_running(g));

    // A leader that exited and was not collected: nothing runs in its group.
    let mut z = sh("exit 0").process_group(0).spawn().unwrap();
    eventually("the zombie", || !process_running(z.id()));
    assert!(process_alive(z.id()), "still there to be collected");
    assert!(!process_group_running(z.id()));
    z.wait().unwrap();
    assert!(!process_group_running(z.id()));
    assert!(!process_group_running(0));

    // A live leader is the cheap case.
    let mut l = sh("exec sleep 30").process_group(0).spawn().unwrap();
    assert!(process_group_running(l.id()));
    kill_group(l.id());
    l.wait().unwrap();
    assert!(!process_group_running(l.id()));
}

/// "Is anything but the pane's own process running in the pane": in its own group, or in any
/// group of the session it leads.
#[test]
fn a_session_leaders_peers_are_found_in_its_group_and_its_session() {
    let session = |script: &str| {
        let mut c = sh(script);
        unsafe { c.pre_exec(|| if libc::setsid() < 0 { Err(std::io::Error::last_os_error()) } else { Ok(()) }) };
        c.spawn().unwrap()
    };
    // Alone: the leader itself is the sleeper.
    let mut alone = session("exec sleep 30");
    let l = alone.id();
    assert_eq!(unsafe { libc::getsid(l as libc::pid_t) }, l as libc::pid_t, "it leads its session");
    assert!(!session_peer_running(l, true) && !session_peer_running(l, false), "the leader itself is no peer");
    unsafe { libc::kill(l as libc::pid_t, libc::SIGKILL) };
    alone.wait().unwrap();

    // A child in the leader's own group.
    let mut own = session("sleep 30 & wait");
    let l = own.id();
    eventually("a peer in its group", || session_peer_running(l, true));
    assert!(session_peer_running(l, false), "its group is part of its session");
    kill_group(l);
    own.wait().unwrap();
    eventually("no peer left", || !session_peer_running(l, true) && !session_peer_running(l, false));

    // A child in a group of its own (a background job of a shell with job control).
    if Command::new("perl").arg("-e").arg("1").status().is_ok_and(|s| s.success()) {
        let mut job = session("perl -e 'setpgrp(0, 0); sleep 30' & wait");
        let l = job.id();
        eventually("a peer in its session only", || session_peer_running(l, false) && !session_peer_running(l, true));
        // The leader and its job, each in its own group.
        for p in own_processes().into_iter().filter(|p| unsafe { libc::getsid(p.pid as libc::pid_t) } == l as libc::pid_t) {
            unsafe { libc::kill(p.pid as libc::pid_t, libc::SIGKILL) };
        }
        job.wait().unwrap();
        eventually("no peer left", || !session_peer_running(l, false));
    }
}

/// A forked copy of a shell (a subshell) is told from a shell that was started: only the second
/// has called exec. Its argv reads the same.
#[test]
fn a_forked_copy_is_told_from_a_started_program() {
    let dir = std::env::temp_dir().join(format!("clotho-proto-exec-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let (pidfile, fifo) = (dir.join("sub"), dir.join("fifo"));
    assert!(Command::new("mkfifo").arg(&fifo).status().unwrap().success());
    // The shell forks a subshell, which says who it is and then waits in a builtin (opening a
    // fifo nobody writes to): it never execs.
    let mut shell = sh(&format!("( sh -c 'echo $PPID' > '{}'; read x < '{}' ) & wait", pidfile.display(), fifo.display())).process_group(0).spawn().unwrap();
    let g = shell.id();
    assert_eq!(process_execed(g), Some(true), "a spawned program has called exec");
    assert_eq!(process_execed(std::process::id()), Some(true), "and so has this one");
    let read_pid = || std::fs::read_to_string(&pidfile).ok().and_then(|s| s.trim().parse::<u32>().ok());
    eventually("the subshell's pid", || read_pid().is_some());
    let sub = read_pid().unwrap();
    assert_ne!(sub, g, "the subshell is a process of its own");
    assert_eq!(process_execed(sub), Some(false), "a subshell is a copy that never called exec");
    assert_eq!(process_args(sub), process_args(g), "with its parent's argv");
    assert_eq!(process_args(g).first().map(String::as_str), Some("/bin/sh"));
    kill_group(g);
    shell.wait().unwrap();
    eventually("the subshell to end", || !process_running(sub));
    std::fs::remove_dir_all(&dir).ok();
}

/// The session listing leaves out every process it is told to (a shell at its prompt, and the
/// processes that wait for it).
#[test]
fn the_waiting_processes_are_no_peers() {
    let mut c = sh("sleep 30 & wait");
    unsafe { c.pre_exec(|| if libc::setsid() < 0 { Err(std::io::Error::last_os_error()) } else { Ok(()) }) };
    let mut leader = c.spawn().unwrap();
    let l = leader.id();
    eventually("a peer", || prompt_peer_running(l, l, false, &[l]));
    let child = own_processes().into_iter().find(|p| p.pid != l && unsafe { libc::getsid(p.pid as libc::pid_t) } == l as libc::pid_t).expect("the sleeper").pid;
    assert!(!prompt_peer_running(l, l, false, &[l, child]), "left out, nothing else runs");
    assert!(prompt_peer_running(l, child, false, &[child]), "the leader counts when it is not left out");
    kill_group(l);
    leader.wait().unwrap();
}
