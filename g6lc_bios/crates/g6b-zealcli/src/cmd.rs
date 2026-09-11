// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! The command table.
//!
//! One table drives dispatch, `help`, and the generated manual, so the three can
//! never disagree about what this image can do. Each entry carries the compile
//! gate it needs: a command whose capability was excluded is reported as
//! *compiled out* — never as "unknown", which would send an operator looking for
//! a typo that is not there. Names are bash-shaped with the ZealOS spelling
//! beside them (`ls`/`Dir`, `cat`/`Type`, `rm`/`Del`).

use g6b_spec::BoardSpec;

/// What a command needs to have been compiled.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Gate {
    /// Always available.
    Always,
    Manual,
    Vi,
    /// Volume exploration.
    Fs,
    /// Firmware update.
    Fw,
    /// Settings export/import.
    Settings,
    /// The web stack is compiled (so there is a UI to hand over to).
    Web,
    /// Network adapter status.
    Net,
    /// The countdown boot picker.
    Autoboot,
}

impl Gate {
    pub fn compiled(self, spec: &BoardSpec) -> bool {
        let c = &spec.kernel.cli;
        match self {
            Self::Always => true,
            Self::Manual => c.manual,
            Self::Vi => c.vi,
            Self::Fs => c.fs,
            Self::Fw => c.fw,
            Self::Settings => spec.kernel.settings.enable,
            Self::Web => spec.web_stack(),
            Self::Net => spec.kernel.hw.enable,
            Self::Autoboot => c.autoboot.enable,
        }
    }

    /// Why it is missing, in BoardSpec terms the operator can act on.
    pub fn because(self) -> &'static str {
        match self {
            Self::Always => "",
            Self::Manual => "kernel.cli.manual",
            Self::Vi => "kernel.cli.vi",
            Self::Fs => "kernel.cli.fs",
            Self::Fw => "kernel.cli.fw",
            Self::Settings => "kernel.settings.enable",
            Self::Web => "kernel.web.enable",
            Self::Net => "kernel.hw.enable",
            Self::Autoboot => "kernel.cli.autoboot.enable",
        }
    }
}

/// One command.
#[derive(Debug, Clone, Copy)]
pub struct Command {
    pub name: &'static str,
    pub aliases: &'static [&'static str],
    pub usage: &'static str,
    pub help: &'static str,
    pub gate: Gate,
}

