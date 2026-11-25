//! Who a pane-bound status or progress ends with: the one place that decides it.
//!
//! A status that ends with its program (`running`, `starting`, an OSC 7501 `blocked` or `idle`,
//! a status the user has seen) and every progress has an **owner**, and lasts exactly as long
//! as the owner does. The rule:
//!
//! 1. **The owner is a process group, never a process.** It is alive while any process in it
//!    is there and not a zombie (`platform::process_group_running`); a stopped job (Ctrl-Z) is
//!    alive. The group's leader may exit first (`true | worker`): that ends nothing.
//! 2. **An interactive shell is never an owner, and never a job** (`interactive_shell`): a
//!    process whose executable (or argv[0]) is a known shell, whose argv has no script operand
//!    and no `-c` (login and interactive flags are fine), and which was started as that (it
//!    called exec: a subshell is a forked copy with the same argv, and is a job). It sits at a
//!    prompt for as long as the user stays in it, so a status it owned would never end. That
//!    holds at any depth: the pane's own shell, a `bash` typed in it, a shell typed in that.
//!    The **foreground job** (`front`) is the terminal's foreground process group unless such
//!    a shell leads it; then the shell is at its prompt and there is no foreground job.
//! 3. **Which group** (`resolve`, when the report arrives):
//!    - a `clothod report`: the foreground job when the reporter is part of it (in its group,
//!      or started by its leader), else the reporter's own group (`deploy.sh &`);
//!    - output (an OSC sequence), or an `agent.report` without a `pid`: the foreground job.
//!      Output does not say who wrote it: with no foreground job, a report that updates a
//!      status keeps that status's owner, and a new one has none (`Unknown`);
//!    - a reporter whose group is the pane's own, or is led by an interactive shell (command
//!      substitution, a prompt hook, a script that is the pane's command), leaves the status
//!      without an owner (`Pane`).
//! 4. **Without an owner** (`Pane`, `Unknown`), at each look (`still_owned`, once a second):
//!    - there is a foreground job: it takes the status (a shell that reports before it starts
//!      the command has that command as its program);
//!    - else, the pane's first process is in the foreground and is not an interactive shell
//!      (a program, or a shell running a script or `-c`): the pane runs its program directly,
//!      that program reported, and the status lasts with it, until the pane closes. Nothing
//!      is asked of what the program does meanwhile (a script may wait in `read`);
//!    - else an interactive shell is at its prompt. The status lasts while something else that
//!      could have reported still runs: for `Pane`, another process in that shell's own group
//!      (the rest of that command substitution); for `Unknown`, a process anywhere in the
//!      pane's session other than that shell and the processes waiting for it (its parents,
//!      up to the pane's first process): a background job that prints, since nothing says
//!      which one wrote. At the second look in a row that finds nothing, it is removed: one
//!      to two seconds after the report, or after the last such process exited.
//!
//! When a process cannot be read (its argv on macOS when it runs as another user, anything
//! once it has exited), it is taken for a program, not for an interactive shell: a status may
//! then last as long as that process stays in the foreground, and is never removed while its
//! program runs.
//!
//! A process that left the pane's session (`setsid`) is not the pane's: its `clothod report` is
//! refused (`wrong_pane`), and what it prints has no owner.

