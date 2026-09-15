//! What the client asks the daemon, and what it does with each answer.
//!
//! Nothing here waits. A request is written and remembered, and its answer is
//! one more line on the stream the loop already reads, handled when it lands.
//! The daemon answers one connection's requests in order, so a slow session
//! start delays every answer behind it -- and the client goes on drawing and
//! reading keys meanwhile.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::model::{self, Model};
use crate::protocol::{self, Connection, Recorded, SessionInfo};

/// What a request was for, so its answer knows where to go.
pub enum Awaiting {
    Recent,
    Learned,
    Sessions,
    Models,
    /// A subscription to this session. Its replay arrives as events ahead of
    /// the answer.
    Attached(String),
    /// A session asked to start, fresh or resuming one, to open once it exists.
    Started,
    /// Another model for a session. Its `session.model` events say when it lands.
    Switched,
    /// A session to delete, forgotten here once the daemon says it is gone.
    Deleted(String),
    Search,
}

struct Asked {
    awaiting: Awaiting,
    /// None once overdue. An answer that comes after that is still used.
    deadline: Option<Instant>,
    /// What the status said when this went overdue, taken back when it lands.
    note: Option<&'static str>,
}

/// Requests written and not yet answered.
#[derive(Default)]
pub struct Requests {
    asked: HashMap<u64, Asked>,
    /// Only the newest search may fill the picker: an older answer landing late
    /// would show results for what was typed before.
    latest_search: Option<u64>,
}

impl Requests {
    fn expect(&mut self, id: u64, awaiting: Awaiting, patience: Duration) {
        let deadline = Some(Instant::now() + patience);
        self.asked.insert(id, Asked { awaiting, deadline, note: None });
    }

    /// When a request goes overdue if nothing answers it first.
    pub fn next_deadline(&self) -> Option<Instant> {
        self.asked.values().filter_map(|asked| asked.deadline).min()
    }

    /// Say in the status what a person is still waiting on. True if anything
    /// went overdue since the last call.
    pub fn expire(&mut self, model: &mut Model, now: Instant) -> bool {
        let mut any = false;
        for (id, asked) in &mut self.asked {
            if asked.deadline.is_some_and(|deadline| deadline <= now) {
                asked.deadline = None;
                asked.note = overdue(&asked.awaiting, *id, self.latest_search);
                if let Some(note) = asked.note {
                    model.status = note.into();
                }
                any = true;
            }
        }
        any
    }

    /// A new connection numbers its requests from one again, so nothing asked
    /// on the old one will be answered, and nothing is still being looked for.
    pub fn forget(&mut self, model: &mut Model) {
        self.asked.clear();
        self.latest_search = None;
        model.picker.searching = false;
        model.models.refreshing = false;
    }
}

fn overdue(awaiting: &Awaiting, id: u64, latest_search: Option<u64>) -> Option<&'static str> {
    match awaiting {
        Awaiting::Search if latest_search == Some(id) => Some("the daemon has not answered the search yet"),
        Awaiting::Models => Some("the daemon has not listed its models yet"),
        Awaiting::Started => Some("the daemon has not started the session yet"),
        Awaiting::Switched => Some("the daemon has not changed the model yet"),
        Awaiting::Deleted(_) => Some("the daemon has not deleted the session yet"),
        Awaiting::Attached(_) => Some("the daemon has not sent the session yet"),
        _ => None,
    }
}

impl Requests {
    pub fn ask_recent(&mut self, connection: &mut Connection, model: &Model) -> std::io::Result<()> {
        let id = connection.send(json!({"type": "session.recorded", "cwd": model.cwd, "limit": 50}))?;
        self.expect(id, Awaiting::Recent, Duration::from_secs(5));
        Ok(())
    }

    pub fn ask_learned(&mut self, connection: &mut Connection, model: &Model) -> std::io::Result<()> {
        if model.current.is_empty() {
            return Ok(());
        }
        let id = connection.send(json!({"type": "session.inspect", "session": model.current}))?;
        self.expect(id, Awaiting::Learned, Duration::from_secs(15));
        Ok(())
    }

    pub fn ask_sessions(&mut self, connection: &mut Connection) -> std::io::Result<()> {
        let id = connection.send(json!({"type": "session.list"}))?;
        self.expect(id, Awaiting::Sessions, Duration::from_secs(10));
        Ok(())
    }

    /// Longer than the others: a refresh reaches every local model server, and
    /// one that is not running is a bounded wait each.
    pub fn ask_models(&mut self, connection: &mut Connection, refresh: bool) -> std::io::Result<()> {
        let id = connection.send(json!({"type": "models", "refresh": refresh}))?;
        self.expect(id, Awaiting::Models, Duration::from_secs(20));
        Ok(())
    }

