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

        let resume = {
            let tab = self.current_tab();
            tab.queue_paused
                && tab.turn.accepts_new_prompt()
                && tab.turn.recommendations().is_none()
                && tab.permission.is_empty()
                && !tab.loading_session
        };
        if resume {
            self.current_tab_mut().queue_paused = false;
            let tab_id = self.active_tab_key().to_string();
            self.dispatch_next_queued_prompt(&tab_id);
        }

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

    /// Dispatch exactly one queued prompt for this helper's owner tab.
    ///
    /// Helpers are per-tab in the current architecture. Never scan every
    /// `TabSession`: doing so revives the retired multi-tab helper routing and
    /// lets unrelated state transitions start work in another helper's tab.
    fn dispatch_next_queued_prompt(&mut self, tab_id: &str) -> bool {
        if self.state != ConnectionState::Connected {
            return false;
        }
        if let Some(owner) = self.owner_tab_id.as_deref() {
            if owner != tab_id {
                return false;
            }
        } else if self.active_tab_key() != tab_id {
            return false;
        }

        let queued = {
            let Some(tab) = self.tab_sessions.get_mut(tab_id) else {
                return false;
            };
            if tab.queue_paused
                || tab.pending_prompts.is_empty()
                || !tab.turn.accepts_new_prompt()
                || tab.turn.recommendations().is_some()
                || !tab.permission.is_empty()
                || tab.loading_session
            {
                return false;
            }
            tab.pending_prompts
                .pop_front()
                .expect("non-empty queue was checked")
        };
        let (text, display_text, images) = queued.into_parts();
        let prompt = {
            let pane_context = PaneContext {
                pane_id: self.pane_id.clone(),
                tab_id: Some(tab_id.to_string()),
                window_id: self.window_id.clone(),
                cwd: self.source_cwd.clone(),
                source_pane_id: self.source_session_id.clone(),
            };
            PromptSubmission::new(text, Some(pane_context)).with_images(images)
        };
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
        let queued = QueuedPrompt::new(
            prompt.text.clone(),
            submitted.text.clone(),
            prompt.images.clone(),
        );
        self.tab_mut(tab_id).queued_dispatch = Some(super::tab_state::QueuedDispatch {
            prompt_id: prompt.id,
            prompt: queued,
        });
        self.turn_submit_prompt_for_tab(tab_id, submitted);
        let _ = self.prompt_tx.send(prompt);
        true
    }

    /// A completed, successful agent turn is the only automatic queue-drain
    /// point. It runs after terminal metadata has been applied and only for
    /// the helper's owning tab.
    pub(super) fn dispatch_after_successful_turn(&mut self, session_id: &str) {
        let tab_id = self.tab_for_session(session_id);
        let completed_id = self
            .tab_sessions
            .get(&tab_id)
            .and_then(|tab| tab.turn.prompt().map(|prompt| prompt.id));
        if self
            .tab_sessions
            .get(&tab_id)
            .and_then(|tab| tab.queued_dispatch.as_ref())
            .is_some_and(|dispatch| Some(dispatch.prompt_id) == completed_id)
        {
            self.tab_mut(&tab_id).queued_dispatch = None;
        }
        self.promote_deferred_autofix(&tab_id);
        self.dispatch_next_queued_prompt(&tab_id);
    }

    /// A recommendation action is an explicit successful resolution of the
    /// card that blocked FIFO progression. Only after `turn_execute_card`
    /// has transitioned the card to its terminal outcome may Q2 begin.
    pub(super) fn dispatch_after_recommendation_execution(&mut self, session_id: &str) {
        let tab_id = self.tab_for_session(session_id);
        self.dispatch_next_queued_prompt(&tab_id);
    }

    /// Keep queued work intact after a recoverable dispatch failure. The next
    /// typed Enter is an explicit user decision to retry in FIFO order.
    pub(super) fn pause_queued_dispatch(&mut self, tab_id: &str, prompt_id: Option<u64>) -> bool {
        let tab = self.tab_mut(tab_id);
        let matches = tab
            .queued_dispatch
            .as_ref()
            .is_some_and(|dispatch| prompt_id.is_none() || Some(dispatch.prompt_id) == prompt_id);
        if matches {
            let dispatch = tab.queued_dispatch.take().expect("matched dispatch");
            tab.pending_prompts.push_front(dispatch.prompt);
        }
        if !tab.pending_prompts.is_empty() {
            tab.queue_paused = true;
        }
        matches
    }

    /// Roll back an ACP-side busy rejection. The rejected queued prompt was
    /// never accepted by the agent, so restore it at the front and clear the
    /// optimistic local Submitted state without draining again.
    pub(super) fn rollback_queued_dispatch(&mut self, tab_id: &str, prompt_id: u64) -> bool {
        if !self.pause_queued_dispatch(tab_id, Some(prompt_id)) {
            return false;
        }
        let tab = self.tab_mut(tab_id);
        if tab
            .turn
            .prompt()
            .is_some_and(|prompt| prompt.id == prompt_id)
        {
            tab.turn = TurnState::Idle;
            tab.messages.clear();
            tab.tool_calls.clear();
            tab.permission.clear();
            tab.activity_frame = 0;
            tab.timing_note = None;
        }
        true
    }

    /// Cancel the active tab's in-flight head. The ACP cancellation is
    /// best-effort when lazy session creation has not produced an id yet, but
    /// the local turn state always returns to Idle.
    pub(super) fn cancel_active_in_flight_turn(&mut self) -> bool {
        if !self.current_tab().turn.is_in_flight() {
            return false;
        }

        let prompt_id = self.current_tab().turn.prompt().map(|prompt| prompt.id);
        if let Some(prompt_id) = prompt_id {
            let tab = self.current_tab_mut();
            if tab
                .queued_dispatch
                .as_ref()
                .is_some_and(|dispatch| dispatch.prompt_id == prompt_id)
            {
                tab.queued_dispatch = None;
            }
        }
        let session_id = self.current_tab().session_id.clone();
        if let Some(session_id) = session_id.as_ref() {
            let _ = self.cancel_tx.send(CancelRequest {
                session_id: Some(session_id.clone()),
                prompt_id: prompt_id.expect("in-flight turn has a prompt id"),
            });
        } else if let Some(prompt_id) = prompt_id {
            let _ = self.cancel_tx.send(CancelRequest {
                session_id: None,
                prompt_id,
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

        app.handle_event(AppEvent::AgentTurnCompleted {
            session_id: DEFAULT_TAB_ID.to_string(),
            prompt_id: app.current_tab().turn.prompt().unwrap().id,
            soft_stop: None,
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

        app.handle_event(AppEvent::AgentTurnCompleted {
            session_id: DEFAULT_TAB_ID.to_string(),
            prompt_id: app.current_tab().turn.prompt().unwrap().id,
            soft_stop: None,
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
        assert!(prompt_rx.try_recv().is_err());
        assert_eq!(app.current_tab().pending_prompts.len(), 1);

        app.current_tab_mut().turn = TurnState::Idle;
        app.current_tab_mut().queue_paused = true;
        enter(&mut app, "explicit resume");
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
    fn owner_helper_never_dispatches_another_tabs_queue() {
        let (mut app, mut prompt_rx) = connected_app();
        app.owner_tab_id = Some("tab-a".into());
        app.tab_id = Some("tab-a".into());
        app.tab_mut("tab-a");
        app.tab_mut("tab-b")
            .pending_prompts
            .push_back(QueuedPrompt::new(
                "background".into(),
                "background".into(),
                vec![],
            ));

        assert!(!app.dispatch_next_queued_prompt("tab-b"));

        assert!(app.tab_sessions["tab-a"].turn.is_idle());
        assert!(app.tab_sessions["tab-b"].turn.is_idle());
        assert!(prompt_rx.try_recv().is_err());
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

        assert!(app.dispatch_next_queued_prompt(DEFAULT_TAB_ID));
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

    #[test]
    fn recoverable_error_pauses_queue_without_dispatching_on_later_events() {
        let (mut app, mut prompt_rx) = connected_app();
        app.current_tab_mut()
            .pending_prompts
            .push_back(QueuedPrompt::new(
                "retry me".into(),
                "retry me".into(),
                vec![],
            ));
        assert!(app.dispatch_next_queued_prompt(DEFAULT_TAB_ID));
        assert_eq!(prompt_rx.try_recv().unwrap().text, "retry me");

        app.handle_event(AppEvent::AgentError {
            session_id: None,
            failure: crate::protocol::acp::failure::AgentFailure::Protocol {
                code: -32603,
                message: "temporary failure".into(),
            },
            message: "temporary failure".into(),
        });
        app.handle_event(AppEvent::Tick);

        assert!(app.current_tab().queue_paused);
        assert_eq!(app.current_tab().pending_prompts.len(), 1);
        assert!(prompt_rx.try_recv().is_err());
    }

    #[test]
    fn load_success_and_failure_pause_until_explicit_fifo_resume() {
        for load_succeeds in [true, false] {
            let (mut app, mut prompt_rx) = connected_app();
            {
                let tab = app.current_tab_mut();
                tab.loading_session = true;
                tab.loading_target_session_id = Some("loaded-session".into());
                tab.pending_prompts.push_back(QueuedPrompt::new(
                    "queued during load".into(),
                    "queued during load".into(),
                    vec![],
                ));
            }
            if load_succeeds {
                app.handle_event(AppEvent::SessionAttached {
                    tab_id: DEFAULT_TAB_ID.to_string(),
                    session_id: "loaded-session".into(),
                    available_models: vec![],
                    current_model_id: None,
                });
            } else {
                app.handle_event(AppEvent::TabError {
                    tab_id: DEFAULT_TAB_ID.to_string(),
                    message: "load failed".into(),
                });
            }
            assert!(app.current_tab().queue_paused);
            assert!(prompt_rx.try_recv().is_err());

            enter(&mut app, "explicit resume");
            assert_eq!(
                prompt_rx.try_recv().unwrap().text,
                "queued during load",
                "case load_succeeds={load_succeeds}"
            );
        }
    }

    #[test]
    fn queued_input_never_bypasses_fifo_head() {
        let (mut app, mut prompt_rx) = connected_app();
        app.current_tab_mut()
            .pending_prompts
            .push_back(QueuedPrompt::new("Q1".into(), "Q1".into(), vec![]));

        enter(&mut app, "Q2");

        assert_eq!(app.current_tab().pending_prompts.len(), 2);
        assert!(prompt_rx.try_recv().is_err());
        assert!(app.dispatch_next_queued_prompt(DEFAULT_TAB_ID));
        assert_eq!(prompt_rx.try_recv().unwrap().text, "Q1");
    }

    #[test]
    fn direct_agent_busy_rolls_back_text_and_attachments_for_fifo_retry() {
        let (mut app, mut prompt_rx) = connected_app();
        let image = PastedImage {
            data_base64: "aGVsbG8=".into(),
            mime_type: "image/png".into(),
            label: "image.png".into(),
        };
        app.current_tab_mut().insert_image_attachment(image.clone());
        enter(&mut app, "describe");
        let first = prompt_rx.try_recv().expect("direct prompt dispatched");
        let prompt_id = app.current_tab().turn.prompt().unwrap().id;
        assert_eq!(first.images, vec![image.clone()]);

        app.handle_event(AppEvent::AgentBusy {
            tab_id: DEFAULT_TAB_ID.to_string(),
            prompt_id,
        });
        assert!(app.current_tab().queue_paused);
        assert_eq!(app.current_tab().pending_prompts.len(), 1);

        enter(&mut app, "explicit resume");
        let retried = prompt_rx.try_recv().expect("rolled-back prompt retried first");
        assert_eq!(retried.text, "describe");
        assert_eq!(retried.images, vec![image]);
    }

    #[test]
    fn recommendation_execution_acknowledgement_gates_queue_drain() {
        let (mut app, mut prompt_rx) = connected_app();
        app.current_tab_mut()
            .pending_prompts
            .push_back(QueuedPrompt::new("Q2".into(), "Q2".into(), vec![]));
        app.current_tab_mut().turn = TurnState::Surfaced {
            prompt: submitted(1, "Q1"),
            outcome: TurnOutcome::ExecutingRecommendation,
            end_pending: false,
        };

        app.handle_event(AppEvent::Tick);
        assert!(prompt_rx.try_recv().is_err(), "pending coordinator work blocks FIFO");
        app.handle_event(AppEvent::RecommendationExecutionCompleted {
            tab_id: DEFAULT_TAB_ID.to_string(),
            prompt_id: 1,
            result: Ok(()),
        });

        assert_eq!(prompt_rx.try_recv().unwrap().text, "Q2");
    }

    #[test]
    fn failed_recommendation_execution_pauses_queue() {
        let (mut app, mut prompt_rx) = connected_app();
        app.current_tab_mut()
            .pending_prompts
            .push_back(QueuedPrompt::new("Q2".into(), "Q2".into(), vec![]));
        app.current_tab_mut().turn = TurnState::Surfaced {
            prompt: submitted(1, "Q1"),
            outcome: TurnOutcome::ExecutingRecommendation,
            end_pending: false,
        };

        app.handle_event(AppEvent::RecommendationExecutionCompleted {
            tab_id: DEFAULT_TAB_ID.to_string(),
            prompt_id: 1,
            result: Err("executor failed".into()),
        });
        app.handle_event(AppEvent::Tick);

        assert!(app.current_tab().queue_paused);
        assert_eq!(app.current_tab().pending_prompts.len(), 1);
        assert!(prompt_rx.try_recv().is_err());
    }

    #[test]
    fn soft_stop_metadata_is_committed_before_the_next_queue_item() {
        let (mut app, mut prompt_rx) = connected_app();
        enter(&mut app, "Q1");
        let _ = prompt_rx.try_recv();
        enter(&mut app, "Q2");

        app.handle_event(AppEvent::AgentTurnCompleted {
            session_id: DEFAULT_TAB_ID.to_string(),
            prompt_id: app.current_tab().turn.prompt().unwrap().id,
            soft_stop: Some(crate::protocol::acp::soft_stop::SoftStopReason::MaxTokens),
        });

        assert_eq!(prompt_rx.try_recv().unwrap().text, "Q2");
        assert!(matches!(
            app.current_tab()
                .completed_turns
                .last()
                .and_then(|turn| turn.details.last()),
            Some(ChatMessage::System(_))
        ));
    }

    #[test]
    fn busy_autofix_is_promoted_to_a_visible_detected_state() {
        let (mut app, _prompt_rx) = connected_app();
        app.autofix_enabled = true;
        app.current_tab_mut().turn = TurnState::Submitted(submitted(1, "busy"));
        let notification = WtNotification {
            severity: WtEventSeverity::Actionable,
            pane_id: "failing-pane".into(),
            tab_id: Some(DEFAULT_TAB_ID.into()),
            summary: "command failed".into(),
            acknowledged: false,
            age_ticks: 0,
        };

        app.trigger_autofix_inner(&notification, false);
        assert!(app.current_tab().autofix.deferred.is_some());

        app.current_tab_mut().turn = TurnState::Idle;
        app.dispatch_after_successful_turn(DEFAULT_TAB_ID);
        assert!(matches!(
            app.current_tab().autofix.bar_snapshot,
            AutofixBarSnapshot::Detected { .. }
        ));
    }

    #[test]
    fn deferred_autofix_is_cleared_by_cancel_and_session_reset() {
        let (mut app, _prompt_rx) = connected_app();
        app.current_tab_mut().autofix.deferred = Some(super::super::autofix::DeferredAutofix {
            pane_id: "pane".into(),
            summary: "failure".into(),
        });
        app.current_tab_mut().turn = TurnState::Submitted(submitted(1, "active"));
        app.turn_cancel(DEFAULT_TAB_ID);
        assert!(app.current_tab().autofix.deferred.is_none());

        app.current_tab_mut().autofix.deferred = Some(super::super::autofix::DeferredAutofix {
            pane_id: "pane".into(),
            summary: "failure".into(),
        });
        app.current_tab_mut().clear_chat_history();
        assert!(app.current_tab().autofix.deferred.is_none());
    }
}
