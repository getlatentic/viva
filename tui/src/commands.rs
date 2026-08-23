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
        aliases: &[],
        blurb: "find any session, running or not",
    },
    Command {
        name: "/sessions",
        aliases: &["/sidebar"],
        blurb: "show or hide the list of running sessions",
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
        name: "/learned",
        aliases: &["/knows"],
        blurb: "what this session has retained: notes, skills, tools",
    },
    Command {
        name: "/shell",
        aliases: &["/!"],
        blurb: "a line starting with ! runs here; the model does not see it",
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

/// Is this line a command, or something that merely begins with a slash?
///
/// A PATH IS NOT A COMMAND. Dropping a file into a terminal pastes its path,
/// and an absolute one begins with `/` -- so a screenshot dragged onto the
/// prompt was refused as an unknown command and never reached the model. A
/// command's name is a bare word: no separator in it, and no dot.
///
/// A slash with no name after it IS a command, and a refused one. Sending it
/// to the model instead would be paying for an answer to a slip.
pub fn looks_like_command(line: &str) -> bool {
    match line.strip_prefix('/') {
        None => false,
        Some(rest) => {
            let word = rest.split_whitespace().next().unwrap_or("");
            !word.contains('/') && !word.contains('.')
        }
    }
}

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
    // A path being typed is not a command being typed.
    if !looks_like_command(input) {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_path_is_not_a_command() {
        // Dropping a file into a terminal pastes its path, and an absolute
        // one begins with a slash -- so a screenshot dragged onto the prompt
        // was refused as an unknown command and never reached the model.
        for path in [
            "/var/folders/5_/T/screenshot.png",
            "/Users/dev/notes.md",
            "/tmp/x",
        ] {
            assert!(!looks_like_command(path), "{path:?} was taken for a command");
            assert!(matching(path).is_empty(), "{path:?} opened the command menu");
        }
    }

    #[test]
    fn a_slash_line_that_names_nothing_is_still_refused_here() {
        // Sending it to the model instead would be paying for an answer to a
        // slip -- which is the whole reason slash lines are handled locally.
        for line in ["/nonsense", "/", "/quit", "/find vite"] {
            assert!(looks_like_command(line), "{line:?} would have been sent onward");
        }
        assert!(!looks_like_command("what is /var for"));
        assert!(!looks_like_command("!ls -la"));
    }

    #[test]
    fn the_menu_offers_nothing_the_dispatcher_refuses() {
        // The reason the table exists: three copies of a list is three
        // chances for the menu to offer a command nobody handles.
        for command in COMMANDS {
            assert!(lookup(command.name).is_some(), "{} is not dispatchable", command.name);
            for alias in command.aliases {
                assert!(lookup(alias).is_some(), "{alias} resolves to nothing");
            }
        }
    }
}
