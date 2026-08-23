//! The facts about a session that are true whether or not anyone asked.
//!
//! Which model, how hard it is thinking, where it is working, on what branch,
//! and how full its context is. A client that shows only a transcript makes a
//! person hold all of that in their head, and the one that matters most --
//! how close the context is to its limit -- is invisible until a summary
//! appears and the conversation changes character with no explanation.

use crate::model::Model;
use std::path::{Path, PathBuf};

/// One line of facts, in the order a person asks them.
pub fn facts(model: &Model) -> Vec<String> {
    let Some(session) = model.sessions.iter().find(|entry| entry.id == model.current) else {
        return Vec::new();
    };
    let mut facts = Vec::new();
    if !session.model.is_empty() {
        facts.push(session.model.clone());
    }
    if !session.effort.is_empty() {
        facts.push(session.effort.clone());
    }
    facts.push(session.short_label().to_string());
    if let Some(branch) = branch(&session.cwd) {
        facts.push(branch);
    }
    if let Some(context) = context(session.tokens, session.limit) {
        facts.push(context);
    }
    facts
}

/// How full the context is, measured rather than estimated: the number the
/// provider reported for the last request, against what this model accepts.
/// Nothing before the first reply, because nothing has been measured yet.
fn context(tokens: u64, limit: u64) -> Option<String> {
    if tokens == 0 || limit == 0 {
        return None;
    }
    let percent = (tokens as f64 / limit as f64 * 100.0).round() as u64;
    Some(format!("{percent}% of {}", round_thousands(limit)))
}

fn round_thousands(count: u64) -> String {
    match count {
        0..=999 => count.to_string(),
        _ => format!("{}k", count / 1000),
    }
}

/// The branch a directory is on, read from the repository rather than asked
/// for. Running `git` would mean a process per frame and a dependency on the
/// binary being installed, for a string that is one file.
fn branch(cwd: &str) -> Option<String> {
    let head = std::fs::read_to_string(git_dir(Path::new(cwd))?.join("HEAD")).ok()?;
    let head = head.trim();
    match head.strip_prefix("ref: refs/heads/") {
        Some(name) => Some(name.to_string()),
        // Detached: the commit is the only name it has.
        None => head.get(..8).map(|short| format!("detached {short}")),
    }
}

/// Where this directory's git data lives, walking up as git does.
///
/// `.git` IS NOT ALWAYS A DIRECTORY. In a linked worktree it is a file holding
/// the path to one, which is how a checkout that is perfectly on a branch
/// reports no branch at all.
fn git_dir(from: &Path) -> Option<PathBuf> {
    for directory in from.ancestors() {
        let candidate = directory.join(".git");
        if candidate.is_dir() {
            return Some(candidate);
        }
        if candidate.is_file() {
            let pointer = std::fs::read_to_string(&candidate).ok()?;
            let path = pointer.trim().strip_prefix("gitdir:")?.trim();
            let path = PathBuf::from(path);
            return Some(if path.is_absolute() { path } else { directory.join(path) });
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::SessionInfo;

    fn model_with(session: SessionInfo) -> Model {
        let mut model = Model::new("/w".into());
        model.current = session.id.clone();
        model.sessions = vec![session];
        model
    }

    #[test]
    fn the_facts_lead_with_what_is_answering() {
        let model = model_with(SessionInfo {
            id: "s1".into(),
            label: "/w/alpha".into(),
            cwd: "/w/alpha".into(),
            model: "deepseek-4-flash".into(),
            effort: "high".into(),
            tokens: 12_800,
            limit: 128_000,
            ..Default::default()
        });
        let facts = facts(&model);
        assert_eq!(facts[0], "deepseek-4-flash");
        assert_eq!(facts[1], "high");
        assert_eq!(facts[2], "alpha");
        assert!(facts.iter().any(|fact| fact == "10% of 128k"),
                "the context is not reported: {facts:?}");
    }

    #[test]
    fn a_context_nobody_has_measured_yet_is_not_reported() {
        // Zero is not `empty`, it is `no request has come back`. Drawing 0%
        // makes a number up and then makes it look measured.
        assert_eq!(context(0, 128_000), None);
        assert_eq!(context(4_000, 0), None);
        assert_eq!(context(64_000, 128_000).unwrap(), "50% of 128k");
    }

    #[test]
    fn a_linked_worktree_still_knows_its_branch() {
        // `.git` is a FILE in a linked worktree, holding the path to the real
        // one. Treating it as a directory reports no branch for a checkout
        // that is perfectly on one -- and this repository is developed in
        // worktrees, so that is the ordinary case, not the exotic one.
        let root = std::env::temp_dir().join(format!("viva-branch-{}", std::process::id()));
        let real = root.join("store");
        let tree = root.join("tree");
        std::fs::create_dir_all(&real).unwrap();
        std::fs::create_dir_all(&tree).unwrap();
        std::fs::write(real.join("HEAD"), "ref: refs/heads/tosin/silly-bun\n").unwrap();
        std::fs::write(tree.join(".git"), format!("gitdir: {}\n", real.display())).unwrap();
        assert_eq!(branch(tree.to_str().unwrap()).as_deref(), Some("tosin/silly-bun"));
        std::fs::remove_dir_all(&root).ok();
    }
}
