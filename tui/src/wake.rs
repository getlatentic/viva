//! The one place the loop waits: until something happens, or until the
//! earliest thing it has to do at a time.
//!
//! Polling for keys on a timer left a line from the daemon waiting out the rest
//! of the poll before it was drawn, and woke an idle client thirty times a
//! second to find nothing. Whatever has work -- a key, a line from the daemon,
//! a daemon start that finished -- rings instead, and the loop sleeps between.

use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::time::Instant;

/// Rung by a thread that has handed the loop something to do. Ring after the
/// thing is handed over, never before, and no wake is ever lost.
#[derive(Clone)]
pub struct Bell(Sender<()>);

pub struct Waiter(Receiver<()>);

pub fn bell() -> (Bell, Waiter) {
    let (sender, receiver) = mpsc::channel();
    (Bell(sender), Waiter(receiver))
}

impl Bell {
    pub fn ring(&self) {
        let _ = self.0.send(());
    }
}

impl Waiter {
    /// Return once rung, or at DEADLINE when there is one, with every ring so
    /// far answered: the loop drains all its work on each wake, so ten rings
    /// that arrived together are one wake, not ten.
    pub fn wait(&self, deadline: Option<Instant>) {
        match deadline {
            Some(at) => match self.0.recv_timeout(at.saturating_duration_since(Instant::now())) {
                Ok(()) | Err(RecvTimeoutError::Timeout) | Err(RecvTimeoutError::Disconnected) => {}
            },
            None => {
                let _ = self.0.recv();
            }
        }
        while self.0.try_recv().is_ok() {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn a_ring_wakes_the_waiter_long_before_its_deadline() {
        let (bell, waiter) = bell();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(20));
            bell.ring();
        });
        let started = Instant::now();
        waiter.wait(Some(Instant::now() + Duration::from_secs(5)));
        assert!(started.elapsed() < Duration::from_secs(1), "slept {:?} with a ring waiting", started.elapsed());
    }

    #[test]
    fn with_nothing_rung_the_waiter_returns_at_its_deadline() {
        let (_bell, waiter) = bell();
        let started = Instant::now();
        waiter.wait(Some(Instant::now() + Duration::from_millis(30)));
        let slept = started.elapsed();
        assert!(slept >= Duration::from_millis(30), "returned early, after {slept:?}");
        assert!(slept < Duration::from_secs(1), "overslept its deadline: {slept:?}");
    }

    #[test]
    fn rings_that_arrived_together_are_one_wake() {
        let (bell, waiter) = bell();
        for _ in 0..3 {
            bell.ring();
        }
        waiter.wait(None);
        let started = Instant::now();
        waiter.wait(Some(Instant::now() + Duration::from_millis(30)));
        assert!(started.elapsed() >= Duration::from_millis(30), "a ring already answered woke it again");
    }
}
