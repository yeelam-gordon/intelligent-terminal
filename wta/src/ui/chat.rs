use std::borrow::Cow;

use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, Paragraph, Wrap};

use crate::app::{App, ChatMessage, CompletedTurn, PlanEntryStatus};
use crate::theme;
use crate::ui::shimmer;
use crate::ui_trace;

const ACTIVITY_LABEL: &str = "Thinking…";

const ACTIVITY_PREVIEW_MAX_CHARS: usize = 180;
const MAX_RENDER_LINE_CHARS: usize = 4096;

/// Estimate the chat block's natural height (in visual rows) given the
/// rendering width. Counts wraps for each message + completed turn plus the
/// pinned activity row when active. Used by `layout::render` to size the
/// chat area so the rec panel sits directly below content instead of being
/// pushed to the pane bottom by a `Min(1)` spacer.
pub fn estimated_block_height(app: &App, area_width: u16) -> u16 {
    let tab = app.current_tab();
    let wrap_width = (area_width as usize).max(1);

    let activity = if tab.prompt_in_flight
        || tab.agent_streaming
        || tab.progress_status.is_some()
    {
        1usize
    } else {
        0
    };

    let messages: usize = tab.messages.iter().map(|m| message_height(m, wrap_width)).sum();
    let turns: usize = tab.completed_turns.iter().map(|t| turn_height(t, wrap_width)).sum();

    (activity + messages + turns).max(1).min(u16::MAX as usize) as u16
}

fn wrap_count(text: &str, width: usize) -> usize {
    let w = width.max(1);
    text.split('\n')
        .map(|line| {
            let chars = line.chars().count();
            if chars == 0 { 1 } else { chars.div_ceil(w) }
        })
        .sum::<usize>()
        .max(1)
}

fn message_height(msg: &ChatMessage, wrap_width: usize) -> usize {
    // Most variants render with a 2-cell prefix ("● " for agent/error,
    // "> " for user) and a trailing blank line.
    let body_width = wrap_width.saturating_sub(2).max(1);
    match msg {
        ChatMessage::User(t) | ChatMessage::Agent(t) | ChatMessage::Error(t) => {
            wrap_count(t, body_width) + 1
        }
        ChatMessage::System(t) | ChatMessage::AgentEvent(t) => wrap_count(t, wrap_width) + 1,
        ChatMessage::ToolCall { .. } => 1,
        ChatMessage::Plan(entries) => 2 + entries.len(), // header + each entry + blank
    }
}

fn turn_height(turn: &CompletedTurn, wrap_width: usize) -> usize {
    // Collapsed view = single Line "▶ > <prompt>" + trailing blank.
    let chars = "▶ > ".chars().count() + turn.prompt.chars().count();
    let prompt_rows = chars.div_ceil(wrap_width.max(1)).max(1);
    let mut h = prompt_rows + 1;
    if turn.expanded {
        h += turn
            .details
            .iter()
            .map(|m| message_height(m, wrap_width))
            .sum::<usize>();
    }
    h
}

pub fn render(frame: &mut Frame, app: &mut App, area: Rect) {
    let render_started = std::time::Instant::now();

    // Pin the activity indicator to a dedicated bottom row when active so a
    // long user prompt that wraps past the chat height can never push it
    // off-screen. The remaining rows scroll normally.
    let activity_line = build_activity_line(app);
    let (chat_area, activity_area) = match (&activity_line, area.height) {
        (Some(_), h) if h > 0 => (
            Rect { height: h - 1, ..area },
            Some(Rect { x: area.x, y: area.y + h - 1, width: area.width, height: 1 }),
        ),
        _ => (area, None),
    };

    let inner = Block::default().borders(Borders::NONE);
    let inner_area = inner.inner(chat_area);
    let visible_height = inner_area.height as usize;
    let wrap_width = inner_area.width as usize;
    let requested_lines = visible_height
        .saturating_add(app.current_tab().chat_scroll.offset)
        .saturating_add(32);

    let mut reversed_lines: Vec<Line> = Vec::new();

    let mut pending_lines = build_pending_stream_lines(app);
    reversed_lines.extend(pending_lines.drain(..).rev());

    let mut truncated = false;

    for (idx, msg) in app.current_tab().messages.iter().enumerate().rev() {
        let is_last_message = idx + 1 == app.current_tab().messages.len();
        let mut message_lines = build_message_lines(msg, is_last_message, app.current_tab().agent_streaming, wrap_width);
        reversed_lines.extend(message_lines.drain(..).rev());
        if reversed_lines.len() >= requested_lines {
            truncated = true;
            break;
        }
    }

    if !truncated {
        let selected_idx = app.current_tab().selected_completed_turn_idx;
        for (idx, turn) in app.current_tab().completed_turns.iter().enumerate().rev() {
            let is_selected = selected_idx == Some(idx);
            let mut turn_lines = build_completed_turn_lines(turn, is_selected, wrap_width);
            reversed_lines.extend(turn_lines.drain(..).rev());
            if reversed_lines.len() >= requested_lines {
                truncated = true;
                break;
            }
        }
    }

    let lines: Vec<Line> = reversed_lines.into_iter().rev().collect();

    let total_lines = lines.len();
    let scroll = total_lines.saturating_sub(visible_height.saturating_add(app.current_tab().chat_scroll.offset));

    let paragraph = Paragraph::new(lines)
        .block(inner)
        .wrap(Wrap { trim: false })
        .scroll((scroll as u16, 0));

    frame.render_widget(paragraph, chat_area);

    if let (Some(line), Some(act_area)) = (activity_line, activity_area) {
        frame.render_widget(Paragraph::new(line), act_area);
    }

    // Update the scroll bound only when the build saw all of history;
    // otherwise the true max is still unknown and the stored value (possibly
    // stale) is the best we have. Either way `Scroll::by` itself doesn't
    // clamp, so wheel-up keeps working even with a stale bound.
    if !truncated {
        app.current_tab_mut()
            .chat_scroll
            .set_max(total_lines.saturating_sub(visible_height));
    }

    ui_trace::log_slow("chat_render", render_started.elapsed(), || {
        format!(
            "messages={} pending_chars={} requested_lines={} visible_height={} area={}x{}",
            app.current_tab().messages.len(),
            app.current_tab().pending_agent_response.chars().count(),
            requested_lines,
            visible_height,
            area.width,
            area.height
        )
    });
}