/// The table. Order is the order `help` and `man COMMANDS` print.
pub const COMMANDS: &[Command] = &[
    Command {
        name: "help",
        aliases: &["Help", "?"],
        usage: "help [command]",
        help: "commands this image compiled",
        gate: Gate::Always,
    },
    Command {
        name: "man",
        aliases: &["Man"],
        usage: "man [section]",
        help: "printed manual for this board",
        gate: Gate::Manual,
    },
    Command {
        name: "clear",
        aliases: &["cls", "Cls"],
        usage: "clear",
        help: "empty the container",
        gate: Gate::Always,
    },
    Command {
        name: "scroll",
        aliases: &[],
        usage: "scroll up|down|top|tail",
        help: "move the viewport (PgUp/PgDn do the same)",
        gate: Gate::Always,
    },
    Command {
        name: "pwd",
        aliases: &["Cwd"],
        usage: "pwd",
        help: "current location",
        gate: Gate::Always,
    },
    Command {
        name: "ls",
        aliases: &["dir", "Dir"],
        usage: "ls [path]",
        help: "list a directory or drive",
        gate: Gate::Always,
    },
    Command {
        name: "cd",
        aliases: &["Cd"],
        usage: "cd path|DRIVE:/path|..",
        help: "change location",
        gate: Gate::Always,
    },
    Command {
        name: "cat",
        aliases: &["type", "Type"],
        usage: "cat file",
        help: "print a file",
        gate: Gate::Always,
    },
    Command {
        name: "vi",
        aliases: &["view", "Vi", "Ed"],
        usage: "vi file",
        help: "read-only viewer (:q to close)",
        gate: Gate::Vi,
    },
    Command {
        name: "write",
        aliases: &["Write"],
        usage: "write file text",
        help: "write a BIOS-local file (not a volume)",
        gate: Gate::Always,
    },
    Command {
        name: "rm",
        aliases: &["del", "Del"],
        usage: "rm file",
        help: "delete a BIOS-local file",
        gate: Gate::Always,
    },
    Command {
        name: "cp",
        aliases: &["Copy"],
        usage: "cp src dst",
        help: "copy a BIOS-local file",
        gate: Gate::Always,
    },
    Command {
        name: "mv",
        aliases: &["Move"],
        usage: "mv src dst",
        help: "rename a BIOS-local file",
        gate: Gate::Always,
    },
    Command {
        name: "mkdir",
        aliases: &["DirMk"],
        usage: "mkdir name",
        help: "make a BIOS-local directory",
        gate: Gate::Always,
    },
    Command {
        name: "echo",
        aliases: &[],
        usage: "echo text",
        help: "print text",
        gate: Gate::Always,
    },
    Command {
        name: "drv",
        aliases: &["Drv", "drives", "vol"],
        usage: "drv",
        help: "drives, partitions and mounts (USB key included)",
        gate: Gate::Fs,
    },
    Command {
        name: "menu",
        aliases: &["Menu"],
        usage: "menu [id]",
        help: "setup screen (main cpu memory uncore devices boot settings)",
        gate: Gate::Always,
    },
    Command {
        name: "set",
        aliases: &["Set"],
        usage: "set [name value]",
        help: "write a setting (no args lists the writable rows)",
        gate: Gate::Always,
    },
    Command {
        name: "get",
        aliases: &["Get"],
        usage: "get name",
        help: "value of a setting row",
        gate: Gate::Always,
    },
    Command {
        name: "save",
        aliases: &["export", "SettingsExport"],
        usage: "save [uart|mailbox|usb]",
        help: "export pending settings as a BoardSpec patch",
        gate: Gate::Settings,
    },
    Command {
        name: "load",
        aliases: &["import", "SettingsImport"],
        usage: "load [uart|mailbox|usb]",
        help: "import settings",
        gate: Gate::Settings,
    },
    Command {
        name: "boot",
        aliases: &["Boot"],
        usage: "boot [id]",
        help: "next-stage selector (opensbi / edk2 / u-boot on a volume)",
        gate: Gate::Always,
    },
    Command {
        name: "mount",
        aliases: &["Mount"],
        usage: "mount [-w] [<drive>[:<part>]] [as <name>]",
        help: "mount a real volume (no args lists mounts)",
        gate: Gate::Fs,
    },
    Command {
        name: "umount",
        aliases: &["Umount", "unmount"],
        usage: "umount <name>",
        help: "release a mount",
        gate: Gate::Fs,
    },
    Command {
        name: "autoboot",
        aliases: &["AutoBoot"],
        usage: "autoboot [now|id]",
        help: "countdown boot picker (arrows wrap, Enter boots, Esc stays)",
        gate: Gate::Autoboot,
    },
    Command {
        name: "fw",
        aliases: &["Fw"],
        usage: "fw [update SRC|apply|cancel]",
        help: "firmware update from https:// or DRIVE:/image",
        gate: Gate::Fw,
    },
    Command {
        name: "net",
        aliases: &["Net"],
        usage: "net",
        help: "network adapter status",
        gate: Gate::Net,
    },
    Command {
        name: "loadui",
        aliases: &["LoadUI", "ui"],
        usage: "loadui",
        help: "hand the screen to browser-ui",
        gate: Gate::Web,
    },
    Command {
        name: "holyc",
        aliases: &[],
        usage: "holyc STMT",
        help: "run a HolyC statement (bare builtins work too)",
        gate: Gate::Always,
    },
    Command {
        name: "reboot",
        aliases: &["Reboot"],
        usage: "reboot",
        help: "SBI system reset",
        gate: Gate::Always,
    },
    Command {
        name: "shutdown",
        aliases: &["Shutdown"],
        usage: "shutdown",
        help: "SBI shutdown",
        gate: Gate::Always,
    },
    Command {
        name: "wakeup",
        aliases: &["Wakeup"],
        usage: "wakeup",
        help: "wake the always-on domain",
        gate: Gate::Always,
    },
    Command {
        name: "linux",
        aliases: &["LinuxHandoff"],
        usage: "linux",
        help: "hand off to the OS payload",
        gate: Gate::Always,
    },
    Command {
        name: "exit",
        aliases: &["Exit", "quit"],
        usage: "exit",
        help: "leave the CLI",
        gate: Gate::Always,
    },
];

