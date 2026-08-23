//! What the client knows, and how an event changes it.
//!
//! No terminal and no socket in this file. A full-screen client fails by
//! drawing the wrong thing, not by crashing, and a wrong frame is invisible to
//! the compiler and to a smoke test alike -- so the fold is pure and a test
//! feeds it a known event stream and reads the result back.

use crate::protocol::{Event, Recorded, SessionInfo};
use std::collections::{BTreeMap, HashSet};

/// Who said it. The whole reason the transcript is a list of entries rather
/// than a string: `user.message` and `model.delta` arrive as different events,
/// and flattening them into one buffer throws away the only thing that lets a
/// reader tell a question from an answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    User,
    Assistant,
    Tool,
    Note,
}

#[derive(Debug, Clone)]
pub struct Entry {
    pub role: Role,
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TaskState {
    Running,
    Draining,
    Done,
    Failed,
    Cancelled,
}

impl TaskState {
    pub fn mark(self) -> &'static str {
        match self {
            TaskState::Running => "*",
            TaskState::Draining => "~",
            TaskState::Done => "+",
            TaskState::Failed => "!",
            TaskState::Cancelled => "-",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Task {
    pub state: TaskState,
    pub parent: Option<String>,
    pub label: String,
    /// The last line the work printed. A subagent that has been running for
    /// four minutes and a subagent that is wedged look identical without it.
    pub latest: String,
}

/// One session's conversation and the work it spawned.
#[derive(Debug, Default)]
pub struct Conversation {
    pub entries: Vec<Entry>,
    /// Streamed assistant text that has not ended in a newline yet. Output
    /// arrives split at arbitrary boundaries -- a line in five pieces, a piece
    /// holding three lines -- and appending each piece as its own entry is how
    /// a client turns one sentence into five paragraphs.
    partial: String,
    pub tasks: BTreeMap<String, Task>,
    pub busy: bool,
    /// The highest sequence seen, and any gap found in it. A client is the
    /// last place that can notice the daemon skipped an event, and noticing
    /// silently is the same as not noticing.
    pub last_seq: u64,
    pub gap: bool,
    pub scroll: u16,
    /// Bumped on every change. The renderer wraps a whole transcript to lay it
    /// out, which costs the length of the conversation -- so it does that once
    /// per change rather than once per frame, and this is how it knows.
    pub revision: u64,
    /// True while the view is pinned to the newest output. A person who has
    /// scrolled up is reading; yanking them back to the bottom on the next
    /// token is the single rudest thing a log view can do.
    pub following: bool,
}

impl Conversation {
    pub fn new() -> Self {
        Conversation { following: true, ..Default::default() }
    }

    fn push(&mut self, role: Role, text: impl Into<String>) {
        self.revision += 1;
        let text = text.into();
        // Consecutive assistant text is one entry, so a reply that arrived in
        // forty chunks renders as one paragraph rather than forty.
        if role == Role::Assistant {
            if let Some(last) = self.entries.last_mut() {
                if last.role == Role::Assistant {
                    last.text.push_str(&text);
                    return;
                }
            }
        }
        self.entries.push(Entry { role, text });
    }

    pub fn end_partial(&mut self) {
        if !self.partial.is_empty() {
            let text = std::mem::take(&mut self.partial);
            self.push(Role::Assistant, text);
        }
    }

    fn absorb_text(&mut self, text: &str) {
        self.revision += 1;
        self.partial.push_str(text);
        while let Some(at) = self.partial.find('\n') {
            let line: String = self.partial.drain(..=at).collect();
            self.push(Role::Assistant, line);
        }
    }

    /// The transcript including whatever is streaming right now.
    ///
    /// BORROWED, not cloned. Cloning every entry to render a frame costs the
    /// whole conversation per frame, which is most of why a long session felt
    /// slower than a short one.
    pub fn visible_entries(&self) -> impl Iterator<Item = (Role, &str)> {
        self.entries
            .iter()
            .map(|entry| (entry.role, entry.text.as_str()))
            .chain(
                (!self.partial.is_empty())
                    .then(|| (Role::Assistant, self.partial.as_str()))
                    .into_iter(),
            )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Focus {
    Input,
    Sessions,
    /// The picker is open over everything else. A mode, deliberately: finding
    /// a session among hundreds is a different activity from talking to one,
    /// and pretending otherwise means every key has two meanings.
    Picker,
}

/// Finding a session among all of them, running or not.
#[derive(Debug, Default)]
pub struct Picker {
    pub query: String,
    pub results: Vec<Recorded>,
    pub selection: usize,
    /// True while a search is out, so an empty list can say `looking` instead
    /// of `nothing found` -- which are different answers.
    pub searching: bool,
}

impl Picker {
    pub fn move_selection(&mut self, step: isize) {
        if self.results.is_empty() {
            return;
        }
        let count = self.results.len() as isize;
        self.selection = (self.selection as isize + step).rem_euclid(count) as usize;
    }

    pub fn selected(&self) -> Option<&Recorded> {
        self.results.get(self.selection)
    }
}

#[derive(Debug)]
pub struct Model {
    pub sessions: Vec<SessionInfo>,
    pub current: String,
    pub conversations: BTreeMap<String, Conversation>,
    pub input: String,
    pub status: String,
    pub focus: Focus,
    pub selection: usize,
    /// The sessions that are OPEN, in the order they were opened -- browser
    /// tabs, not workspaces. The sidebar is for finding a session among all of
    /// them; a tab is one you have chosen to keep in front of you, and `+`
    /// opening a new tab means starting a session, which is what the word
    /// leads a person to expect.
    pub tabs: Vec<String>,
    pub tab: usize,
    pub cwd: String,
    pub connected: bool,
    pub picker: Picker,
    /// Every session id ever listed. A tab whose session is missing from the
    /// list is only gone if we had SEEN it there; one we have never seen is
    /// young, not dead. Without the distinction, opening a session and asking
    /// for the list in the same breath closes the tab that was just made,
    /// because the daemon had not finished registering the cell.
    known: HashSet<String>,
}

impl Model {
    pub fn new(cwd: String) -> Self {
        Model {
            sessions: Vec::new(),
            current: String::new(),
            conversations: BTreeMap::new(),
            input: String::new(),
            status: String::new(),
            focus: Focus::Input,
            selection: 0,
            tabs: Vec::new(),
            tab: 0,
            cwd,
            connected: true,
            picker: Picker::default(),
            known: HashSet::new(),
        }
    }

    pub fn conversation(&mut self, session: &str) -> &mut Conversation {
        self.conversations
            .entry(session.to_string())
            .or_insert_with(Conversation::new)
    }

    pub fn current_conversation(&self) -> Option<&Conversation> {
        self.conversations.get(&self.current)
    }

    /// Fold one event into the session it belongs to.
    ///
    /// ROUTED BY THE EVENT'S OWN SESSION, never by which one is on screen. A
    /// client watching three sessions receives all three streams down one
    /// socket, and attributing them to whatever is in front is how one
    /// session's output appears under another's name.
    pub fn absorb(&mut self, event: &Event) {
        let session = if event.session.is_empty() {
            self.current.clone()
        } else {
            event.session.clone()
        };
        let text = event.text("text").to_string();
        let name = event.name.clone();
        let seq = event.seq;
        let conversation = self.conversation(&session);
        if seq > 0 {
            if conversation.last_seq > 0 && seq > conversation.last_seq + 1 {
                conversation.gap = true;
            }
            conversation.last_seq = conversation.last_seq.max(seq);
        }
        match name.as_str() {
            "user.message" => {
                conversation.end_partial();
                conversation.push(Role::User, text);
            }
            "model.delta" => conversation.absorb_text(&text),
            "tool.started" => {
                conversation.end_partial();
                let call = event
                    .data
                    .get("call")
                    .and_then(|call| call.get("command").or_else(|| call.get("name")))
                    .and_then(|value| value.as_str())
                    .unwrap_or("tool");
                conversation.push(Role::Tool, call.to_string());
            }
            "tool.output" => {
                conversation.revision += 1;
                // Live output from a command still running. It belongs to the
                // task pane as well as the transcript: a build that prints for
                // four minutes is the thing a person is waiting on.
                if let Some(task) = conversation
                    .tasks
                    .values_mut()
                    .find(|task| task.state == TaskState::Running)
                {
                    if let Some(line) = text.lines().last() {
                        task.latest = line.to_string();
                    }
                }
            }
            "turn.started" => {
                conversation.busy = true;
            }
            "turn.completed" | "turn.failed" | "turn.cancelled" => {
                conversation.end_partial();
                conversation.busy = false;
            }
            "task.started" => {
                conversation.revision += 1;
                let id = event.text("task").to_string();
                let parent = event.data.get("parent").and_then(|v| v.as_str()).map(str::to_string);
                let label = if text.is_empty() { id.clone() } else { text.clone() };
                conversation.tasks.insert(
                    id,
                    Task { state: TaskState::Running, parent, label, latest: String::new() },
                );
            }
            "task.draining" => set_task_state(conversation, event, TaskState::Draining),
            "task.completed" => set_task_state(conversation, event, TaskState::Done),
            "task.failed" | "task.error" => set_task_state(conversation, event, TaskState::Failed),
            "task.cancelled" => set_task_state(conversation, event, TaskState::Cancelled),
            "session.error" => {
                let detail = event.text("detail").to_string();
                conversation.push(Role::Note, detail);
            }
            "question.requested" | "approval.requested" => {
                conversation.push(Role::Note, format!("needs you: {}", text));
            }
            // A client one version behind its daemon should lose a feature,
            // not fall over.
            _ => {}
        }
    }

    /// Put a session in a tab and make it current, or focus the tab it is
    /// already in. Opening the same session twice is a person asking to look
    /// at it, not asking for a second copy.
    pub fn open_tab(&mut self, id: &str) {
        match self.tabs.iter().position(|open| open == id) {
            Some(index) => self.tab = index,
            None => {
                self.tabs.push(id.to_string());
                self.tab = self.tabs.len() - 1;
            }
        }
        self.current = id.to_string();
        self.conversation(id);
    }

    /// Close the tab at INDEX. The session keeps running -- closing a view of
    /// something is not ending it, and a client that killed work by being shut
    /// would make the daemon pointless.
    pub fn close_tab(&mut self, index: usize) {
        if index >= self.tabs.len() {
            return;
        }
        self.tabs.remove(index);
        if self.tabs.is_empty() {
            self.current.clear();
            self.tab = 0;
            return;
        }
        self.tab = index.min(self.tabs.len() - 1);
        self.current = self.tabs[self.tab].clone();
    }

    /// Drop tabs whose session the daemon no longer lists, so a tab bar cannot
    /// outlive what it points at.
    pub fn prune_tabs(&mut self) {
        let live: Vec<String> = self.sessions.iter().map(|s| s.id.clone()).collect();
        for id in &live {
            self.known.insert(id.clone());
        }
        let known = &self.known;
        self.tabs
            .retain(|id| live.contains(id) || !known.contains(id));
        if self.tab >= self.tabs.len() {
            self.tab = self.tabs.len().saturating_sub(1);
        }
        if !self.tabs.is_empty() && !self.tabs.contains(&self.current) {
            self.current = self.tabs[self.tab].clone();
        }
    }

    /// The label a tab shows: the project, and the session id when two tabs
    /// would otherwise read identically.
    pub fn tab_label(&self, id: &str) -> String {
        let Some(session) = self.sessions.iter().find(|s| s.id == id) else {
            return id.to_string();
        };
        let short = session.short_label().to_string();
        let duplicates = self
            .tabs
            .iter()
            .filter(|other| {
                self.sessions
                    .iter()
                    .find(|s| &&s.id == other)
                    .map(|s| s.short_label() == short)
                    .unwrap_or(false)
            })
            .count();
        if duplicates > 1 {
            format!("{short} {id}")
        } else {
            short
        }
    }

    /// Say something to the person, in the transcript, from the client itself.
    ///
    /// In the transcript rather than only the status line: a reply to
    /// something they typed belongs where the rest of the conversation is, and
    /// a status line is gone by the next keystroke.
    pub fn note(&mut self, text: impl Into<String>) {
        let current = self.current.clone();
        let conversation = self.conversation(&current);
        conversation.end_partial();
        conversation.push(Role::Note, text.into());
    }

    pub fn selected_session(&self) -> Option<&SessionInfo> {
        self.sessions.get(self.selection)
    }

    pub fn move_selection(&mut self, step: isize) {
        if self.sessions.is_empty() {
            return;
        }
        let count = self.sessions.len() as isize;
        let next = (self.selection as isize + step).rem_euclid(count);
        self.selection = next as usize;
    }
}

fn set_task_state(conversation: &mut Conversation, event: &Event, state: TaskState) {
    let id = event.text("task").to_string();
    if let Some(task) = conversation.tasks.get_mut(&id) {
        task.state = state;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn event(name: &str, session: &str, data: serde_json::Value) -> Event {
        serde_json::from_value(json!({
            "event": name, "session": session, "seq": 1, "data": data
        }))
        .unwrap()
    }

    fn model_with(session: &str) -> Model {
        let mut model = Model::new("/w".into());
        model.sessions = vec![SessionInfo {
            id: session.into(),
            label: "/w/alpha".into(),
            state: "idle".into(),
            ..Default::default()
        }];
        model.open_tab(session);
        model
    }

    #[test]
    fn a_question_and_an_answer_are_different_things() {
        // The whole reason the transcript is a list of entries rather than a
        // string. Flattening both into one buffer throws away the only thing
        // that lets a reader tell what they asked from what they were told.
        let mut model = model_with("s1");
        model.absorb(&event("user.message", "s1", json!({"text": "run the tests"})));
        model.absorb(&event("model.delta", "s1", json!({"text": "all green\n"})));
        let entries: Vec<(Role, String)> = model
            .current_conversation()
            .unwrap()
            .visible_entries()
            .map(|(role, text)| (role, text.to_string()))
            .collect();
        let roles: Vec<Role> = entries.iter().map(|(role, _)| *role).collect();
        assert_eq!(roles, vec![Role::User, Role::Assistant]);
        assert_eq!(entries[0].1, "run the tests");
        assert!(entries[1].1.contains("all green"));
    }

    #[test]
    fn streamed_text_becomes_paragraphs_however_it_arrives() {
        // A line arrives in five pieces and a piece holds three lines.
        // Appending each piece as its own entry is how a client turns one
        // sentence into five paragraphs.
        let mut model = model_with("s1");
        for piece in ["one", " and", " two\nthree\nfo", "ur\n"] {
            model.absorb(&event("model.delta", "s1", json!({"text": piece})));
        }
        let text = model
            .current_conversation()
            .unwrap()
            .visible_entries()
            .next()
            .unwrap()
            .1
            .to_string();
        assert_eq!(text, "one and two\nthree\nfour\n");
    }

    #[test]
    fn an_unfinished_line_is_still_shown() {
        // It is what the model is saying right now.
        let mut model = model_with("s1");
        model.absorb(&event("model.delta", "s1", json!({"text": "thinking"})));
        assert!(model.current_conversation().unwrap().entries.is_empty());
        let visible: Vec<(Role, String)> = model
            .current_conversation()
            .unwrap()
            .visible_entries()
            .map(|(role, text)| (role, text.to_string()))
            .collect();
        assert_eq!(visible.len(), 1);
        assert_eq!(visible[0].1, "thinking");
    }

    #[test]
    fn events_go_to_their_own_session_not_the_one_on_screen() {
        // A client watching three sessions receives all three streams down one
        // socket. Attributing them to whatever is in front is how one
        // session's output appears under another's name.
        let mut model = model_with("s1");
        model.absorb(&event("user.message", "s2", json!({"text": "elsewhere"})));
        assert!(model.conversations["s1"].entries.is_empty());
        assert_eq!(model.conversations["s2"].entries[0].text, "elsewhere");
    }

    #[test]
    fn a_tab_is_a_session_you_opened_and_opening_it_twice_is_one_tab() {
        let mut model = model_with("s1");
        model.sessions.push(SessionInfo { id: "s2".into(), ..Default::default() });
        model.open_tab("s2");
        assert_eq!(model.tabs, vec!["s1", "s2"]);
        assert_eq!(model.tab, 1);
        model.open_tab("s1");
        assert_eq!(model.tabs.len(), 2, "opening an open session made a second tab");
        assert_eq!(model.tab, 0, "opening an open session did not focus its tab");
    }

    #[test]
    fn closing_a_tab_does_not_end_the_session() {
        let mut model = model_with("s1");
        model.sessions.push(SessionInfo { id: "s2".into(), ..Default::default() });
        model.open_tab("s2");
        model.close_tab(1);
        assert_eq!(model.tabs, vec!["s1"]);
        assert_eq!(model.current, "s1");
        // The session is still there to be reopened -- closing a view of
        // something is not ending it.
        assert!(model.sessions.iter().any(|s| s.id == "s2"));
    }

    #[test]
    fn a_tab_cannot_outlive_the_session_it_points_at() {
        let mut model = model_with("s1");
        model.sessions.push(SessionInfo { id: "s2".into(), ..Default::default() });
        model.prune_tabs();                       // both are now known
        model.open_tab("s2");
        model.sessions.retain(|s| s.id == "s1");
        model.prune_tabs();
        assert_eq!(model.tabs, vec!["s1"]);
        assert_eq!(model.current, "s1");
    }

    #[test]
    fn a_tab_for_a_session_the_list_has_not_caught_up_with_survives() {
        // Opening a session and asking for the list in the same breath closed
        // the tab that had just been made: the daemon had registered the cell
        // and not yet listed it, and pruning read that as `gone`. A session we
        // have never seen is young, not dead.
        let mut model = model_with("s1");
        model.prune_tabs();
        model.open_tab("s9");                     // started, not yet listed
        model.prune_tabs();
        assert!(model.tabs.contains(&"s9".to_string()), "the new tab was pruned");
        assert_eq!(model.current, "s9");
        // Once it HAS been seen, losing it does close the tab.
        model.sessions.push(SessionInfo { id: "s9".into(), ..Default::default() });
        model.prune_tabs();
        model.sessions.retain(|s| s.id != "s9");
        model.prune_tabs();
        assert!(!model.tabs.contains(&"s9".to_string()), "a session that ended kept its tab");
    }

    #[test]
    fn two_tabs_in_one_project_are_told_apart() {
        // Both labelled `alpha` is a tab bar that cannot be used.
        let mut model = Model::new("/w".into());
        model.sessions = vec![
            SessionInfo { id: "s1".into(), label: "/w/alpha".into(), ..Default::default() },
            SessionInfo { id: "s2".into(), label: "/w/alpha".into(), ..Default::default() },
        ];
        model.open_tab("s1");
        model.open_tab("s2");
        assert_eq!(model.tab_label("s1"), "alpha s1");
        assert_eq!(model.tab_label("s2"), "alpha s2");
    }

    #[test]
    fn a_subagent_and_what_it_is_printing_reach_the_task_pane() {
        let mut model = model_with("s1");
        model.absorb(&event("task.started", "s1", json!({"task": "t1", "text": "index the repo"})));
        model.absorb(&event(
            "task.started",
            "s1",
            json!({"task": "t2", "text": "run the suite", "parent": "t1"}),
        ));
        model.absorb(&event("tool.output", "s1", json!({"text": "compiling...\nlinking...\n"})));
        let tasks = &model.current_conversation().unwrap().tasks;
        assert_eq!(tasks.len(), 2);
        assert_eq!(tasks["t1"].state, TaskState::Running);
        assert_eq!(tasks["t2"].parent.as_deref(), Some("t1"));
        // The LAST line, not the whole stream: a build that prints for four
        // minutes must not push the task list off the screen.
        assert_eq!(tasks["t1"].latest, "linking...");
        model.absorb(&event("task.completed", "s1", json!({"task": "t1"})));
        assert_eq!(model.current_conversation().unwrap().tasks["t1"].state, TaskState::Done);
    }

    #[test]
    fn an_unknown_event_is_ignored_rather_than_fatal() {
        // A client one version behind its daemon should lose a feature, not
        // fall over.
        let mut model = model_with("s1");
        model.absorb(&event("something.invented.later", "s1", json!({"text": "?"})));
        assert!(model.conversations["s1"].entries.is_empty());
    }

    #[test]
    fn a_session_is_named_by_its_project_not_its_path() {
        let session = SessionInfo { label: "/Users/dev/workspace/vivarium".into(), ..Default::default() };
        assert_eq!(session.short_label(), "vivarium");
        let trailing = SessionInfo { label: "/a/b/".into(), ..Default::default() };
        assert_eq!(trailing.short_label(), "b");
        let bare = SessionInfo { label: "notes".into(), ..Default::default() };
        assert_eq!(bare.short_label(), "notes");
    }
}