use clotho_proto::platform;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Owner {
    /// This process group. Never the pane's own, nor one an interactive shell leads.
    Group(u32),
    /// None: the reporter ran in the pane's own process group, or in an interactive shell's.
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

/// Whether `args` (a shell's argv) starts a shell that reads its commands from the terminal:
/// no script operand, and no `-c`. Options that take a value are skipped with it where the
/// shells have them; a value of an option not known here reads as a script (a program).
fn reads_commands(args: &[String]) -> bool {
    /// Long options whose value is the next word.
    const VALUED: [&str; 6] = ["rcfile", "init-file", "init-command", "config", "env-config", "emulate"];
    let mut it = args.iter().skip(1);
    while let Some(a) = it.next() {
        if a == "--" || a == "-" {
            return it.next().is_none();
        }
        if let Some(long) = a.strip_prefix("--") {
            let name = long.split('=').next().unwrap_or(long);
            if name == "command" || name == "commands" {
                return false;
            }
            if !long.contains('=') && VALUED.contains(&name) {
                it.next();
            }
        } else if let Some(flags) = a.strip_prefix('-').or_else(|| a.strip_prefix('+')) {
            if flags.contains('c') {
                return false;
            }
            if flags.contains('s') {
                // Commands come from its input: what follows are parameters, not a script.
                return true;
            }
            // `-o option`, bash's `-O option`, fish's `-C command`.
            if flags.ends_with(['o', 'O', 'C']) {
                it.next();
            }
        } else {
            return false;
        }
    }
    true
}

/// Rule 2: whether `pid` is an interactive shell: its executable or argv[0] is a known shell,
/// its argv has no script operand and no `-c`, and it was started as that (not a subshell,
/// which is a forked copy with the same argv). False when its argv or that cannot be read
/// (it has exited; on macOS, it runs as another user): it then counts as a program, which
/// keeps a status rather than removing it.
pub fn interactive_shell(pid: u32) -> bool {
    let args = platform::process_args(pid);
    let Some(arg0) = args.first() else { return false };
    let exe = platform::process_exe(pid).map(|p| p.to_string_lossy().into_owned());
    let shell = |name: &String| crate::layout::is_shell(std::slice::from_ref(name));
    (exe.as_ref().is_some_and(shell) || shell(arg0)) && reads_commands(&args) && platform::process_execed(pid) == Some(true)
}

/// What is in the foreground of the pane's terminal (`pane` is the pane's first process, which
/// leads its session and its group).
#[derive(Debug, PartialEq, Eq)]
enum Front {
    /// A job: the foreground process group, which no interactive shell leads and which is not
    /// the pane's own.
    Job(u32),
    /// This interactive shell, at its prompt: the pane's own, or one started in it.
    Prompt(u32),
    /// The pane's own group, and its first process is not an interactive shell: the program
    /// the pane runs directly.
    Program,
}

fn front(pane: u32) -> Front {
    // A terminal that cannot be asked has the pane's own process in front.
    let fg = platform::foreground_group(pane).unwrap_or(pane);
    if interactive_shell(fg) {
        Front::Prompt(fg)
    } else if fg == pane {
        Front::Program
    } else {
        Front::Job(fg)
    }
}

/// The job in the foreground of the pane's terminal, if there is one (rule 2).
pub fn foreground_job(pane: u32) -> Option<u32> {
    match front(pane) {
        Front::Job(g) => Some(g),
        _ => None,
    }
}

/// Whether group `g` can never own anything: the pane's own, or led by an interactive shell.
fn ownerless_group(pane: u32, g: u32) -> bool {
    g == pane || interactive_shell(g)
}

/// The owner of what was just reported in the pane (rule 3). `reporter` is the process that
/// ran `clothod report` (it is still there: it waits for the answer); None for output and for
/// a report that names no process. `existing` is the owner of the status or progress this
/// report updates, if there is one.
pub fn resolve(pane: u32, reporter: Option<u32>, existing: Option<Owner>) -> Owner {
    let fg = foreground_job(pane);
    let Some(r) = reporter else {
        return fg.map(Owner::Group).or(existing).unwrap_or(Owner::Unknown);
    };
    let job = platform::process_group(r);
    match (fg, job) {
        (Some(f), _) if job == Some(f) || platform::ancestors(r, pane).contains(&f) => Owner::Group(f),
        (_, Some(j)) if !ownerless_group(pane, j) => Owner::Group(j),
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
    // Such a group is never an owner, wherever the value came from (a stored one, or a program
    // that has since become a shell with `exec`).
    let owner = match owner {
        Owner::Group(g) if ownerless_group(pane, g) => Owner::Pane,
        o => o,
    };
    if let Owner::Group(g) = owner {
        return if platform::process_group_running(g) { Look::Alive } else { Look::Gone };
    }
    match front(pane) {
        Front::Job(job) => Look::Taken(job),
        Front::Program => Look::Alive,
        Front::Prompt(shell) => {
            // The shell at its prompt, and whoever waits for it to return.
            let mut waiting = vec![shell, pane];
            waiting.extend(platform::ancestors(shell, pane));
            if platform::prompt_peer_running(pane, shell, owner == Owner::Pane, &waiting) {
                Look::Alive
            } else {
                Look::Idle
            }
        }
    }
}

/// One look at a status's or progress's owner (rules 1, 2 and 4), once a second and only for panes
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
        Owner::Group(g) if !ownerless_group(pane, g) => platform::process_group_running(g),
        _ => front(pane) == Front::Program,
    }
}

#[cfg(test)]
mod tests {
    use super::reads_commands;

    fn argv(line: &str) -> Vec<String> {
        line.split(' ').map(String::from).collect()
    }

    #[test]
    fn an_interactive_shells_argv_has_no_script_and_no_command() {
        for line in ["bash", "-bash", "-zsh", "/bin/sh", "bash --norc --noprofile", "zsh -f", "zsh -il", "bash --login -i", "sh -i", "bash --rcfile /tmp/rc", "bash --rcfile=/tmp/rc -i", "bash -O extglob", "zsh -o extendedglob -i", "bash +O nullglob", "fish -C echo", "fish --init-command echo -i", "bash -s a b", "bash --", "sh -", "tcsh -l", "nu --config /x/config.nu"] {
            assert!(reads_commands(&argv(line)), "{line}");
        }
        for line in ["sh /x/run.sh", "/bin/sh /x/run.sh arg", "bash -e /x/run.sh", "bash -c true", "sh -ec true", "zsh -f -c true", "bash -lc true", "bash -ic true", "bash --norc /x/run.sh", "bash -- /x/run.sh", "sh - /x/run.sh", "bash -o pipefail /x/run.sh", "fish --command=true", "fish -c true", "nu --commands true", "nu script.nu", "bash --rcfile /tmp/rc /x/run.sh"] {
            assert!(!reads_commands(&argv(line)), "{line}");
        }
    }
}
