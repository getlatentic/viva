//! The slash commands, in one table.
//!
//! One table because three things need it -- the menu that appears when you
//! press `/`, the dispatcher that runs it, and `/help` -- and three copies of
//! a list is three chances for the menu to offer something the dispatcher
//! refuses. That has a particular sting here: refusing an unknown command is
//! the whole feature, so a menu that can offer one would be the feature
//! attacking itself.

#[derive(Debug, Clone, Copy)]
pub struct Command {
    pub name: &'static str,
    /// Other spellings that do the same thing. Not shown in the menu -- a list
    /// with three ways to leave in it is a list that hides the other verbs.
    pub aliases: &'static [&'static str],
    pub blurb: &'static str,
}

pub const COMMANDS: &[Command] = &[
    Command {
        name: "/find",
        aliases: &["/sessions"],
        blurb: "find any session, running or not",
    },
    Command {
        name: "/new",
        aliases: &[],
        blurb: "start a session in a new tab",
    },
    Command {
        name: "/close",
        aliases: &[],
        blurb: "close this tab; the session keeps running",
    },
    Command {
        name: "/refresh",
        aliases: &[],
        blurb: "re-read the session list",
    },
    Command {
        name: "/help",
        aliases: &["/?"],
        blurb: "list these",
    },
    Command {
        name: "/quit",
        aliases: &["/exit", "/detach", "/q"],
        blurb: "leave; the session keeps running",
    },
];

/// The command a line names, by its own name or any alias.
pub fn lookup(verb: &str) -> Option<&'static Command> {
    let verb = verb.to_ascii_lowercase();
    COMMANDS.iter().find(|command| {
        command.name == verb || command.aliases.iter().any(|alias| *alias == verb)
    })
}

/// The commands a partially typed line could still become.
///
/// Empty once the line has a space in it: by then the person is typing an
/// argument, and a menu over the top of that is in the way rather than in
/// help.
pub fn matching(input: &str) -> Vec<&'static Command> {
    if !input.starts_with('/') || input.contains(char::is_whitespace) {
        return Vec::new();
    }
    let typed = input.to_ascii_lowercase();
    COMMANDS
        .iter()
        .filter(|command| {
            command.name.starts_with(&typed)
                || command.aliases.iter().any(|alias| alias.starts_with(&typed))
        })
        .collect()
}

pub fn help() -> String {
    let width = COMMANDS.iter().map(|c| c.name.len()).max().unwrap_or(8);
    let mut text = String::new();
    for command in COMMANDS {
        text.push_str(&format!("{:width$}  {}", command.name, command.blurb, width = width));
        if !command.aliases.is_empty() {
            text.push_str(&format!("  ({})", command.aliases.join(" ")));
        }
        text.push('\n');
    }
    text.push_str(
        "\nkeys: tab switches, ctrl-n new, ctrl-w close, ctrl-p find,\n      \
arrows walk the list, pgup/pgdn scroll, ctrl-c stops a turn",
    );
    text
}
