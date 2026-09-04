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
 *
 * Images arrive by paste, by drop and by the picker, and all three land in the
 * same list: a screenshot is the fastest way to say what is wrong with a page,
 * and every gesture somebody already has for moving one should work.
 */
import { useEffect, useRef, useState } from "react";
import { ArrowUp, Picture, X } from "../lib/icons";
import { accept, ACCEPTED, encodeImage, MAX_IMAGES, type OutgoingImage, rejectionMessage } from "../lib/images";

export interface ComposerProps {
  /** Sends now. Rejects if the machine refuses; the caller surfaces that. */
  onSend: (text: string, images: OutgoingImage[]) => Promise<void>;
  onInterrupt: () => void;
  /**
   * Keys are being pressed with something in the box.
   *
   * Called on every keystroke and throttled by the caller, because the rate
   * that matters is the server's typing lease rather than anything this
   * component knows about. There is no matching "stopped": the claim expires
   * on its own, so a box left half-written simply goes quiet.
   */
  onTyping?: () => void;
  running: boolean;
  /** The model the project's agent runs, shown but not chosen here. */
  model: string;
  disabled?: boolean;
  placeholder?: string;
}

/** One image on the way out, plus the object URL its thumbnail is drawn from. */
interface Attachment {
  id: string;
  file: File;
  name: string;
  url: string;
}

/** A prompt that has left the box: the words, and the images that go with them. */
interface Pending {
  text: string;
  items: Attachment[];
}

