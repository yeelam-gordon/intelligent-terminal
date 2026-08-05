//! Per-tab pending-prompt queue transitions.
//!
//! Prompts are owned by [`TabSession`] rather than the ACP transport. This
//! keeps input, cancellation, reset, and rendering scoped to the Terminal tab
//! that accepted the prompt, while `PromptSubmission::pane_context.tab_id`
//! makes the helper/master transport route the eventual dispatch correctly.

use super::tab_state::{QueuedPrompt, PENDING_PROMPT_QUEUE_CAP};
use super::*;

const QUEUE_HINT_DURATION: std::time::Duration = std::time::Duration::from_millis(2500);

impl App {
    /// Move the active tab's draft into its pending queue. Returns false when
    /// the queue is full, leaving the complete draft (including attachments)
    /// available for the user to edit or submit later.
    pub(super) fn enqueue_current_prompt(&mut self) -> bool {
        if self.current_tab().pending_prompts.len() >= PENDING_PROMPT_QUEUE_CAP {
            let now = std::time::Instant::now();
            self.transient_hint = Some((
                t!("input.queue.full", cap = PENDING_PROMPT_QUEUE_CAP).into_owned(),
                now + QUEUE_HINT_DURATION,
            ));
            return false;
        }

        let (text, display_text, images) = {
            let tab = self.current_tab_mut();
            let display_text = std::mem::take(&mut tab.input);
            let (text, images) = tab.attachments.take_for_submission(display_text.clone());
            tab.record_input_history(&text);
            tab.cursor_pos = 0;
            tab.refresh_command_popup();
            (text, display_text, images)
        };
        self.current_tab_mut()
            .pending_prompts
            .push_back(QueuedPrompt::new(text, display_text, images));

        if self.show_welcome_hint {
            self.show_welcome_hint = false;
            set_welcome_shown_in_state();
        }
        true
    }

    /// Remove the newest queued prompt from the active tab. Queue dispatch is
    /// FIFO, while Esc behaves as an undo stack for the user's most recent
    /// enqueue action.
    pub(super) fn undo_latest_queued_prompt(&mut self) -> bool {
        let Some(queued) = self.current_tab_mut().pending_prompts.pop_back() else {
            return false;
        };
        let now = std::time::Instant::now();
        self.transient_hint = Some((
            t!("input.queue.removed", preview = queued.collapsed_text()).into_owned(),
            now + QUEUE_HINT_DURATION,
        ));
        true
    }

    /// Drop pending user work for the active tab and return how many prompts
    /// were discarded. Ctrl+C and `/stop` use this intentionally stronger
    /// semantic than Esc, which only undoes one queued prompt at a time.
    pub(super) fn discard_current_pending_prompts(&mut self) -> usize {
        let queued = &mut self.current_tab_mut().pending_prompts;
        let count = queued.len();
        queued.clear();
        count
    }

    /// Dispatch at most one queued prompt per ready tab.
    ///
    /// Each helper owns its own prompt queue, but its ACP client can lazily
    /// create a session for a tab identified in `PaneContext`. Therefore this
    /// uses `turn_submit_prompt_for_tab` instead of resolving an absent
    /// session id through the active-tab fallback, which would misroute a
    /// background tab's queued work.
    pub(super) fn drain_pending_prompts(&mut self) {
        if self.state != ConnectionState::Connected
            || !self
                .tab_sessions
                .values()
                .any(|tab| !tab.pending_prompts.is_empty())
        {
            return;
        }

        let mut tab_ids: Vec<String> = self.tab_sessions.keys().cloned().collect();
        tab_ids.sort();

        for tab_id in tab_ids {
            let can_dispatch = self.tab_sessions.get(&tab_id).is_some_and(|tab| {
                !tab.pending_prompts.is_empty()
                    && tab.turn.accepts_new_prompt()
                    && tab.turn.recommendations().is_none()
                    && tab.permission.is_empty()
                    && !tab.loading_session
            });
            if !can_dispatch {
                continue;
            }

            let queued = self
                .tab_sessions
                .get_mut(&tab_id)
                .expect("queued tab remains present")
                .pending_prompts
                .pop_front()
                .expect("dispatch gate requires a queued prompt");
            let (text, display_text, images) = queued.into_parts();
            let pane_context = PaneContext {
                pane_id: self.pane_id.clone(),
                tab_id: Some(tab_id.clone()),
                window_id: self.window_id.clone(),
                cwd: self.source_cwd.clone(),
                source_pane_id: self.source_session_id.clone(),
            };
            let prompt = PromptSubmission::new(text, Some(pane_context)).with_images(images);
            prompt_timing_log(
                prompt.id,
                prompt.submitted_at_unix_s,
                "queue_dispatch",
                &format!("preview={:?}", prompt.preview()),
            );
            let submitted = SubmittedPrompt {
                id: prompt.id,
                text: display_text,
                submitted_at_unix_s: prompt.submitted_at_unix_s,
                context: TurnContext::default(),
                autofix: None,
            };
            self.turn_submit_prompt_for_tab(&tab_id, submitted);
            let _ = self.prompt_tx.send(prompt);
        }
    }