impl Command {
    /// Commands this image actually carries.
    pub fn compiled(spec: &BoardSpec) -> Vec<&'static Command> {
        COMMANDS.iter().filter(|c| c.gate.compiled(spec)).collect()
    }

    /// Table lookup by name or alias, regardless of gate.
    pub fn find(word: &str) -> Option<&'static Command> {
        COMMANDS
            .iter()
            .find(|c| c.name == word || c.aliases.iter().any(|a| *a == word))
            .or_else(|| {
                let lower = word.to_ascii_lowercase();
                COMMANDS.iter().find(|c| {
                    c.name == lower || c.aliases.iter().any(|a| a.eq_ignore_ascii_case(word))
                })
            })
    }

    /// One `help` row.
    pub fn row(&self) -> String {
        let mut names = String::from(self.name);
        for a in self.aliases {
            names.push('/');
            names.push_str(a);
        }
        format!("{names:<28} {}", self.help)
    }
}

/// `help` text: compiled commands plus the registered HolyC builtins.
pub fn help_text(spec: &BoardSpec) -> String {
    // ASCII only: this text is also packed into the guest payload as the `help`
    // page and blitted by an 8x8 glyph face that has no em dash.
    let mut s = format!(
        "zealcli - {}x{} container, prompt at the bottom{}.\n",
        spec.kernel.cli.cols,
        spec.kernel.cli.rows,
        if spec.kernel.cli.mouse {
            ", mouse on"
        } else {
            ", no mouse"
        }
    );
    for c in Command::compiled(spec) {
        s.push_str(&c.row());
        s.push('\n');
    }
    let out: Vec<&'static Command> = COMMANDS.iter().filter(|c| !c.gate.compiled(spec)).collect();
    if !out.is_empty() {
        s.push_str("compiled out: ");
        for (i, c) in out.iter().enumerate() {
            if i > 0 {
                s.push_str(", ");
            }
            s.push_str(&format!("{} ({})", c.name, c.gate.because()));
        }
        s.push('\n');
    }
    s.push_str("HolyC builtins:\n");
    for (i, n) in g6b_holyc::HOLYC_BUILTIN_NAMES.iter().enumerate() {
        if i > 0 && i % 6 == 0 {
            s.push('\n');
        }
        s.push_str(n);
        s.push(' ');
    }
    s.push('\n');
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn table_is_the_single_source_of_truth() {
        let full = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let bare =
            BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"barebone"}"#).unwrap();
        // `loadui` only exists where there is a UI to load.
        assert!(Command::compiled(&full).iter().any(|c| c.name == "loadui"));
        assert!(!Command::compiled(&bare).iter().any(|c| c.name == "loadui"));
        // Barebone still carries the whole operator surface.
        for want in ["man", "vi", "drv", "fw", "set", "boot", "net"] {
            assert!(
                Command::compiled(&bare).iter().any(|c| c.name == want),
                "barebone should carry {want}"
            );
        }
        // Aliases resolve, including the ZealOS spellings.
        for (word, name) in [
            ("Dir", "ls"),
            ("Type", "cat"),
            ("Del", "rm"),
            ("Cls", "clear"),
            ("Drv", "drv"),
            ("LoadUI", "loadui"),
            ("SettingsExport", "save"),
        ] {
            assert_eq!(Command::find(word).unwrap().name, name, "{word}");
        }
        assert!(Command::find("nonsense").is_none());
    }

    #[test]
    fn help_names_what_is_missing_and_why() {
        let mut json = r#"{"schema_version":1,"profile":"barebone","kernel":{"cli":{"vi":false,"manual":false}}}"#.to_string();
        let spec = BoardSpec::from_json_str(&json).unwrap();
        let h = help_text(&spec);
        assert!(h.contains("compiled out:"), "{h}");
        assert!(h.contains("vi (kernel.cli.vi)"), "{h}");
        assert!(h.contains("man (kernel.cli.manual)"), "{h}");
        assert!(h.contains("no mouse"), "{h}");
        json = r#"{"schema_version":1,"profile":"full","kernel":{"cli":{"mouse":true}}}"#.into();
        let mouse = BoardSpec::from_json_str(&json).unwrap();
        assert!(help_text(&mouse).contains("mouse on"));
        for n in g6b_holyc::HOLYC_BUILTIN_NAMES {
            assert!(help_text(&spec).contains(n), "missing {n}");
        }
    }
}