    /// Subscribe from the beginning, unless this client holds the session or
    /// is already waiting for it. The daemon replays everything on every
    /// attach, so a second one would show each turn twice.
    pub fn attach(&mut self, connection: &mut Connection, model: &Model, session: &str) -> std::io::Result<()> {
        let held = model
            .conversations
            .get(session)
            .map(|conversation| !conversation.entries.is_empty())
            .unwrap_or(false);
        let on_the_way = self
            .asked
            .values()
            .any(|asked| matches!(&asked.awaiting, Awaiting::Attached(pending) if pending == session));
        if held || on_the_way {
            return Ok(());
        }
        let id = connection.send(json!({"type": "session.attach", "session": session, "since": 0}))?;
        self.expect(id, Awaiting::Attached(session.to_string()), Duration::from_secs(20));
        Ok(())
    }

    pub fn open(&mut self, connection: &mut Connection, model: &mut Model, session: &str) -> std::io::Result<()> {
        model.open_tab(session);
        self.attach(connection, model, session)
    }

    /// A session here, on the named model when there is one.
    pub fn start(&mut self, connection: &mut Connection, model: &Model, named: Option<&str>) -> std::io::Result<()> {
        let mut request = json!({"type": "session.start", "cwd": model.cwd});
        if let Some(named) = named {
            request["model"] = json!(named);
        }
        let id = connection.send(request)?;
        self.expect(id, Awaiting::Started, Duration::from_secs(30));
        Ok(())
    }

    /// A recorded conversation continued in a new session, in the directory it
    /// was recorded in: the daemon looks for it there, and one resumed anywhere
    /// else starts empty and looks like history that failed to load.
    pub fn resume(&mut self, connection: &mut Connection, model: &Model, recorded: &str, cwd: &str) -> std::io::Result<()> {
        let cwd = if cwd.is_empty() { model.cwd.as_str() } else { cwd };
        let id = connection.send(json!({"type": "session.start", "cwd": cwd, "resume": recorded}))?;
        self.expect(id, Awaiting::Started, Duration::from_secs(60));
        Ok(())
    }

    /// Answer on another model in SESSION, from its next turn.
    pub fn switch_model(&mut self, connection: &mut Connection, session: &str, label: &str) -> std::io::Result<()> {
        let id = connection.send(json!({"type": "session.model", "session": session, "model": label}))?;
        self.expect(id, Awaiting::Switched, Duration::from_secs(20));
        Ok(())
    }

    /// Delete SESSION. Longer than most: a running session is stopped first,
    /// and the daemon gives that half a minute.
    pub fn delete(&mut self, connection: &mut Connection, session: &str) -> std::io::Result<()> {
        let id = connection.send(json!({"type": "session.delete", "session": session}))?;
        self.expect(id, Awaiting::Deleted(session.to_string()), Duration::from_secs(40));
        Ok(())
    }

    pub fn search(&mut self, connection: &mut Connection, text: &str) -> std::io::Result<()> {
        let request = if text.trim().is_empty() {
            json!({"type": "session.recorded", "limit": 50})
        } else {
            json!({"type": "session.search", "text": text, "limit": 50})
        };
        let id = connection.send(request)?;
        self.expect(id, Awaiting::Search, Duration::from_secs(15));
        self.latest_search = Some(id);
        Ok(())
    }
}

impl Requests {
    /// Handle the answer to something this client asked. False when it asked
    /// nothing with that id, which leaves the answer to the caller.
    pub fn answered(&mut self, connection: &mut Connection, model: &mut Model, reply: &Value) -> std::io::Result<bool> {
        let Some(id) = reply.get("id").and_then(Value::as_u64) else {
            return Ok(false);
        };
        let Some(asked) = self.asked.remove(&id) else {
            return Ok(false);
        };
        if asked.note.is_some_and(|note| model.status == note) {
            model.status.clear();
        }
        match asked.awaiting {
            Awaiting::Recent => {
                if let Some(found) = recorded(reply) {
                    model.recent = found;
                }
            }
            Awaiting::Learned => model.learned = protocol::Learned::from_reply(reply),
            Awaiting::Sessions => take_sessions(model, reply),
            Awaiting::Models => {
                model.models.refreshing = false;
                match reply.get("models").and_then(Value::as_array) {
                    Some(array) => model.models.absorb(
                        array
                            .iter()
                            .filter_map(|value| serde_json::from_value::<model::ModelOffer>(value.clone()).ok())
                            .collect(),
                    ),
                    None => take_response(model, reply),
                }
            }
            Awaiting::Attached(_) | Awaiting::Switched => take_response(model, reply),
            Awaiting::Deleted(session) => {
                if reply.get("success").and_then(Value::as_bool) == Some(true) {
                    model.forget_session(&session);
                    model.status = "session deleted".into();
                    self.ask_sessions(connection)?;
                    self.ask_recent(connection, model)?;
                } else {
                    take_response(model, reply);
                }
            }
            Awaiting::Started => match started(reply) {
                Some(session) => {
                    model.open_tab(&session);
                    self.ask_sessions(connection)?;
                    self.attach(connection, model, &session)?;
                    self.ask_learned(connection, model)?;
                }
                // A refusal has to say why, or the pane just keeps waiting.
                None => take_response(model, reply),
            },
            Awaiting::Search => {
                if self.latest_search == Some(id) {
                    model.picker.searching = false;
                    if let Some(found) = recorded(reply) {
                        model.picker.results = found;
                        model.picker.selection = 0;
                    }
                }
            }
        }
        Ok(true)
    }

