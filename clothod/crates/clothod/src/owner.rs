//! Who a pane-bound status or progress ends with: the one place that decides it.
//!
//! A status that ends with its program (`running`, `starting`, an OSC 7501 `blocked` or `idle`,
//! a status the user has seen) and every progress has an **owner**, and lasts exactly as long
//! as the owner does. The rule:
//!
//! 1. **The owner is a process group, never a process.** It is alive while any process in it
//!    is there and not a zombie (`platform::process_group_running`); a stopped job (Ctrl-Z) is
//!    alive. The group's leader may exit first (`true | worker`): that ends nothing.
//! 2. **Which group** (`resolve`, when the report arrives):
//!    - a `clothod report`: the pane's foreground job when the reporter is part of it (in its
//!      group, or started by its leader), else the reporter's own group (`deploy.sh &`);
//!    - output (an OSC sequence), or an `agent.report` without a `pid`: the pane's foreground
//!      job. Output does not say who wrote it: with no job in the foreground, a report that
//!      updates a status keeps that status's owner, and a new one has none (`Unknown`).
//! 3. **The pane's own process group is never an owner.** The pane's first process (its
//!    shell) lives as long as the pane, so a status it owned would never end. A reporter that
//!    ran in that group (command substitution, a prompt hook, a script that is the pane's
//!    command) leaves the status without one (`Pane`).
//! 4. **Without an owner** (`Pane`, `Unknown`), at each look (`still_owned`, once a second):
//!    - a job is in the foreground: it takes the status (a shell that reports before it starts
//!      the command has that command as its program);
//!    - else, in a pane whose own process is not a shell (the pane runs the program directly),
//!      that program reported: the status lasts until the pane closes;
//!    - else the shell is at its prompt. The status lasts while something else that could
//!      have reported still runs: for `Pane`, another process in the shell's own group (the
//!      rest of that command substitution or script); for `Unknown`, another process anywhere
//!      in the pane's session (a background job that prints: nothing says which one wrote).
//!      At the second look in a row that finds nothing, it is removed: one to two seconds
//!      after the report, or after the last such process exited.
//!
//! A process that left the pane's session (`setsid`) is not the pane's: its `clothod report` is
//! refused (`wrong_pane`), and what it prints has no owner.

use clotho_proto::platform;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Owner {
    /// This process group. Never the pane's own.
    Group(u32),
    /// None: the reporter ran in the pane's own process group.
    Pane,
    /// None: nothing says who reported (output with no job in the foreground).
    #[default]
    Unknown,
}

impl Owner {
    /// As an agent stores it (`pid`, and whether the reporter ran in the pane's own group).
    pub fn from_parts(group: Option<u32>, in_pane_group: bool) -> Owner {
        match group {
            Some(g) => Owner::Group(g),
            None if in_pane_group => Owner::Pane,
            None => Owner::Unknown,
        }
    }

    pub fn group(self) -> Option<u32> {
        match self {
            Owner::Group(g) => Some(g),
            _ => None,
        }
    }
}

/// The job in the foreground of the pane's terminal: its process group, when that is not the
/// pane's own (`pane` is the pane's first process, which leads its session and its group).
pub fn foreground_job(pane: u32) -> Option<u32> {
    platform::foreground_group(pane).filter(|g| *g != pane)
}

fn is_shell(pane: u32) -> bool {
    crate::layout::is_shell(&platform::process_names(pane))
}

/// The owner of what was just reported in the pane (rule 2 and 3). `reporter` is the process
/// that ran `clothod report` (it is still there: it waits for the answer); None for output and
/// for a report that names no process. `existing` is the owner of the status or progress this
/// report updates, if there is one.
pub fn resolve(pane: u32, reporter: Option<u32>, existing: Option<Owner>) -> Owner {
    let fg = foreground_job(pane);
    let Some(r) = reporter else {
        return fg.map(Owner::Group).or(existing).unwrap_or(Owner::Unknown);
    };
    let job = platform::process_group(r);
    match (fg, job) {
        (Some(f), _) if job == Some(f) || platform::ancestors(r, pane).contains(&f) => Owner::Group(f),
        (_, Some(j)) if j != pane => Owner::Group(j),
        (_, Some(_)) => Owner::Pane,
        (Some(f), None) => Owner::Group(f),
        (None, None) => existing.unwrap_or(Owner::Unknown),
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Look {
    Alive,
    /// It had no owner, and this job is in the foreground now.
    Taken(u32),
    /// It has no owner, and nothing that could have reported it runs.
    Idle,
    Gone,
}

fn look(pane: u32, owner: Owner) -> Look {
    // The pane's own group is never an owner, wherever the value came from (a stored one).
    let owner = if owner == Owner::Group(pane) { Owner::Pane } else { owner };
    if let Owner::Group(g) = owner {
        return if platform::process_group_running(g) { Look::Alive } else { Look::Gone };
    }
    if let Some(job) = foreground_job(pane) {
        return Look::Taken(job);
    }
    if !is_shell(pane) || platform::session_peer_running(pane, owner == Owner::Pane) {
        return Look::Alive;
    }
    Look::Idle
}

/// One look at a status's or progress's owner (rule 1 and 4), once a second and only for panes
/// that have one. `idle` counts the looks in a row that found nothing to own it. False: it has
/// ended. A job that takes it becomes `owner`.
pub fn still_owned(pane: u32, owner: &mut Owner, idle: &mut u8) -> bool {
    match look(pane, *owner) {
        Look::Alive => *idle = 0,
        Look::Taken(job) => {
            *owner = Owner::Group(job);
            *idle = 0;
        }
        Look::Idle => {
            *idle += 1;
            if *idle >= 2 {
                *idle = 0;
                return false;
            }
        }
        Look::Gone => {
            *idle = 0;
            return false;
        }
    }
    true
}

/// Whether the owner is known and running right now: a live process group, or the pane's own
/// program in a pane that runs it directly. What `agent.ack` asks: a seen status stays listed
/// only while that holds.
pub fn known_alive(pane: u32, owner: Owner) -> bool {
    match owner {
        Owner::Group(g) if g != pane => platform::process_group_running(g),
        _ => !is_shell(pane),
    }
}
