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

    /// One streamed token, at three conversation sizes.
    ///
    /// The drawing is windowed -- only the rows a pane can show are touched --
    /// but the LAYOUT is not: a changed conversation is wrapped from the top,
    /// and a token changes the conversation. If that cost grows with the
    /// session, then a long one gets slower at exactly the moment a person is
    /// watching output arrive.
    #[test]
    fn a_streamed_token_does_not_cost_the_whole_session() {
        let mut costs = Vec::new();
        for turns in [10usize, 100, 400] {
            let mut model = big_model(turns);
            let mut terminal = Terminal::new(TestBackend::new(120, 40)).unwrap();
            let mut rendered = ui::Rendered::default();
            terminal.draw(|frame| { ui::draw(frame, &mut model, &mut rendered); }).unwrap();

            let rounds = 30;
            let started = Instant::now();
            for round in 0..rounds {
                let say: Event = serde_json::from_value(json!({
                    "event": "model.delta", "session": "s1", "seq": 90000 + round,
                    "data": {"text": "another word "}
                })).unwrap();
                model.absorb(&say);
                terminal.draw(|frame| { ui::draw(frame, &mut model, &mut rendered); }).unwrap();
            }
            let each = started.elapsed() / rounds as u32;
            println!("{turns:>4} turns: {each:?} per streamed token");
            costs.push((turns, each.as_secs_f64() * 1000.0));
        }
        let (_, small) = costs[0];
        let (_, large) = costs[2];
        println!("10 turns {small:.2}ms -> 400 turns {large:.2}ms  ({:.1}x)", large / small.max(0.001));
        assert!(large < 16.0,
                "a token costs {large:.2}ms at 400 turns, which is longer than a frame");
        // FLAT, not merely fast. An absolute bound passes on a machine quick
        // enough to hide a cost that still grows with the session, and the
        // complaint is always about the long session.
        assert!(large < small * 3.0,
                "a token costs {:.1}x more at 400 turns than at 10 ({small:.2}ms -> {large:.2}ms)",
                large / small.max(0.001));
    }

    #[test]
    fn a_frame_is_drawn_in_under_a_frame() {
        // 120 turns is a long afternoon, not an extreme. At sixty frames a
        // second a frame has 16ms; a client that takes longer than that to
        // decide what to draw cannot feel immediate however fast the terminal
        // is.
        let mut model = big_model(120);
        let mut terminal = Terminal::new(TestBackend::new(120, 40)).unwrap();
        // Warm once, so the number is steady-state rather than first-touch.
        let mut rendered = ui::Rendered::default();
        terminal.draw(|frame| { ui::draw(frame, &mut model, &mut rendered); }).unwrap();

        let rounds = 20;
        let started = Instant::now();
        for _ in 0..rounds {
            terminal.draw(|frame| { ui::draw(frame, &mut model, &mut rendered); }).unwrap();
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
        // IT HAS TO ACTUALLY SCROLL. This drew the same frame ten times and
        // called the number a scrolling cost -- a redraw benchmark wearing a
        // scrolling name, which would have reported `flat` however expensive
        // moving the window had become.
        //
        // Scrolling moves the window and nothing else: the layout is already
        // done and the entries have not changed, so the cost is finding the
        // rows and handing ratatui a frame that differs from the last one. If
        // that grows with the session, every keypress costs the length of the
        // conversation -- which is the shape of "it felt fine and then it did
        // not".
        let mut short = big_model(10);
        let mut long = big_model(400);
        let mut terminal = Terminal::new(TestBackend::new(120, 40)).unwrap();

        let time = |model: &mut Model, terminal: &mut Terminal<TestBackend>| {
            let mut rendered = ui::Rendered::default();
            terminal.draw(|frame| { ui::draw(frame, model, &mut rendered); }).unwrap();
            let rounds = 40;
            let started = Instant::now();
            for round in 0..rounds {
                if let Some(conversation) = model.conversations.get_mut("s1") {
                    // Up for half of them and down for the other half, so the
                    // run neither runs out of transcript nor sits at an end
                    // where the window stops moving and the frames stop
                    // differing -- which would measure nothing.
                    conversation.scroll_by(if round < rounds / 2 { 3 } else { -3 });
                    while conversation.settle() {}
                }
                terminal.draw(|frame| { ui::draw(frame, model, &mut rendered); }).unwrap();
            }
            started.elapsed() / rounds as u32
        };
        let quick = time(&mut short, &mut terminal);
        let slow = time(&mut long, &mut terminal);
        println!("one scroll step: 10 turns {quick:?}   400 turns {slow:?}");
        assert!(
            slow.as_micros() < quick.as_micros().max(1) * 6,
            "forty times the conversation cost {}x the scroll ({quick:?} -> {slow:?})",
            slow.as_micros() / quick.as_micros().max(1)
        );
    }
}