    /// The daemon has said hello, first or after a lost connection. With no tab
    /// open this opens the session in this directory, or starts one. With tabs
    /// open each is read again from the start: a restarted daemon numbers its
    /// streams from one, so folding its replay onto what is held would show
    /// every turn twice.
    pub fn greeted(&mut self, connection: &mut Connection, model: &mut Model, greeting: &Value) -> std::io::Result<()> {
        take_sessions(model, greeting);
        model.connected = true;
        if model.tabs.is_empty() {
            let here = model
                .sessions
                .iter()
                .find(|session| session.cwd.trim_end_matches('/') == model.cwd.trim_end_matches('/'))
                .map(|session| session.id.clone());
            match here {
                Some(session) => self.open(connection, model, &session)?,
                None => self.start(connection, model, None)?,
            }
        } else {
            model.conversations.clear();
            for session in model.tabs.clone() {
                model.conversation(&session);
                self.attach(connection, model, &session)?;
            }
            model.status = "reconnected".into();
        }
        self.ask_learned(connection, model)?;
        self.ask_recent(connection, model)
    }
}

fn started(reply: &Value) -> Option<String> {
    reply.get("session")?.get("id")?.as_str().map(str::to_string)
}

fn recorded(reply: &Value) -> Option<Vec<Recorded>> {
    let found = reply.get("recorded")?.as_array()?;
    Some(found.iter().filter_map(|value| serde_json::from_value::<Recorded>(value.clone()).ok()).collect())
}