export function Composer({ onSend, onInterrupt, onTyping, running, model, disabled, placeholder }: ComposerProps) {
  const [text, setText] = useState("");
  const [items, setItems] = useState<Attachment[]>([]);
  const [note, setNote] = useState<string | null>(null);
  const [dragging, setDragging] = useState(false);
  const [queued, setQueued] = useState<Pending | null>(null);
  const [sending, setSending] = useState(false);
  const box = useRef<HTMLTextAreaElement | null>(null);
  const picker = useRef<HTMLInputElement | null>(null);
  /**
   * Every object URL this composer has minted and not yet handed back.
   *
   * An attachment can be in three places at once — the list on screen, a queued
   * prompt, a send in flight — so "revoke it when it leaves the list" is not a
   * rule that holds. One set, written by whoever creates or releases a URL, is:
   * it is also what the unmount below can drain, which is the case that
   * otherwise leaks a megabyte per track somebody clicked away from.
   */
  const urls = useRef(new Set<string>());

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

  useEffect(() => {
    const held = urls.current;
    return () => {
      for (const url of held) URL.revokeObjectURL(url);
      held.clear();
    };
  }, []);

  // The queued line sends itself the moment the machine is free.
  useEffect(() => {
    if (!queued || running || sending) return;
    const pending = queued;
    setQueued(null);
    void deliver(pending);
    // `deliver` is stable enough for this: it closes over setters only.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [queued, running, sending]);

  function release(url: string): void {
    if (!urls.current.delete(url)) return;
    URL.revokeObjectURL(url);
  }

  /**
   * Files from a paste, a drop or the picker — the three are the same gesture.
   *
   * Nothing is filtered on the way in. A dropped PDF is a person who meant
   * something by it, and telling them it is not an image they can attach is a
   * better answer than a drop that appears to do nothing at all.
   */
  function attach(files: FileList | File[] | null): boolean {
    const incoming = Array.from(files ?? []);
    if (!incoming.length) return false;
    const { accepted, rejected } = accept(incoming, items.length);
    setNote(rejectionMessage(rejected));
    if (!accepted.length) return rejected.length > 0;
    setItems((current) => [
      ...current,
      ...accepted.map((file) => {
        const url = URL.createObjectURL(file);
        urls.current.add(url);
        return { id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`, file, name: file.name || "image", url };
      }),
    ]);
    return true;
  }

  function remove(id: string): void {
    setItems((current) => {
      const going = current.find((item) => item.id === id);
      if (going) release(going.url);
      return current.filter((item) => item.id !== id);
    });
    setNote(null);
  }

  /** Put a prompt that did not go back in the box, images and all. */
  function restore(pending: Pending): void {
    setText((current) => (current ? current : pending.text));
    setItems((current) => {
      // Whatever was attached while this one was in flight stays; the returning
      // images go in front of it, and anything over the limit is dropped here
      // rather than being carried as a prompt the server would refuse.
      const merged = [...pending.items, ...current];
      for (const extra of merged.slice(MAX_IMAGES)) release(extra.url);
      return merged.slice(0, MAX_IMAGES);
    });
  }

  async function deliver(pending: Pending): Promise<void> {
    setSending(true);
    try {
      let images: OutgoingImage[];
      try {
        images = await Promise.all(pending.items.map((item) => encodeImage(item.file)));
      } catch {
        // Reading a file off the disk failed — it was moved, or the browser
        // will not hand it over. Nobody else is going to report that.
        setNote("Those images could not be read.");
        restore(pending);
        return;
      }
      await onSend(pending.text, images);
      for (const item of pending.items) release(item.url);
    } catch {
      // The caller has already shown why. Put the words back rather than
      // losing them — a composer that eats a paragraph on a network blip is
      // unforgivable in a way a visible error is not.
      restore(pending);
    } finally {
      setSending(false);
    }
  }

  function submit(): void {
    const value = text.trim();
    // A prompt of nothing but a screenshot is a real prompt: "look at this" is
    // most of what somebody wants to say about a picture.
    if ((!value && !items.length) || disabled) return;
    const pending: Pending = { text: value, items };
    setText("");
    setItems([]);
    setNote(null);
    if (running || sending) setQueued(pending);
    else void deliver(pending);
  }

  const nothingToSend = !text.trim() && items.length === 0;

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
              restore(queued);
              setQueued(null);
            }}
          >
            <X size={13} />
          </button>
        </div>
      ) : null}
      {note ? (
        <div className="composer-note" role="status">
          {note}
        </div>
      ) : null}
      <div
        className={`composer-box${dragging ? " dragging" : ""}`}
        onDragOver={(e) => {
          if (!e.dataTransfer.types.includes("Files")) return;
          // Without this the browser navigates to the dropped file, which
          // discards whatever was half-written in the box.
          e.preventDefault();
          setDragging(true);
        }}
        onDragLeave={(e) => {
          if (e.currentTarget.contains(e.relatedTarget as Node | null)) return;
          setDragging(false);
        }}
        onDrop={(e) => {
          if (!e.dataTransfer.types.includes("Files")) return;
          e.preventDefault();
          setDragging(false);
          attach(e.dataTransfer.files);
        }}
      >
        {items.length ? (
          <div className="attachments">
            {items.map((item) => (
              <div key={item.id} className="attachment">
                <img src={item.url} alt={item.name} />
                <button type="button" className="x" aria-label={`Remove ${item.name}`} onClick={() => remove(item.id)}>
                  <X size={11} />
                </button>
              </div>
            ))}
          </div>
        ) : null}
        <textarea
          ref={box}
          rows={1}
          value={text}
          disabled={disabled}
          placeholder={placeholder ?? "Ask for a change, or a question about this branch"}
          onChange={(e) => {
            setText(e.target.value);
            // Only while there is something in the box. Emptying it is not
            // typing, and neither is clearing it to start again — the claim
            // that was already made lapses three seconds later on its own.
            if (e.target.value.trim()) onTyping?.();
          }}
          onPaste={(e) => {
            // Only when the clipboard actually carried files. Pasting text
            // that happens to come from an image editor must still paste.
            if (attach(e.clipboardData.files)) e.preventDefault();
          }}
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
          <input
            ref={picker}
            type="file"
            className="offscreen"
            accept={ACCEPTED.join(",")}
            multiple
            tabIndex={-1}
            onChange={(e) => {
              attach(e.target.files);
              // Same file twice in a row is a real thing to want, and it fires
              // no change event unless the input is cleared first.
              e.target.value = "";
            }}
          />
          <button
            type="button"
            className="attach"
            onClick={() => picker.current?.click()}
            disabled={disabled || items.length >= MAX_IMAGES}
            aria-label="Attach an image"
            title="Attach an image"
          >
            <Picture size={15} />
          </button>
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
              disabled={nothingToSend || disabled || sending}
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
