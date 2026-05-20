use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use rio_backend::event::{EventListener, RioEvent, WindowId};

#[derive(Clone)]
pub struct WinEventListener {
    dirty: Arc<AtomicBool>,
    route_id: usize,
}

impl WinEventListener {
    pub fn new(dirty: Arc<AtomicBool>, route_id: usize) -> Self {
        Self { dirty, route_id }
    }

    pub fn mark_dirty(&self) {
        self.dirty.store(true, Ordering::Release);
    }
}

impl EventListener for WinEventListener {
    fn event(&self) -> (Option<RioEvent>, bool) {
        (None, false)
    }

    fn send_event(&self, _event: RioEvent, _id: WindowId) {
        self.dirty.store(true, Ordering::Release);
    }
}