/// One row's worth of a message that may have been written for a shell. The
/// status line is one row, and an error carrying newlines and indentation
/// rendered there as nothing at all.
fn one_line(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

pub fn take_response(model: &mut Model, reply: &Value) {
    if reply.get("sessions").is_some() {
        take_sessions(model, reply);
    } else if reply.get("success").and_then(Value::as_bool) == Some(false) {
        if let Some(error) = reply.get("error").and_then(Value::as_str) {
            model.status = one_line(error);
        }
    }
}

fn take_sessions(model: &mut Model, reply: &Value) {
    let Some(array) = reply.get("sessions").and_then(Value::as_array) else {
        return;
    };
    model.sessions = array
        .iter()
        .filter_map(|value| serde_json::from_value::<SessionInfo>(value.clone()).ok())
        .collect();
    model.prune_tabs();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::Event;
    use std::io::{BufRead, BufReader};
    use std::os::unix::net::UnixStream;

    /// A connection, and the daemon's end of it, which answers nothing.
    struct Wire {
        connection: Connection,
        daemon: BufReader<UnixStream>,
    }

    impl Wire {
        fn new() -> Wire {
            let (ours, theirs) = UnixStream::pair().expect("a socket pair");
            theirs.set_read_timeout(Some(Duration::from_millis(50))).expect("a read timeout");
            Wire { connection: Connection::over(ours, crate::wake::bell().0).expect("a connection"), daemon: BufReader::new(theirs) }
        }

        /// Every request that reached the daemon since the last call.
        fn written(&mut self) -> Vec<Value> {
            let mut requests = Vec::new();
            let mut line = String::new();
            while matches!(self.daemon.read_line(&mut line), Ok(read) if read > 0) {
                requests.push(serde_json::from_str(&line).expect("a request is one JSON line"));
                line.clear();
            }
            requests
        }
    }

    fn kinds(requests: &[Value]) -> Vec<&str> {
        requests.iter().map(|request| request["type"].as_str().unwrap_or("")).collect()
    }

    fn reply(id: u64, fields: Value) -> Value {
        let mut value = json!({"type": "response", "id": id, "success": true});
        if let (Some(target), Some(extra)) = (value.as_object_mut(), fields.as_object()) {
            for (key, field) in extra {
                target.insert(key.clone(), field.clone());
            }
        }
        value
    }

    #[test]
    fn an_answer_goes_where_its_question_said() {
        let mut wire = Wire::new();
        let mut model = Model::new("/w".into());
        let mut asked = Requests::default();
        asked.ask_sessions(&mut wire.connection).unwrap();
        let sessions = json!({"sessions": [{"id": "s1", "cwd": "/w"}]});
        assert!(asked.answered(&mut wire.connection, &mut model, &reply(1, sessions)).unwrap());
        assert_eq!(model.sessions.len(), 1);
        assert!(asked.asked.is_empty(), "an answered request is still waiting");
    }

    #[test]
    fn an_answer_nobody_asked_for_is_left_to_the_caller() {
        let mut wire = Wire::new();
        let mut model = Model::new("/w".into());
        let mut asked = Requests::default();
        assert!(!asked.answered(&mut wire.connection, &mut model, &reply(99, json!({}))).unwrap());
    }

    #[test]
    fn a_late_answer_to_an_older_search_does_not_replace_a_newer_one() {
        let mut wire = Wire::new();
        let mut model = Model::new("/w".into());
        let mut asked = Requests::default();
        model.picker.searching = true;
        asked.search(&mut wire.connection, "old").unwrap();
        asked.search(&mut wire.connection, "new").unwrap();
        asked.answered(&mut wire.connection, &mut model, &reply(1, json!({"recorded": [{"id": "stale"}]}))).unwrap();
        assert!(model.picker.results.is_empty(), "the older search filled the picker");
        assert!(model.picker.searching, "the older search ended the newer one");
        asked.answered(&mut wire.connection, &mut model, &reply(2, json!({"recorded": [{"id": "fresh"}]}))).unwrap();
        assert_eq!(model.picker.results[0].id, "fresh");
        assert!(!model.picker.searching);
    }

    #[test]
    fn a_search_nobody_answers_says_so_and_keeps_looking() {
        let mut wire = Wire::new();
        let mut model = Model::new("/w".into());
        let mut asked = Requests::default();
        model.picker.searching = true;
        asked.search(&mut wire.connection, "anything").unwrap();
        assert!(!asked.expire(&mut model, Instant::now()), "overdue before the deadline");
        assert!(asked.expire(&mut model, Instant::now() + Duration::from_secs(16)));
        assert!(model.picker.searching, "an unanswered search claimed nothing was found");
        assert_eq!(model.status, "the daemon has not answered the search yet");
        asked.answered(&mut wire.connection, &mut model, &reply(1, json!({"recorded": [{"id": "r1"}]}))).unwrap();
        assert_eq!(model.picker.results[0].id, "r1");
        assert!(!model.picker.searching);
        assert!(model.status.is_empty(), "the note outlived the answer: {}", model.status);
    }

    #[test]
    fn an_overdue_start_still_opens_its_session_when_the_answer_lands() {
        let mut wire = Wire::new();
        let mut model = Model::new("/w".into());
        let mut asked = Requests::default();
        asked.start(&mut wire.connection, &model, None).unwrap();
        let late = Instant::now() + Duration::from_secs(31);
        assert!(asked.next_deadline().is_some_and(|deadline| deadline < late));
        assert!(asked.expire(&mut model, late));
        assert_eq!(asked.next_deadline(), None, "an overdue request would go on waking the loop");
        assert_eq!(model.status, "the daemon has not started the session yet");
        assert!(!asked.expire(&mut model, late), "the same request went overdue twice");
        asked.answered(&mut wire.connection, &mut model, &reply(1, json!({"session": {"id": "s9"}}))).unwrap();
        assert_eq!(model.current, "s9");
        assert!(model.status.is_empty(), "the note outlived the answer: {}", model.status);
        assert_eq!(kinds(&wire.written()), ["session.start", "session.list", "session.attach", "session.inspect"]);
    }

    #[test]
    fn a_session_is_attached_once_while_its_replay_is_on_the_way() {
        let mut wire = Wire::new();
        let model = Model::new("/w".into());
        let mut asked = Requests::default();
        asked.attach(&mut wire.connection, &model, "s1").unwrap();
        asked.attach(&mut wire.connection, &model, "s1").unwrap();
        assert_eq!(kinds(&wire.written()), ["session.attach"], "a second attach replays the session again");
    }

    #[test]
    fn a_new_connection_forgets_what_the_old_one_asked() {
        let mut wire = Wire::new();
        let mut model = Model::new("/w".into());
        let mut asked = Requests::default();
        model.models.refreshing = true;
        asked.ask_models(&mut wire.connection, false).unwrap();
        asked.forget(&mut model);
        assert!(asked.asked.is_empty());
        assert!(!model.models.refreshing, "a forgotten request left its spinner running");
    }

    #[test]
    fn a_first_greeting_opens_the_session_in_this_directory() {
        let mut wire = Wire::new();
        let mut model = Model::new("/w".into());
        let mut asked = Requests::default();
        let greeting = json!({"sessions": [{"id": "far", "cwd": "/elsewhere"}, {"id": "here", "cwd": "/w/"}]});
        asked.greeted(&mut wire.connection, &mut model, &greeting).unwrap();
        assert_eq!(model.tabs, ["here"]);
        assert_eq!(kinds(&wire.written()), ["session.attach", "session.inspect", "session.recorded"]);
    }

    #[test]
    fn a_first_greeting_with_no_session_here_starts_one() {
        let mut wire = Wire::new();
        let mut model = Model::new("/w".into());
        let mut asked = Requests::default();
        let greeting = json!({"sessions": [{"id": "far", "cwd": "/elsewhere"}]});
        asked.greeted(&mut wire.connection, &mut model, &greeting).unwrap();
        let written = wire.written();
        assert_eq!(kinds(&written), ["session.start", "session.recorded"]);
        assert_eq!(written[0]["cwd"], "/w");
        assert!(model.tabs.is_empty(), "a tab opened before its session existed");
    }

    #[test]
    fn a_greeting_after_a_loss_reads_every_open_tab_again() {
        let mut wire = Wire::new();
        let mut model = Model::new("/w".into());
        let mut asked = Requests::default();
        model.open_tab("s1");
        let said = json!({"event": "user.message", "session": "s1", "seq": 1, "data": {"text": "hello"}});
        model.absorb(&serde_json::from_value::<Event>(said).expect("an event"));
        assert!(!model.conversations["s1"].entries.is_empty(), "the fixture holds nothing");
        let greeting = json!({"sessions": [{"id": "s1", "cwd": "/w"}]});
        asked.greeted(&mut wire.connection, &mut model, &greeting).unwrap();
        assert!(model.conversations["s1"].entries.is_empty(), "the replay would land on what is held");
        let written = wire.written();
        assert_eq!(kinds(&written), ["session.attach", "session.inspect", "session.recorded"]);
        assert_eq!(written[0]["since"], 0);
        assert_eq!(model.status, "reconnected");
    }

    #[test]
    fn a_model_switch_names_the_session_and_the_model() {
        let mut wire = Wire::new();
        let mut asked = Requests::default();
        asked.switch_model(&mut wire.connection, "s1", "local/qwen").unwrap();
        let written = wire.written();
        assert_eq!(kinds(&written), ["session.model"]);
        assert_eq!(written[0]["session"], "s1");
        assert_eq!(written[0]["model"], "local/qwen");
    }

    #[test]
    fn a_deleted_session_is_forgotten_only_once_the_daemon_says_it_is_gone() {
        let mut wire = Wire::new();
        let mut model = Model::new("/w".into());
        let mut asked = Requests::default();
        model.open_tab("s1");
        model.recent = vec![Recorded { id: "s1".into(), messages: 2, ..Default::default() }];
        asked.delete(&mut wire.connection, "s1").unwrap();
        let refused = json!({"success": false, "error": "That session is in the middle of a turn; stop it first."});
        asked.answered(&mut wire.connection, &mut model, &reply(1, refused)).unwrap();
        assert_eq!(model.tabs, ["s1"], "a refused delete closed the tab");
        assert!(model.status.contains("stop it first"), "the refusal was not said: {}", model.status);
        asked.delete(&mut wire.connection, "s1").unwrap();
        let gone = json!({"success": true, "session": "s1", "files": 2});
        asked.answered(&mut wire.connection, &mut model, &reply(2, gone)).unwrap();
        assert!(model.tabs.is_empty() && model.recent.is_empty(), "the deleted session is still held");
        let written = wire.written();
        assert_eq!(kinds(&written), ["session.delete", "session.delete", "session.list", "session.recorded"]);
        assert_eq!(written[0]["session"], "s1");
    }

    #[test]
    fn a_message_written_for_a_shell_becomes_one_row() {
        let shell = "No model is configured. Put a key in:\n\n  {\n    \"a\": 1\n  }\n";
        assert_eq!(one_line(shell), "No model is configured. Put a key in: { \"a\": 1 }");
        assert_eq!(one_line("already one row"), "already one row");
    }
}
