//! How long a frame takes, with a conversation the size of a real one.
//!
//! A number rather than an impression. "Feels slow" is a report; this is the
//! thing that either changed or did not.

#[cfg(test)]
mod tests {
    use crate::model::Model;
    use crate::protocol::{Event, SessionInfo};
    use crate::ui;
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;
    use serde_json::json;
    use std::time::Instant;

    fn big_model(turns: usize) -> Model {
        let mut model = Model::new("/w".into());
        model.sessions = vec![SessionInfo {
            id: "s1".into(),
            label: "/w/alpha".into(),
            state: "idle".into(),
            ..Default::default()
        }];
        model.open_tab("s1");
        for turn in 0..turns {
            let ask: Event = serde_json::from_value(json!({
                "event": "user.message", "session": "s1", "seq": turn,
                "data": {"text": format!("question number {turn}")}
            })).unwrap();
            model.absorb(&ask);
            for line in 0..12 {
                let say: Event = serde_json::from_value(json!({
                    "event": "model.delta", "session": "s1", "seq": turn,
                    "data": {"text": format!("answer {turn} line {line} with enough text on it to wrap once or twice at a hundred columns\n")}
                })).unwrap();
                model.absorb(&say);
            }
        }
        model
    }

    #[test]
    fn a_frame_is_drawn_in_under_a_frame() {
        // 120 turns is a long afternoon, not an extreme. At sixty frames a
        // second a frame has 16ms; a client that takes longer than that to
        // decide what to draw cannot feel immediate however fast the terminal
        // is.
        let model = big_model(120);
        let mut terminal = Terminal::new(TestBackend::new(120, 40)).unwrap();
        // Warm once, so the number is steady-state rather than first-touch.
        let mut rendered = ui::Rendered::default();
        terminal.draw(|frame| { ui::draw(frame, &model, &mut rendered); }).unwrap();

        let rounds = 20;
        let started = Instant::now();
        for _ in 0..rounds {
            terminal.draw(|frame| { ui::draw(frame, &model, &mut rendered); }).unwrap();
        }
        let each = started.elapsed() / rounds;
        println!("draw with {} entries: {:?} per frame",
                 model.current_conversation().unwrap().entries.len(), each);
        assert!(
            each.as_millis() < 16,
            "a frame took {each:?}, which is longer than a frame at 60fps"
        );
    }

    #[test]
    fn scrolling_does_not_get_slower_the_longer_the_conversation() {
        // Scrolling re-wraps whatever the renderer decides to re-wrap. If that
        // is the whole transcript, every keypress costs the length of the
        // session -- which is exactly the shape of "it felt fine and then it
        // did not".
        let short = big_model(10);
        let long = big_model(200);
        let mut terminal = Terminal::new(TestBackend::new(120, 40)).unwrap();

        let time = |model: &Model, terminal: &mut Terminal<TestBackend>| {
            let mut rendered = ui::Rendered::default();
            terminal.draw(|frame| { ui::draw(frame, model, &mut rendered); }).unwrap();
            let started = Instant::now();
            for _ in 0..10 {
                terminal.draw(|frame| { ui::draw(frame, model, &mut rendered); }).unwrap();
            }
            started.elapsed() / 10
        };
        let quick = time(&short, &mut terminal);
        let slow = time(&long, &mut terminal);
        println!("10 turns: {quick:?}   200 turns: {slow:?}");
        assert!(
            slow.as_micros() < quick.as_micros().max(1) * 6,
            "twenty times the conversation cost {}x the frame ({quick:?} -> {slow:?})",
            slow.as_micros() / quick.as_micros().max(1)
        );
    }
}
