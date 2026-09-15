//! How long a frame takes, with a conversation the size of a real one.
//!
//! A number rather than an impression. "Feels slow" is a report; this is the
//! thing that either changed or did not.

#[cfg(test)]
mod tests {
    use crate::model::Model;
    use crate::protocol::{Event, SessionInfo};
    use crate::layout;
    use crate::ui;
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;
    use serde_json::json;
    use std::time::Instant;

    /// The budget for one frame, which depends on how the crate was built.
    ///
    /// 16ms is a claim about the SHIPPED client at sixty frames a second.
    /// `cargo test` builds unoptimised, where the same draw costs 3.6ms against
    /// 0.69ms release on one machine -- so the bound passed here and failed on
    /// a CI runner at 16.85ms, reporting the profile rather than the code.
    /// Debug carries the same claim scaled by that measured 5.2x, which still
    /// catches a draw that got slow without failing for being a debug build.
    fn frame_budget_ms() -> f64 {
        if cfg!(debug_assertions) { 16.0 * 5.2 } else { 16.0 }
    }

    fn big_model(turns: usize) -> Model {
        model_saying(turns, |turn, line| {
            format!("answer {turn} line {line} with enough text on it to wrap once or twice at a hundred columns\n")
        })
    }

    /// TURNS questions, each answered in twelve lines that SAY writes.
    fn model_saying(turns: usize, say: impl Fn(usize, usize) -> String) -> Model {
        let mut model = Model::new("/w".into());
        model.sessions = vec![SessionInfo {
            id: "s1".into(),
            label: "/w/alpha".into(),
            state: "idle".into(),
            ..Default::default()
        }];
        model.open_tab("s1");
        converse(&mut model, "s1", turns, say);
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
            let mut rendered = layout::Rendered::default();
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
        let budget = frame_budget_ms();
        assert!(large < budget,
                "a token costs {large:.2}ms at 400 turns, over the {budget:.0}ms a frame has");
        // FLAT, not merely fast. An absolute bound passes on a machine quick
        // enough to hide a cost that still grows with the session, and the
        // complaint is always about the long session.
        assert!(large < small * 3.0,
                "a token costs {:.1}x more at 400 turns than at 10 ({small:.2}ms -> {large:.2}ms)",
                large / small.max(0.001));
    }

    /// A token in a conversation written two cells a character. A grapheme
    /// outside ASCII is measured through Unicode's tables, and a conversation
    /// in Japanese must not be the slow one.
    #[test]
    fn a_wide_transcript_streams_within_a_frame() {
        let mut model = model_saying(400, |turn, line| {
            format!("答え{turn}の{line}行目、百桁で一度か二度は折り返すくらいの長さがある文章です\n")
        });
        let mut terminal = Terminal::new(TestBackend::new(120, 40)).unwrap();
        let mut rendered = layout::Rendered::default();
        terminal.draw(|frame| { ui::draw(frame, &mut model, &mut rendered); }).unwrap();
        let rounds = 30;
        let started = Instant::now();
        for round in 0..rounds {
            let say: Event = serde_json::from_value(json!({
                "event": "model.delta", "session": "s1", "seq": 90000 + round,
                "data": {"text": "もう一語 "}
            })).unwrap();
            model.absorb(&say);
            terminal.draw(|frame| { ui::draw(frame, &mut model, &mut rendered); }).unwrap();
        }
        let each = started.elapsed().as_secs_f64() * 1000.0 / rounds as f64;
        println!("400 wide turns: {each:.2}ms per streamed token");
        let budget = frame_budget_ms();
        assert!(each < budget, "a wide token costs {each:.2}ms, over the {budget:.0}ms a frame has");
    }

    /// TURNS more questions in SESSION, each answered in twelve lines SAY writes.
    fn converse(model: &mut Model, session: &str, turns: usize, say: impl Fn(usize, usize) -> String) {
        for turn in 0..turns {
            let ask: Event = serde_json::from_value(json!({
                "event": "user.message", "session": session, "seq": turn,
                "data": {"text": format!("question number {turn}")}
            })).unwrap();
            model.absorb(&ask);
            for line in 0..12 {
                let said: Event = serde_json::from_value(json!({
                    "event": "model.delta", "session": session, "seq": turn,
                    "data": {"text": say(turn, line)}
                })).unwrap();
                model.absorb(&said);
            }
        }
    }

