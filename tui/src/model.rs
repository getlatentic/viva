//! What the client knows, and how an event changes it.
//!
//! No terminal and no socket in this file. A full-screen client fails by
//! drawing the wrong thing, not by crashing, and a wrong frame is invisible to
//! the compiler and to a smoke test alike -- so the fold is pure and a test
//! feeds it a known event stream and reads the result back.

use crate::protocol::{Event, Learned, Recorded, SessionInfo};
use serde_json::Value;
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

/// How a tool call ended. Unknown while it runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Running,
    Done,
    Failed,
}

impl Outcome {
    pub fn mark(self) -> &'static str {
        match self {
            Outcome::Running => "·",
            Outcome::Done => "✔",
            Outcome::Failed => "✘",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Entry {
    pub role: Role,
    pub text: String,
    /// What a tool printed. Held on the call rather than pushed into the
    /// transcript as loose lines: a build that prints four hundred lines
    /// otherwise buries the conversation it belongs to, and there is no way
    /// left to tell which call produced what.
    pub output: Vec<String>,
    pub outcome: Outcome,
    /// The id the daemon gave this call, so its result can find it again.
    call: String,
    /// Bumped whenever this entry changes, so a renderer can tell which of a
    /// thousand entries it has to lay out again -- which is one of them.
    pub stamp: u64,
    /// When the call began, by this client's clock, and how long it took.
    /// Measured here rather than read from the event: an event's time is in
    /// whole seconds, and the difference between a 40ms grep and an 800ms one
    /// is the thing worth showing.
    started: Option<std::time::Instant>,
    pub took: Option<std::time::Duration>,
    /// True once output has arrived as a stream. A command that streams also
    /// reports its whole output when it finishes, so a client that took both
    /// would print everything a running command said a second time.
    streamed: bool,
}

impl Entry {
    fn new(role: Role, text: String) -> Self {
        Entry {
            role,
            text,
            output: Vec::new(),
            outcome: Outcome::Running,
            call: String::new(),
            stamp: 0,
            started: None,
            took: None,
            streamed: false,
        }
    }
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
    /// The assistant line that has not ended in a newline yet, held as the
    /// entry it renders as. Output arrives split at arbitrary boundaries -- a
    /// line in five pieces, a piece holding three lines -- and appending each
    /// piece as its own entry is how a client turns one sentence into five
    /// paragraphs.
    ///
    /// ONE place holds it. While the same text sat in a buffer and again in a
    /// rendered copy, ending a turn drained the buffer and left the copy
    /// behind, so every reply drew its last paragraph twice and the leftover
    /// outlived the turn -- surfacing again under the next question.
    streaming: Vec<Entry>,
    pub tasks: BTreeMap<String, Task>,
    pub busy: bool,
    /// The highest sequence seen, and any gap found in it. A client is the
    /// last place that can notice the daemon skipped an event, and noticing
    /// silently is the same as not noticing.
    pub last_seq: u64,
    pub gap: bool,
    pub scroll: u16,
    /// Scroll asked for and not yet applied.
    ///
    /// A wheel sends a BURST, not an event. Applying a whole burst in one
    /// frame moves the view without ever showing it move -- twenty events
    /// became one frame sixty lines further on, which is a jump wearing a
    /// scroll's name. Paid out a step per frame instead, at a cost of under a
    /// millisecond each, so a fast gesture still finishes fast and the eye is
    /// given something to follow.
    pending: i32,
    /// Bumped on every change. The renderer wraps a whole transcript to lay it
    /// out, which costs the length of the conversation -- so it does that once
    /// per change rather than once per frame, and this is how it knows.
    pub revision: u64,
    /// The stamp given to the next entry that changes. Never reused, so an
    /// entry that has been laid out cannot be mistaken for one that has not.
    stamps: u64,
    /// Show every line a tool printed, rather than the first few. Off by
    /// default: a tool result is context for the conversation, and a
    /// four-hundred-line build log that pushes the conversation off the screen
    /// has stopped being context.
    pub expanded: bool,
    /// True while the view is pinned to the newest output. A person who has
    /// scrolled up is reading; yanking them back to the bottom on the next
    /// token is the single rudest thing a log view can do.
    pub following: bool,
}

impl Conversation {
    pub fn new() -> Self {
        Conversation { following: true, ..Default::default() }
    }

    /// The smallest move worth a frame: one notch of a wheel.
    const STEP: i32 = 3;
    /// The largest, so a fling arrives quickly without skipping the screen.
    const LEAP: i32 = 60;

    /// Ask to move by LINES, to be paid out over the frames that follow.
    pub fn scroll_by(&mut self, lines: i32) {
        self.pending += lines;
    }

    /// Jump, with nothing owed. Home and End mean the end, not a journey to it.
    pub fn jump_to(&mut self, offset: u16) {
        self.pending = 0;
        self.scroll = offset;
        self.following = offset == 0;
    }

    /// Is there movement still owed?
    pub fn owes_scroll(&self) -> bool {
        self.pending != 0
    }

    /// Pay out one frame's worth. True when the view moved.
    ///
    /// EASING OUT, a quarter of what is left each time: a slow gesture moves
    /// exactly one notch and a two-hundred-line fling arrives in a handful of
    /// frames, both of them visibly moving rather than arriving.
    pub fn settle(&mut self) -> bool {
        if self.pending == 0 {
            return false;
        }
        let owed = self.pending.abs();
        let step = (owed / 4).clamp(Self::STEP, Self::LEAP).min(owed) * self.pending.signum();
        self.pending -= step;
        let next = (self.scroll as i32 + step).max(0);
        if next == 0 {
            self.pending = 0;
        }
        self.scroll = next.min(u16::MAX as i32) as u16;
        // Reaching the bottom resumes following, so a person who scrolled back
        // and then returned does not have to know there is a mode.
        self.following = next == 0;
        true
    }

    fn push(&mut self, role: Role, text: impl Into<String>) {
        self.revision += 1;
        self.stamps += 1;
        let stamp = self.stamps;
        let text = text.into();
        // Consecutive assistant text is one entry, so a reply that arrived in
        // forty chunks renders as one paragraph rather than forty.
        if role == Role::Assistant {
            if let Some(last) = self.entries.last_mut() {
                if last.role == Role::Assistant {
                    last.text.push_str(&text);
                    last.stamp = stamp;
                    return;
                }
            }
        }
        let mut entry = Entry::new(role, text);
        entry.stamp = stamp;
        self.entries.push(entry);
    }

    pub fn end_partial(&mut self) {
        let text = self.take_streaming();
        if !text.is_empty() {
            self.push(Role::Assistant, text);
        }
    }

    fn absorb_text(&mut self, text: &str) {
        self.revision += 1;
        let mut line = self.take_streaming();
        line.push_str(text);
        while let Some(at) = line.find('\n') {
            let complete: String = line.drain(..=at).collect();
            self.push(Role::Assistant, complete);
        }
        if !line.is_empty() {
            self.stamps += 1;
            let mut entry = Entry::new(Role::Assistant, line);
            entry.stamp = self.stamps;
            self.streaming.push(entry);
        }
    }

    /// The transcript including whatever is streaming right now.
    ///
    /// BORROWED, not cloned. Cloning every entry to render a frame costs the
    /// whole conversation per frame, which is most of why a long session felt
    /// slower than a short one.
    pub fn visible_entries(&self) -> impl Iterator<Item = &Entry> {
        self.entries.iter().chain(self.streaming.iter())
    }

    /// The call an event belongs to: the one with this id, or -- for an event
    /// that carries none -- the innermost call still running.
    ///
    /// BY ID, BECAUSE CALLS NEST. A `delegate` runs a whole sub-agent inside
    /// its own call, and every tool that worker uses is reported on the same
    /// stream between the delegate's start and its end. `The last call
    /// started` is therefore the worker's last step, so the delegate's own
    /// result landed on that step instead, and the delegate itself stayed
    /// marked as running for the rest of the session.
    fn tool_mut(&mut self, id: &str) -> Option<&mut Entry> {
        self.stamps += 1;
        let stamp = self.stamps;
        let found = self.entries.iter_mut().rev().find(|entry| {
            entry.role == Role::Tool
                && if id.is_empty() {
                    entry.outcome == Outcome::Running
                } else {
                    entry.call == id
                }
        });
        if let Some(entry) = found {
            entry.stamp = stamp;
            return Some(entry);
        }
        None
    }

    /// Take the unfinished line out, leaving nothing behind.
    fn take_streaming(&mut self) -> String {
        self.streaming.drain(..).map(|entry| entry.text).collect()
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
    /// Which entry the slash menu has highlighted. Reset whenever the line
    /// changes, so the highlight cannot point past a list that just shrank.
    pub command_selection: usize,
    /// What this session has retained. Kept on the model rather than fetched
    /// when the overlay opens, so the status line can carry the counts always:
    /// a harness whose whole point is that it learns should not hide what it
    /// has learned behind a keystroke.
    pub learned: Learned,
    pub showing_learned: bool,
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
            command_selection: 0,
            learned: Learned::default(),
            showing_learned: false,
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
                let line = call_line(event.data.get("call"));
                let id = call_id(event.data.get("call"));
                conversation.push(Role::Tool, line);
                if let Some(entry) = conversation.entries.last_mut() {
                    entry.call = id;
                    entry.started = Some(std::time::Instant::now());
                }
            }
            "tool.output" => {
                conversation.revision += 1;
                // Onto the CALL that is running, so output and call stay
                // joined. The transcript showed the call and dropped the
                // result entirely, which is why five different commands read
                // as five identical lines.
                if let Some(entry) = conversation.tool_mut("") {
                    entry.streamed = true;
                    for line in text.lines() {
                        entry.output.push(line.to_string());
                    }
                }
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
            "tool.completed" | "tool.failed" => {
                conversation.revision += 1;
                let failed = name == "tool.failed";
                // The RESULT rides here, under `output`. Every tool that
                // returns rather than streams -- read, ls, find, and a shell
                // command once it has exited -- reports its work on this event
                // and on no other, so reading only the streaming one leaves a
                // transcript of calls with nothing under any of them.
                let output = event.text("output").to_string();
                let id = call_id(event.data.get("call"));
                if let Some(entry) = conversation.tool_mut(&id) {
                    entry.outcome = if failed { Outcome::Failed } else { Outcome::Done };
                    entry.took = entry.started.map(|since| since.elapsed());
                    if !entry.streamed {
                        for line in output.lines() {
                            entry.output.push(line.to_string());
                        }
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

/// The argument worth showing, in the order worth trying.
///
/// The same list the line client settled on. A tool call is mostly one
/// interesting value and several uninteresting ones, and which key holds it
/// depends on the tool.
const SALIENT: &[&str] = &[
    "command", "path", "pattern", "query", "note", "target", "source", "name", "text", "url",
];

/// `bash cd /x && npm test` rather than `bash`.
///
/// The name alone made a run read as five identical lines saying `ls`, which
/// says the agent is busy and nothing whatever about what it is doing. The
/// arguments are one level down, under "arguments" -- looking for them beside
/// the name found nothing and silently fell back to the name.
/// The id the daemon gave a call, or nothing when the event carries none.
fn call_id(call: Option<&serde_json::Value>) -> String {
    call.and_then(|call| call.get("id"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

pub fn call_line(call: Option<&serde_json::Value>) -> String {
    let Some(call) = call else {
        return "tool".into();
    };
    let name = call.get("name").and_then(Value::as_str).unwrap_or("tool");
    let Some(arguments) = call.get("arguments").and_then(Value::as_object) else {
        return name.to_string();
    };
    // An argument that is present and EMPTY is not worth showing. `ls` with a
    // path of "" means the working directory, and taking it as the thing to
    // show left the call reading `ls ` with a separator and nothing after it.
    fn worth_showing(value: &Value) -> Option<&str> {
        value.as_str().filter(|text| !text.trim().is_empty())
    }
    let salient = SALIENT
        .iter()
        .find_map(|key| arguments.get(*key).and_then(worth_showing))
        // Any string at all, when none of the usual keys is there: a tool this
        // client has never heard of still has something worth showing.
        .or_else(|| arguments.values().find_map(worth_showing));
    match salient {
        Some(value) => format!("{name} {}", one_line(value, 72)),
        None => name.to_string(),
    }
}

/// One line of it, with the rest said to be there rather than shown.
fn one_line(text: &str, width: usize) -> String {
    let flattened = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if flattened.chars().count() <= width {
        return flattened;
    }
    let head: String = flattened.chars().take(width).collect();
    format!("{head}…")
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
            .map(|entry| (entry.role, entry.text.clone()))
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
            .text
            .clone();
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
            .map(|entry| (entry.role, entry.text.clone()))
            .collect();
        assert_eq!(visible.len(), 1);
        assert_eq!(visible[0].1, "thinking");
    }

    #[test]
    fn a_reply_that_does_not_end_in_a_newline_is_shown_once() {
        // A model rarely ends its last sentence with a newline, so the tail of
        // almost every reply was the unfinished line. Holding it in a buffer
        // AND in a rendered copy meant ending the turn drained one and kept
        // the other, and the closing paragraph appeared twice.
        let mut model = model_with("s1");
        model.absorb(&event("model.delta", "s1", json!({"text": "one\ntwo"})));
        model.absorb(&event("turn.completed", "s1", json!({})));
        let text: String = model
            .current_conversation()
            .unwrap()
            .visible_entries()
            .map(|entry| entry.text.clone())
            .collect();
        assert_eq!(text, "one\ntwo", "the closing line was drawn twice");
    }

    #[test]
    fn a_finished_reply_does_not_reappear_under_the_next_question() {
        // The leftover copy rendered after everything else, so it outlived its
        // own turn and surfaced below the NEXT question -- one turn's answer
        // shown as though it belonged to another.
        let mut model = model_with("s1");
        model.absorb(&event("model.delta", "s1", json!({"text": "first answer"})));
        model.absorb(&event("turn.completed", "s1", json!({})));
        model.absorb(&event("user.message", "s1", json!({"text": "next question"})));
        model.absorb(&event("model.delta", "s1", json!({"text": "second answer"})));
        let roles: Vec<Role> = model
            .current_conversation()
            .unwrap()
            .visible_entries()
            .map(|entry| entry.role)
            .collect();
        assert_eq!(roles, vec![Role::Assistant, Role::User, Role::Assistant]);
        let last = model
            .current_conversation()
            .unwrap()
            .visible_entries()
            .last()
            .unwrap()
            .text
            .clone();
        assert_eq!(last, "second answer", "the previous turn's tail came back");
    }

    #[test]
    fn a_burst_of_wheel_events_does_not_arrive_in_one_frame() {
        // A wheel sends a burst, not an event, and the loop drains every
        // waiting event before drawing. Twenty of them became ONE frame sixty
        // lines further on -- a jump wearing a scroll's name. Measured at the
        // pty: twenty events produced the same bytes as one.
        let mut conversation = Conversation::new();
        for _ in 0..20 {
            conversation.scroll_by(3);
        }
        let mut frames = 0;
        while conversation.settle() {
            frames += 1;
            assert!(frames < 60, "the scroll never finished");
        }
        assert!(frames >= 5, "sixty lines arrived in {frames} frame(s)");
        assert_eq!(conversation.scroll, 60, "the view did not end up where it was sent");
        assert!(!conversation.owes_scroll());
    }

    #[test]
    fn one_notch_moves_exactly_one_notch() {
        // Easing must not cost precision: a single deliberate notch is three
        // lines, not two and not four.
        let mut conversation = Conversation::new();
        conversation.scroll_by(3);
        assert!(conversation.settle());
        assert_eq!(conversation.scroll, 3);
        assert!(!conversation.settle(), "a finished scroll asked for another frame");
    }

    #[test]
    fn a_long_fling_moves_fastest_first() {
        // Otherwise a two-hundred-line fling at three lines a frame is a
        // crawl, and the cure for a jump becomes a different complaint.
        let mut conversation = Conversation::new();
        conversation.scroll_by(400);
        conversation.settle();
        let first = conversation.scroll as i32;
        let mut previous = first;
        let mut smaller_later = false;
        while conversation.settle() {
            let step = conversation.scroll as i32 - previous;
            previous = conversation.scroll as i32;
            if step < first {
                smaller_later = true;
            }
        }
        assert!(first > Conversation::STEP, "the fling started at a crawl: {first}");
        assert!(smaller_later, "the fling never slowed as it arrived");
        assert_eq!(conversation.scroll, 400);
    }

    #[test]
    fn arriving_at_the_bottom_stops_and_follows_again() {
        // Owing more than there is left to give would hold the view at the
        // bottom asking for frames forever.
        let mut conversation = Conversation::new();
        conversation.jump_to(20);
        conversation.scroll_by(-400);
        let mut frames = 0;
        while conversation.settle() {
            frames += 1;
            assert!(frames < 200, "the scroll ran past the bottom and kept going");
        }
        assert_eq!(conversation.scroll, 0);
        assert!(conversation.following, "returning to the bottom did not resume following");
        assert!(!conversation.owes_scroll());
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
    fn a_tool_call_says_what_it_is_doing() {
        // The name alone made a run read as five identical lines saying `ls`,
        // which says the agent is busy and nothing whatever about what it is
        // doing. The arguments are one level down, under "arguments" -- looking
        // for them beside the name found nothing and fell back to the name.
        let mut model = model_with("s1");
        for (arguments, expected) in [
            (json!({"command": "ls -la src"}), "bash ls -la src"),
            (json!({"path": "src/main.rs"}), "bash src/main.rs"),
            (json!({"pattern": "TODO"}), "bash TODO"),
            // A key this client has never heard of still has something worth
            // showing, so any string will do rather than nothing.
            (json!({"invented": "a value"}), "bash a value"),
            // Nothing string-shaped: the name alone, honestly.
            (json!({"depth": 3}), "bash"),
            (json!({}), "bash"),
        ] {
            let event = event(
                "tool.started",
                "s1",
                json!({"call": {"name": "bash", "arguments": arguments}}),
            );
            model.absorb(&event);
            let last = model.conversations["s1"].entries.last().unwrap();
            assert_eq!(last.role, Role::Tool);
            assert_eq!(last.text, expected);
        }
    }

    #[test]
    fn a_long_argument_is_one_line_with_the_rest_admitted() {
        // A twenty-line heredoc in the transcript pushes the conversation off
        // the screen to say one thing.
        let long = "echo ".to_string() + &"x".repeat(200);
        let line = call_line(Some(&json!({"name": "bash", "arguments": {"command": long}})));
        assert!(line.chars().count() < 90, "a long argument was not cut: {line}");
        assert!(line.ends_with('…'), "the cut was not admitted: {line}");
        // Newlines are flattened, so one call stays one line.
        let across = call_line(Some(&json!({
            "name": "bash", "arguments": {"command": "cd /x\n  && npm test"}
        })));
        assert_eq!(across, "bash cd /x && npm test");
    }

    #[test]
    fn a_tool_result_stays_with_the_call_that_produced_it() {
        // The transcript showed the call and dropped the result entirely,
        // which is why five different commands read as five identical lines.
        let mut model = model_with("s1");
        model.absorb(&event("tool.started", "s1",
                            json!({"call": {"name": "bash", "arguments": {"command": "ls src"}}})));
        model.absorb(&event("tool.output", "s1", json!({"text": "a.rs\nb.rs\n"})));
        model.absorb(&event("tool.completed", "s1", json!({})));
        let entry = model.conversations["s1"]
            .entries.iter().find(|e| e.role == Role::Tool).unwrap();
        assert_eq!(entry.text, "bash ls src");
        assert_eq!(entry.output, vec!["a.rs", "b.rs"]);
        assert_eq!(entry.outcome, Outcome::Done);
    }

    #[test]
    fn a_failed_call_looks_different_and_keeps_its_reason() {
        let mut model = model_with("s1");
        model.absorb(&event("tool.started", "s1",
                            json!({"call": {"name": "bash", "arguments": {"command": "false"}}})));
        model.absorb(&event("tool.failed", "s1", json!({"output": "exit 1"})));
        let entry = model.conversations["s1"]
            .entries.iter().find(|e| e.role == Role::Tool).unwrap();
        assert_eq!(entry.outcome, Outcome::Failed);
        assert!(entry.output.contains(&"exit 1".to_string()));
        assert_ne!(Outcome::Failed.mark(), Outcome::Done.mark());
    }

    #[test]
    fn a_tool_that_returns_rather_than_streams_still_shows_its_result() {
        // `ls`, `read`, `find` -- every tool that returns rather than streams
        // reports on `tool.completed`, under `output`, and on no other event.
        // Reading only the streaming event left a transcript of calls with
        // nothing under any of them, which is what a real session showed.
        let mut model = model_with("s1");
        model.absorb(&event("tool.started", "s1",
                            json!({"call": {"name": "ls", "arguments": {"path": ""}}})));
        model.absorb(&event("tool.completed", "s1",
                            json!({"call": {"name": "ls"}, "output": "my-react-app/\n"})));
        let entry = model.conversations["s1"]
            .entries.iter().find(|e| e.role == Role::Tool).unwrap();
        assert_eq!(entry.text, "ls");
        assert_eq!(entry.output, vec!["my-react-app/"], "the result never reached the call");
        assert_eq!(entry.outcome, Outcome::Done);
    }

    #[test]
    fn a_streamed_command_does_not_repeat_itself_when_it_finishes() {
        // A command that streams ALSO reports its whole output on completion.
        // Taking both prints everything the command said a second time.
        let mut model = model_with("s1");
        model.absorb(&event("tool.started", "s1",
                            json!({"call": {"name": "bash", "arguments": {"command": "make"}}})));
        model.absorb(&event("tool.output", "s1", json!({"text": "compiling\nlinking\n"})));
        model.absorb(&event("tool.completed", "s1",
                            json!({"output": "compiling\nlinking\n"})));
        let entry = model.conversations["s1"]
            .entries.iter().find(|e| e.role == Role::Tool).unwrap();
        assert_eq!(entry.output, vec!["compiling", "linking"], "the output was printed twice");
    }

    #[test]
    fn a_delegate_keeps_its_own_result_when_its_worker_calls_tools() {
        // `delegate` runs a whole sub-agent inside its own call, and the
        // worker's tools are reported on the same stream between the
        // delegate's start and its end. Matching a result to `the last call
        // started` gave the delegate's answer to the worker's last step, and
        // left the delegate marked as running for the rest of the session.
        // Taken from a recorded session: seq 127 opens it, 142 closes it.
        let mut model = model_with("s1");
        model.absorb(&event("tool.started", "s1", json!({
            "call": {"id": "d1", "name": "delegate", "arguments": {"task": "find how to run it"}}})));
        model.absorb(&event("tool.started", "s1", json!({
            "call": {"id": "r1", "name": "read", "arguments": {"path": "package.json"}}})));
        model.absorb(&event("tool.completed", "s1", json!({
            "call": {"id": "r1", "name": "read"}, "output": "{\n  \"name\": \"app\""})));
        model.absorb(&event("tool.completed", "s1", json!({
            "call": {"id": "d1", "name": "delegate"}, "output": "run npm install, then npm run dev"})));

        let calls: Vec<&Entry> = model.conversations["s1"]
            .entries.iter().filter(|entry| entry.role == Role::Tool).collect();
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0].outcome, Outcome::Done, "the delegate never stopped running");
        assert!(calls[0].output.iter().any(|line| line.contains("npm run dev")),
                "the delegate lost its own answer: {:?}", calls[0].output);
        assert!(calls[1].output.iter().all(|line| !line.contains("npm run dev")),
                "the delegate's answer landed on its worker's call: {:?}", calls[1].output);
    }

    #[test]
    fn streamed_output_goes_to_the_innermost_call_still_running() {
        // A streamed chunk carries no call id, so it goes to the call that is
        // running -- the innermost one, not one that has already finished.
        let mut model = model_with("s1");
        model.absorb(&event("tool.started", "s1",
                            json!({"call": {"id": "d1", "name": "delegate"}})));
        model.absorb(&event("tool.started", "s1",
                            json!({"call": {"id": "b1", "name": "bash",
                                            "arguments": {"command": "make"}}})));
        model.absorb(&event("tool.output", "s1", json!({"text": "compiling\n"})));
        model.absorb(&event("tool.completed", "s1", json!({"call": {"id": "b1"}, "output": ""})));
        model.absorb(&event("tool.output", "s1", json!({"text": "worker thinking\n"})));
        let calls: Vec<&Entry> = model.conversations["s1"]
            .entries.iter().filter(|entry| entry.role == Role::Tool).collect();
        assert_eq!(calls[1].output, vec!["compiling"]);
        assert_eq!(calls[0].output, vec!["worker thinking"],
                   "output after the inner call finished did not fall back to the delegate");
    }

    #[test]
    fn output_goes_to_the_running_call_not_the_first_one() {
        // Two calls in a turn: the second one's output must not land on the
        // first. Appending to entries[0] would look right in a one-call turn
        // and be wrong in every other.
        let mut model = model_with("s1");
        for (command, out) in [("ls", "first"), ("cat x", "second")] {
            model.absorb(&event("tool.started", "s1",
                                json!({"call": {"name": "bash",
                                                "arguments": {"command": command}}})));
            model.absorb(&event("tool.output", "s1", json!({"text": format!("{out}\n")})));
        }
        let calls: Vec<_> = model.conversations["s1"]
            .entries.iter().filter(|e| e.role == Role::Tool).collect();
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0].output, vec!["first"]);
        assert_eq!(calls[1].output, vec!["second"]);
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