    /// Cancel the active tab's in-flight head. The ACP cancellation is
    /// best-effort when lazy session creation has not produced an id yet, but
    /// the local turn state always returns to Idle.
    pub(super) fn cancel_active_in_flight_turn(&mut self) -> bool {
        if !self.current_tab().turn.is_in_flight() {
            return false;
        }

        let session_id = self.current_tab().session_id.clone();
        if let Some(session_id) = session_id.as_ref() {
            let _ = self.cancel_tx.send(CancelRequest {
                session_id: session_id.clone(),
            });
        }
        self.turn_cancel(session_id.as_deref().unwrap_or(DEFAULT_TAB_ID));
        let tab = self.current_tab_mut();
        tab.messages
            .push(ChatMessage::System(t!("system.cancelled").into_owned()));
        tab.scroll_to_bottom();
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::tests::test_app_with_prompt_rx;
    use crate::clipboard_image::PastedImage;
    use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

    fn connected_app() -> (
        App,
        tokio::sync::mpsc::UnboundedReceiver<crate::protocol::acp::client::PromptSubmission>,
    ) {
        let (mut app, prompt_rx) = test_app_with_prompt_rx();
        app.state = ConnectionState::Connected;
        (app, prompt_rx)
    }

    fn enter(app: &mut App, text: &str) {
        app.current_tab_mut().insert_input_str(text);
        app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE));
    }

    fn submitted(id: u64, text: &str) -> SubmittedPrompt {
        SubmittedPrompt {
            id,
            text: text.to_string(),
            submitted_at_unix_s: 0.0,
            context: TurnContext::default(),
            autofix: None,
        }
    }

    #[test]
    fn busy_enter_queues_and_completion_drains_fifo() {
        let (mut app, mut prompt_rx) = connected_app();
        enter(&mut app, "first");
        assert_eq!(prompt_rx.try_recv().unwrap().text, "first");

        enter(&mut app, "second");
        enter(&mut app, "third");
        let tab = app.current_tab();
        assert_eq!(tab.pending_prompts.len(), 2);
        assert_eq!(
            tab.messages
                .iter()
                .filter(|message| matches!(message, ChatMessage::User(_)))
                .count(),
            1,
            "queued work must not render a premature user bubble"
        );

        app.handle_event(AppEvent::AgentMessageEnd {
            session_id: DEFAULT_TAB_ID.to_string(),
        });
        let second = prompt_rx
            .try_recv()
            .expect("first queued prompt dispatched");
        assert_eq!(second.text, "second");
        assert_eq!(
            second
                .pane_context
                .as_ref()
                .and_then(|context| context.tab_id.as_deref()),
            Some(DEFAULT_TAB_ID)
        );
        assert_eq!(app.current_tab().pending_prompts.len(), 1);

        app.handle_event(AppEvent::AgentMessageEnd {
            session_id: DEFAULT_TAB_ID.to_string(),
        });
        assert_eq!(
            prompt_rx
                .try_recv()
                .expect("second queued prompt dispatched")
                .text,
            "third"
        );
    }

    #[test]
    fn session_load_permission_and_card_hold_queue_until_ready() {
        let (mut app, mut prompt_rx) = connected_app();
        app.current_tab_mut().loading_session = true;
        enter(&mut app, "after load");
        assert_eq!(app.current_tab().pending_prompts.len(), 1);
        app.drain_pending_prompts();
        assert!(prompt_rx.try_recv().is_err());

        {
            let tab = app.current_tab_mut();
            tab.loading_session = false;
            tab.permission.push_back(PermissionState {
                tool_call_id: "tool-1".into(),
                description: "permission".into(),
                title: "permission".into(),
                kind_label: None,
                target: None,
                target_is_command: false,
                options: vec![],
                selected: 0,
                responder: None,
            });
        }
        app.drain_pending_prompts();
        assert!(prompt_rx.try_recv().is_err());

        {
            let tab = app.current_tab_mut();
            tab.permission.clear();
            tab.turn = TurnState::Surfaced {
                prompt: submitted(1, "card"),
                outcome: TurnOutcome::Recommendation(crate::coordinator::RecommendationSet {
                    recommended_choice: None,
                    choices: vec![],
                }),
                end_pending: false,
            };
        }
        app.drain_pending_prompts();
        assert!(prompt_rx.try_recv().is_err());
        assert_eq!(app.current_tab().pending_prompts.len(), 1);

        app.current_tab_mut().turn = TurnState::Idle;
        app.drain_pending_prompts();
        assert_eq!(
            prompt_rx
                .try_recv()
                .expect("queue drains after all gates release")
                .text,
            "after load"
        );
    }

    #[test]
    fn esc_undoes_queue_lifo_before_cancelling_head() {
        let (mut app, _prompt_rx) = connected_app();
        enter(&mut app, "head");
        enter(&mut app, "first queued");
        enter(&mut app, "second queued");

        app.handle_key(KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE));
        assert_eq!(app.current_tab().pending_prompts.len(), 1);
        assert_eq!(
            app.current_tab()
                .pending_prompts
                .back()
                .unwrap()
                .collapsed_text(),
            "first queued"
        );
        assert!(app.current_tab().turn.is_in_flight());

        app.handle_key(KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE));
        assert!(app.current_tab().pending_prompts.is_empty());
        assert!(app.current_tab().turn.is_in_flight());

        app.handle_key(KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE));
        assert!(app.current_tab().turn.is_idle());
    }

    #[test]
    fn esc_undoes_user_queue_before_cancelling_autofix() {
        let (mut app, _prompt_rx) = connected_app();
        {
            let tab = app.current_tab_mut();
            tab.autofix.pane_id = Some("failing-pane".into());
            tab.turn = TurnState::Submitted(SubmittedPrompt {
                id: 1,
                text: "autofix".into(),
                submitted_at_unix_s: 0.0,
                context: TurnContext::with_target_pane("failing-pane"),
                autofix: Some(AutofixContext { generation: 0 }),
            });
            tab.pending_prompts.push_back(QueuedPrompt::new(
                "user follow-up".into(),
                "user follow-up".into(),
                vec![],
            ));
        }

        app.handle_key(KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE));

        assert!(app.current_tab().pending_prompts.is_empty());
        assert!(
            app.current_tab().turn.is_in_flight(),
            "Esc must preserve the in-flight autofix until queued user work is gone"
        );
    }

    #[test]
    fn stop_and_ctrl_c_clear_all_queued_work() {
        let (mut app, _prompt_rx) = connected_app();
        enter(&mut app, "head");
        enter(&mut app, "queued");
        app.handle_key(KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL));
        assert!(app.current_tab().pending_prompts.is_empty());
        assert!(app.current_tab().turn.is_idle());

        enter(&mut app, "new head");
        enter(&mut app, "new queued");
        app.current_tab_mut().replace_input("/stop".into());
        app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE));
        assert!(app.current_tab().pending_prompts.is_empty());
        assert!(app.current_tab().turn.is_idle());
    }

    #[test]
    fn queue_cap_preserves_the_draft() {
        let (mut app, _prompt_rx) = connected_app();
        enter(&mut app, "head");
        for index in 0..PENDING_PROMPT_QUEUE_CAP {
            enter(&mut app, &format!("queued {index}"));
        }
        assert_eq!(
            app.current_tab().pending_prompts.len(),
            PENDING_PROMPT_QUEUE_CAP
        );

        app.current_tab_mut().insert_input_str("overflow");
        app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE));
        assert_eq!(
            app.current_tab().pending_prompts.len(),
            PENDING_PROMPT_QUEUE_CAP
        );
        assert_eq!(app.current_tab().input, "overflow");
        assert!(app.transient_hint.is_some());
    }

    #[test]
    fn background_queue_dispatches_with_its_tab_context() {
        let (mut app, mut prompt_rx) = connected_app();
        app.tab_id = Some("tab-a".into());
        app.tab_mut("tab-a");
        app.tab_mut("tab-b")
            .pending_prompts
            .push_back(QueuedPrompt::new(
                "background".into(),
                "background".into(),
                vec![],
            ));

        app.drain_pending_prompts();

        assert!(app.tab_sessions["tab-a"].turn.is_idle());
        assert!(matches!(
            app.tab_sessions["tab-b"].turn,
            TurnState::Submitted(_)
        ));
        let prompt = prompt_rx
            .try_recv()
            .expect("background queue dispatches through the helper");
        assert_eq!(prompt.text, "background");
        assert_eq!(
            prompt
                .pane_context
                .as_ref()
                .and_then(|context| context.tab_id.as_deref()),
            Some("tab-b")
        );
    }

    #[test]
    fn queued_images_survive_until_dispatch() {
        let (mut app, mut prompt_rx) = connected_app();
        let image = PastedImage {
            data_base64: "aGVsbG8=".into(),
            mime_type: "image/png".into(),
            label: "image.png".into(),
        };
        app.current_tab_mut()
            .pending_prompts
            .push_back(QueuedPrompt::new(
                "describe this".into(),
                "[image: image.png] describe this".into(),
                vec![image.clone()],
            ));

        app.drain_pending_prompts();
        assert_eq!(
            prompt_rx
                .try_recv()
                .expect("queued prompt dispatched")
                .images,
            vec![image]
        );
    }

    #[test]
    fn clearing_history_drops_queued_prompts() {
        let (mut app, _prompt_rx) = connected_app();
        app.current_tab_mut()
            .pending_prompts
            .push_back(QueuedPrompt::new("stale".into(), "stale".into(), vec![]));
        app.current_tab_mut().clear_chat_history();
        assert!(app.current_tab().pending_prompts.is_empty());
    }

    #[test]
    fn tab_reset_and_rename_do_not_leak_queued_prompts() {
        let (mut app, _prompt_rx) = connected_app();
        app.tab_id = Some("old-tab".into());
        app.tab_mut("old-tab")
            .pending_prompts
            .push_back(QueuedPrompt::new(
                "queued before drag".into(),
                "queued before drag".into(),
                vec![],
            ));

        app.rename_tab_session("old-tab", "new-tab", Some("window-2"));
        assert_eq!(app.tab_sessions["new-tab"].pending_prompts.len(), 1);
        assert!(!app.tab_sessions.contains_key("old-tab"));

        app.reset_tab_session_for("new-tab");
        assert!(app.tab_sessions["new-tab"].pending_prompts.is_empty());
    }

    #[test]
    fn preview_collapses_whitespace_and_is_bounded() {
        let prompt =
            QueuedPrompt::new("unused".into(), "  first\n second\t third  ".into(), vec![]);
        assert_eq!(prompt.collapsed_text(), "first second third");

        let long = QueuedPrompt::new("unused".into(), "x ".repeat(300), vec![]);
        assert_eq!(long.collapsed_text().chars().count(), 256);
    }
}