    fn delta(text: &str) -> Event {
        serde_json::from_value(json!({
            "event": "model.delta", "session": "s1", "seq": 0, "data": {"text": text}
        })).unwrap()
    }

    /// Milliseconds a draw takes after each of ROUNDS calls to STEP.
    fn per_draw(
        model: &mut Model,
        terminal: &mut Terminal<TestBackend>,
        rendered: &mut layout::Rendered,
        rounds: usize,
        mut step: impl FnMut(usize, &mut Model, &mut Terminal<TestBackend>),
    ) -> f64 {
        let started = Instant::now();
        for round in 0..rounds {
            step(round, model, terminal);
            terminal.draw(|frame| { ui::draw(frame, model, rendered); }).unwrap();
        }
        started.elapsed().as_secs_f64() * 1000.0 / rounds as f64
    }

    #[test]
    fn switching_tabs_does_not_lay_out_a_conversation_again() {
        let mut model = big_model(400);
        model.sessions.push(SessionInfo {
            id: "s2".into(), label: "/w/beta".into(), state: "idle".into(), ..Default::default()
        });
        converse(&mut model, "s2", 400, |turn, line| {
            format!("the other session, turn {turn} line {line}, with text enough to wrap at a hundred columns\n")
        });
        let mut terminal = Terminal::new(TestBackend::new(120, 40)).unwrap();
        let mut rendered = layout::Rendered::default();
        for id in ["s1", "s2"] {
            model.open_tab(id);
            terminal.draw(|frame| { ui::draw(frame, &mut model, &mut rendered); }).unwrap();
        }
        let still = per_draw(&mut model, &mut terminal, &mut rendered, 20, |_, _, _| {});
        let switching = per_draw(&mut model, &mut terminal, &mut rendered, 20, |round, model, _| {
            model.open_tab(if round % 2 == 0 { "s1" } else { "s2" });
        });
        println!("tab switch, two 400-turn sessions: {switching:.2}ms  (a frame that changes nothing: {still:.2}ms)");
        let budget = frame_budget_ms();
        assert!(switching < budget, "a tab switch costs {switching:.2}ms, over the {budget:.0}ms a frame has");
        assert!(switching < still * 3.0 + 0.5,
                "a tab switch costs {switching:.2}ms against {still:.2}ms for a frame that changes nothing");
    }

    #[test]
    fn a_page_width_seen_before_is_not_laid_out_again() {
        let mut model = big_model(400);
        let mut terminal = Terminal::new(TestBackend::new(120, 40)).unwrap();
        let mut rendered = layout::Rendered::default();
        for shown in [false, true] {
            model.sidebar = shown;
            terminal.draw(|frame| { ui::draw(frame, &mut model, &mut rendered); }).unwrap();
        }
        let still = per_draw(&mut model, &mut terminal, &mut rendered, 20, |_, _, _| {});
        let toggling = per_draw(&mut model, &mut terminal, &mut rendered, 20, |round, model, _| {
            model.sidebar = round % 2 == 0;
        });
        println!("sessions column toggled, 400 turns: {toggling:.2}ms a frame  (a frame that changes nothing: {still:.2}ms)");
        let budget = frame_budget_ms();
        assert!(toggling < budget, "a toggle costs {toggling:.2}ms, over the {budget:.0}ms a frame has");
        assert!(toggling < still * 3.0 + 0.5,
                "a toggle costs {toggling:.2}ms against {still:.2}ms for a frame that changes nothing");
    }

    #[test]
    fn a_new_page_width_is_laid_out_within_a_frame() {
        let mut model = big_model(400);
        let mut terminal = Terminal::new(TestBackend::new(120, 40)).unwrap();
        let mut rendered = layout::Rendered::default();
        terminal.draw(|frame| { ui::draw(frame, &mut model, &mut rendered); }).unwrap();
        let dragging = per_draw(&mut model, &mut terminal, &mut rendered, 20, |round, _, terminal| {
            terminal.backend_mut().resize(119 - round as u16, 40);
        });
        println!("resized to a width not seen before, 400 turns: {dragging:.2}ms a frame");
        let budget = frame_budget_ms();
        assert!(dragging < budget, "a resize costs {dragging:.2}ms, over the {budget:.0}ms a frame has");
    }