fn build_completed_turn_lines<'a>(
    turn: &'a crate::app::CompletedTurn,
    is_selected: bool,
    wrap_width: usize,
) -> Vec<Line<'a>> {
    let chevron = if turn.expanded { "▼ " } else { "▶ " };
    // Selected row uses the SELECTED theme (reverse video) to make the
    // current Tab target visible. Unselected rows render in the standard
    // dim USER_PROMPT style — same as before this feature existed.
    let prompt_style = if is_selected {
        theme::SELECTED
    } else {
        theme::USER_PROMPT
    };
    let chevron_style = if is_selected {
        theme::SELECTED
    } else {
        theme::DIM
    };

    let mut lines = vec![Line::from(vec![
        Span::styled(chevron, chevron_style),
        Span::styled("> ", prompt_style),
        Span::styled(truncate_render_text(&turn.prompt), prompt_style),
    ])];

    if turn.expanded {
        // Render the captured details — the agent reply, tool calls,
        // plans, etc. — using the same builder as the active turn so the
        // formatting matches. `is_last_message=false` and
        // `agent_streaming=false` together suppress the streaming-cursor
        // path; details are always finalized by the time they land here.
        for msg in turn.details.iter() {
            lines.extend(build_message_lines(msg, false, false, wrap_width));
        }
    }

    lines.push(Line::default());
    lines
}

fn build_activity_line(app: &App) -> Option<Line<'static>> {
    if !(app.current_tab().prompt_in_flight || app.current_tab().agent_streaming || app.current_tab().progress_status.is_some()) {
        return None;
    }

    let mut spans = shimmer::shimmer_spans(ACTIVITY_LABEL, app.current_tab().activity_frame);

    if let Some((preview, style)) = activity_preview(app) {
        spans.push(Span::styled(" ", theme::DIM));
        spans.push(Span::styled(preview, style));
    }

    Some(Line::from(spans))
}

fn activity_preview(app: &App) -> Option<(String, Style)> {
    app.current_tab().progress_status
        .as_deref()
        // Server-side "Thinking..." (three ASCII dots) would duplicate the
        // shimmer label; drop it. The shimmer uses U+2026 so the strings
        // don't collide on equality.
        .filter(|s| *s != "Thinking...")
        .map(single_line_tail_preview)
        .filter(|text| !text.is_empty())
        .map(|text| (text, theme::DIM))
}

fn build_pending_stream_lines(_app: &App) -> Vec<Line<'_>> {
    // Don't render the raw agent response (typically JSON) while streaming.
    // The activity indicator is sufficient feedback; the final parsed
    // recommendations will appear when the response is finalized.
    Vec::new()
}

fn build_pending_text_lines<'a>(label: &str, text: &'a str, style: Style) -> Vec<Line<'a>> {
    let mut lines = Vec::new();
    lines.push(Line::from(Span::styled(format!("{label}:"), theme::DIM)));

    for line_text in text.lines() {
        lines.push(Line::from(Span::styled(
            truncate_render_text(line_text),
            style,
        )));
    }

    if text.lines().next().is_none() {
        lines.push(Line::from(Span::styled("", style)));
    }

    lines.push(Line::default());
    lines
}

fn single_line_tail_preview(text: &str) -> String {
    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let chars: Vec<char> = collapsed.chars().collect();

    if chars.len() <= ACTIVITY_PREVIEW_MAX_CHARS {
        return collapsed;
    }

    let tail: String = chars[chars.len().saturating_sub(ACTIVITY_PREVIEW_MAX_CHARS)..]
        .iter()
        .collect();
    format!("...{tail}")
}

