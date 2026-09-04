/**
 * The prompt box.
 *
 * Two behaviours here are load-bearing rather than decorative, and both come
 * from the same fact: a project is one machine, and a machine runs one turn at
 * a time across every track on it.
 *
 * **The box never locks.** A composer disabled while the agent works teaches
 * people to sit and wait, which is exactly the wrong habit in an app whose
 * whole point is having four things in flight. So Enter always accepts, and a
 * prompt sent into a busy machine is *queued here* and sent when the machine
 * frees up — the line above the box says so, with the option to unsend.
 *
 * **Stop is a first-class control.** Not a small x on a spinner somewhere: the
 * send button becomes a stop button while a turn is running, in the same
 * place, because the thing you most want when an agent is doing the wrong
 * thing is the button your hand is already on.
 */
import { useEffect, useRef, useState } from "react";
import { ArrowUp, X } from "../lib/icons";

export interface ComposerProps {
  /** Sends now. Rejects if the machine refuses; the caller surfaces that. */
  onSend: (text: string) => Promise<void>;
  onInterrupt: () => void;
  running: boolean;
  /** The model the project's agent runs, shown but not chosen here. */
  model: string;
  disabled?: boolean;
  placeholder?: string;
}

export function Composer({ onSend, onInterrupt, running, model, disabled, placeholder }: ComposerProps) {
  const [text, setText] = useState("");
  const [queued, setQueued] = useState<string | null>(null);
  const [sending, setSending] = useState(false);
  const box = useRef<HTMLTextAreaElement | null>(null);

  // Grow with the content up to a ceiling, then scroll. A textarea that grows
  // without limit pushes the transcript off the screen at exactly the moment
  // somebody is writing a long instruction and wants to see what they are
  // instructing about.
  useEffect(() => {
    const el = box.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight, 260)}px`;
  }, [text]);

  // The queued line sends itself the moment the machine is free.
  useEffect(() => {
    if (!queued || running || sending) return;
    const pending = queued;
    setQueued(null);
    void deliver(pending);
    // `deliver` is stable enough for this: it closes over setters only.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [queued, running, sending]);

  async function deliver(value: string): Promise<void> {
    setSending(true);
    try {
      await onSend(value);
    } catch {
      // The caller has already shown why. Put the words back rather than
      // losing them — a composer that eats a paragraph on a network blip is
      // unforgivable in a way a visible error is not.
      setText((current) => (current ? current : value));
    } finally {
      setSending(false);
    }
  }

  function submit(): void {
    const value = text.trim();
    if (!value || disabled) return;
    setText("");
    if (running || sending) setQueued(value);
    else void deliver(value);
  }

  return (
    <div className="composer">
      {queued ? (
        <div className="queued row">
          <span className="truncate">Queued behind the turn running now — it sends itself.</span>
          <button
            type="button"
            className="x"
            aria-label="Unsend the queued message"
            onClick={() => {
              setText((current) => current || queued);
              setQueued(null);
            }}
          >
            <X size={13} />
          </button>
        </div>
      ) : null}
      <div className="composer-box">
        <textarea
          ref={box}
          rows={1}
          value={text}
          disabled={disabled}
          placeholder={placeholder ?? "Ask for a change, or a question about this branch"}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => {
            // Enter sends, Shift+Enter is a newline. The other way round is
            // correct for a document and wrong for a conversation.
            if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
              e.preventDefault();
              submit();
            }
          }}
        />
        <div className="composer-foot">
          <div className="meta">
            <span className="mono">{model}</span>
            <span>
              <kbd>⏎</kbd> to send
            </span>
          </div>
          <span className="spacer" />
          {running ? (
            <button type="button" className="send" onClick={onInterrupt} aria-label="Stop this turn" title="Stop this turn">
              <span style={{ width: 9, height: 9, background: "currentColor", borderRadius: 2 }} />
            </button>
          ) : (
            <button
              type="button"
              className="send"
              onClick={submit}
              disabled={!text.trim() || disabled || sending}
              aria-label="Send"
              title="Send"
            >
              <ArrowUp size={15} />
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