    /// A model, the terminal it is drawn on and the layout it keeps, drawn once
    /// so what is measured next is steady state.
    struct Stage {
        model: Model,
        terminal: Terminal<TestBackend>,
        rendered: layout::Rendered,
    }

    impl Stage {
        fn new(mut model: Model) -> Stage {
            let mut terminal = Terminal::new(TestBackend::new(120, 40)).unwrap();
            let mut rendered = layout::Rendered::default();
            terminal.draw(|frame| { ui::draw(frame, &mut model, &mut rendered); }).unwrap();
            Stage { model, terminal, rendered }
        }
    }

    /// The fastest of WINDOWS measurements of FIRST and of SECOND, taken in turn.
    ///
    /// In turn, so load that comes and goes lands on both sides. The fastest, so
    /// a stall that hits one window is not the number compared. A cost that
    /// recurs every few draws is in every window, so it still counts.
    fn fastest_in_turn(
        windows: usize,
        first: &mut Stage,
        second: &mut Stage,
        mut measure: impl FnMut(&mut Stage) -> f64,
    ) -> (f64, f64) {
        let (mut quickest_first, mut quickest_second) = (f64::INFINITY, f64::INFINITY);
        for _ in 0..windows {
            quickest_first = quickest_first.min(measure(first));
            quickest_second = quickest_second.min(measure(second));
        }
        (quickest_first, quickest_second)
    }

    #[test]
    fn a_long_reply_does_not_get_slower_line_by_line() {
        let reply = |line: usize| delta(&format!("reply line {line}, which says a sentence or so of something\n"));
        // The last reply of `big_model` already has twelve lines.
        let replying = |lines: usize| {
            let mut model = big_model(100);
            for line in 0..lines {
                model.absorb(&reply(line));
            }
            Stage::new(model)
        };
        let (mut near_start, mut far_in) = (replying(8), replying(388));
        let mut written = 0;
        let (early, late) = fastest_in_turn(5, &mut near_start, &mut far_in, |stage| {
            per_draw(&mut stage.model, &mut stage.terminal, &mut stage.rendered, 20, |_, model, _| {
                written += 1;
                model.absorb(&reply(written));
            })
        });
        println!("a reply line: {early:.2}ms from line 20, {late:.2}ms from line 400");
        assert!(late < early * 2.0, "line 400 of a reply costs {late:.2}ms against {early:.2}ms for line 20");
    }

    #[test]
    fn an_unbroken_line_streams_in_time_that_does_not_grow_with_it() {
        let token = "0123456789abcdef".repeat(4);
        let line_of = |tokens: usize| {
            let mut model = big_model(10);
            for _ in 0..tokens {
                model.absorb(&delta(&token));
            }
            Stage::new(model)
        };
        let (mut at_2kb, mut at_80kb) = (line_of(32), line_of(1250));
        let (short, long) = fastest_in_turn(5, &mut at_2kb, &mut at_80kb, |stage| {
            per_draw(&mut stage.model, &mut stage.terminal, &mut stage.rendered, 30, |_, model, _| {
                model.absorb(&delta(&token))
            })
        });
        println!("a token on an unbroken line: {short:.2}ms from 2KB, {long:.2}ms from 80KB");
        assert!(long < short * 2.0, "a token at 80KB costs {long:.2}ms against {short:.2}ms at 2KB");
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
        let mut rendered = layout::Rendered::default();
        terminal.draw(|frame| { ui::draw(frame, &mut model, &mut rendered); }).unwrap();

        let rounds = 20;
        let started = Instant::now();
        for _ in 0..rounds {
            terminal.draw(|frame| { ui::draw(frame, &mut model, &mut rendered); }).unwrap();
        }
        let each = started.elapsed() / rounds;
        println!("draw with {} entries: {:?} per frame",
                 model.current_conversation().unwrap().entries.len(), each);
        let budget = frame_budget_ms();
        assert!(
            each.as_secs_f64() * 1000.0 < budget,
            "a frame took {each:?}, over the {budget:.0}ms a frame has at 60fps"
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
            let mut rendered = layout::Rendered::default();
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