fn build_message_lines<'a>(
    msg: &'a ChatMessage,
    is_last_message: bool,
    agent_streaming: bool,
    wrap_width: usize,
) -> Vec<Line<'a>> {
    let mut lines = Vec::new();
    match msg {
        ChatMessage::User(text) => {
            lines.push(Line::from(vec![
                Span::styled("> ", theme::USER_PROMPT),
                Span::styled(truncate_render_text(text), theme::USER_PROMPT),
            ]));
            lines.push(Line::default());
        }
        ChatMessage::Agent(text) => {
            push_dot_prefixed_lines(
                &mut lines,
                text,
                wrap_width,
                theme::DOT_AGENT,
                theme::AGENT_TEXT,
            );
            if !agent_streaming || !is_last_message {
                lines.push(Line::default());
            }
        }
        ChatMessage::System(text) => {
            for line_text in text.lines() {
                lines.push(Line::from(Span::styled(
                    truncate_render_text(line_text),
                    theme::SYSTEM_TEXT,
                )));
            }
            lines.push(Line::default());
        }
        ChatMessage::ToolCall { title, status, .. } => {
            lines.push(Line::from(Span::styled(
                format!(
                    "[{}] {}",
                    truncate_render_text(title),
                    truncate_render_text(status)
                ),
                theme::TOOL_CALL,
            )));
        }
        ChatMessage::Plan(entries) => {
            lines.push(Line::from(Span::styled("Plan:", theme::PLAN_STYLE)));
            for entry in entries {
                let marker = match entry.status {
                    PlanEntryStatus::Completed => "[x]",
                    PlanEntryStatus::InProgress => "[>]",
                    PlanEntryStatus::Pending => "[ ]",
                };
                lines.push(Line::from(Span::styled(
                    format!("  {} {}", marker, truncate_render_text(&entry.content)),
                    theme::PLAN_STYLE,
                )));
            }
            lines.push(Line::default());
        }
        ChatMessage::Error(text) => {
            push_dot_prefixed_lines(
                &mut lines,
                text,
                wrap_width,
                theme::DOT_ERROR,
                theme::ERROR_STYLE,
            );
            lines.push(Line::default());
        }
        ChatMessage::AgentEvent(text) => {
            for (i, line_text) in text.lines().enumerate() {
                if i == 0 {
                    lines.push(Line::from(Span::styled(
                        truncate_render_text(line_text),
                        theme::AGENT_EVENT_HEADER,
                    )));
                } else {
                    lines.push(Line::from(Span::styled(
                        truncate_render_text(line_text),
                        theme::AGENT_EVENT_DETAIL,
                    )));
                }
            }
            lines.push(Line::default());
        }
    }
    lines
}

// Render a multi-line text block with a colored dot prefix on the first
// visual row and a 2-cell hanging indent on every continuation row (both
// for explicit \n breaks AND for soft-wrapped continuations of long
// paragraphs). Without this, ratatui's Paragraph word-wrap pushes
// continuation rows back to column 0 and the bullet alignment breaks.
fn push_dot_prefixed_lines<'a>(
    lines: &mut Vec<Line<'a>>,
    text: &str,
    wrap_width: usize,
    dot_style: Style,
    text_style: Style,
) {
    // Reserve 2 cells for either "● " or the continuation indent.
    let body_width = wrap_width.saturating_sub(2).max(1);
    let mut first_row = true;

    for paragraph in text.split('\n') {
        if paragraph.is_empty() {
            // Preserve blank lines between paragraphs.
            if first_row {
                lines.push(Line::from(vec![
                    Span::styled("● ", dot_style),
                    Span::styled(String::new(), text_style),
                ]));
                first_row = false;
            } else {
                lines.push(Line::default());
            }
            continue;
        }

        let wrapped = textwrap::wrap(paragraph, body_width);
        for piece in wrapped {
            let piece_str = truncate_render_text(&piece).into_owned();
            if first_row {
                lines.push(Line::from(vec![
                    Span::styled("● ", dot_style),
                    Span::styled(piece_str, text_style),
                ]));
                first_row = false;
            } else {
                lines.push(Line::from(vec![
                    Span::raw("  "),
                    Span::styled(piece_str, text_style),
                ]));
            }
        }
    }
}

fn truncate_render_text(text: &str) -> Cow<'_, str> {
    let char_count = text.chars().count();
    if char_count <= MAX_RENDER_LINE_CHARS {
        return Cow::Borrowed(text);
    }

    let head_chars = MAX_RENDER_LINE_CHARS * 3 / 4;
    let tail_chars = MAX_RENDER_LINE_CHARS / 4;
    let omitted = char_count.saturating_sub(head_chars + tail_chars);
    let head: String = text.chars().take(head_chars).collect();
    let tail: String = text
        .chars()
        .skip(char_count.saturating_sub(tail_chars))
        .collect();

    Cow::Owned(format!("{head} ...<{omitted} chars omitted>... {tail}"))
}
