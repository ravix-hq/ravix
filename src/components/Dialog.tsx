/**
 * The shell every modal in this app sits in.
 *
 * A dialog is the one place a web app can trap somebody: focus wanders out
 * behind the scrim, Escape does nothing, and the thing that opened it is gone
 * by the time it closes. So the behaviour lives here once rather than in each
 * picker — Escape and a scrim click close it, Tab cycles inside it, and focus
 * goes back to whatever opened it — and a new dialog gets all of that by
 * existing.
 *
 * `children` is dropped straight between the head and the foot rather than
 * inside a body element, because the pickers need two regions with different
 * scroll behaviour: a `.search-line` that stays put and a `.dialog-body` that
 * scrolls under it. A shell that wrapped everything in one scrolling body
 * would scroll the search field off the top of the list it filters.
 */
import { useEffect, useId, useRef, type ReactNode } from "react";
import { X } from "../lib/icons";

/**
 * What Tab is allowed to land on. Deliberately not `[contenteditable]` or an
 * `iframe`: nothing in this app renders either inside a dialog, and a selector
 * that matches things that are never there is a claim the code cannot keep.
 */
const FOCUSABLE =
  'a[href], button:not(:disabled), input:not(:disabled), textarea:not(:disabled), select:not(:disabled), [tabindex]:not([tabindex="-1"])';

export interface DialogProps {
  title: string;
  onClose: () => void;
  children: ReactNode;
  footer?: ReactNode;
  /** For a sheet of fields rather than a list of rows, which needs the room. */
  wide?: boolean;
}

export function Dialog({ title, onClose, children, footer, wide }: DialogProps) {
  const frame = useRef<HTMLDivElement>(null);
  const opener = useRef<Element | null>(null);
  const downOnScrim = useRef(false);
  const titleId = useId();

  // Held in a ref so the key and focus effects can run once for the life of
  // the dialog: a caller that passes a fresh arrow function on every render —
  // which is every caller — would otherwise rebind the document listener and
  // re-run the focus restore on each keystroke it renders through.
  const close = useRef(onClose);
  close.current = onClose;

  useEffect(() => {
    opener.current = document.activeElement;
    const node = frame.current;
    // Only if nothing inside has already claimed it: a picker autofocuses its
    // filter field on mount, and stealing that back to the close button would
    // make every dialog open one Tab away from being usable.
    if (node && !node.contains(document.activeElement)) {
      (node.querySelector<HTMLElement>(FOCUSABLE) ?? node).focus();
    }
    return () => {
      const back = opener.current;
      // `document.contains` because the opener is often a row in a list the
      // dialog just changed — focusing a detached node silently moves focus
      // to the body, which is where keyboard users get lost.
      if (back instanceof HTMLElement && document.contains(back)) back.focus();
    };
  }, []);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.stopPropagation();
        close.current();
        return;
      }
      if (event.key !== "Tab") return;
      const node = frame.current;
      if (!node) return;
      const items = [...node.querySelectorAll<HTMLElement>(FOCUSABLE)].filter((el) => el.offsetParent !== null);
      if (!items.length) {
        event.preventDefault();
        node.focus();
        return;
      }
      const first = items[0]!;
      const last = items[items.length - 1]!;
      const here = document.activeElement;
      const outside = !node.contains(here);
      if (event.shiftKey && (here === first || outside)) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && (here === last || outside)) {
        event.preventDefault();
        first.focus();
      }
    };
    // Capture, so a picker that handles arrows and Enter on its own input
    // still cannot swallow Escape before the dialog sees it.
    document.addEventListener("keydown", onKey, true);
    return () => document.removeEventListener("keydown", onKey, true);
  }, []);

  return (
    <div
      className="scrim"
      // Both halves of the click have to land on the scrim. Without the
      // mousedown check, selecting text in the dialog and releasing outside it
      // closes the dialog and throws away whatever was being read.
      onMouseDown={(e) => {
        downOnScrim.current = e.target === e.currentTarget;
      }}
      onClick={(e) => {
        if (downOnScrim.current && e.target === e.currentTarget) onClose();
      }}
    >
      <div
        ref={frame}
        className="dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        tabIndex={-1}
        style={wide ? { width: "min(860px, 100%)" } : undefined}
      >
        <div className="dialog-head">
          <h2 id={titleId}>{title}</h2>
          <span className="spacer" />
          <button type="button" className="x" onClick={onClose} aria-label="Close">
            <X size={16} />
          </button>
        </div>
        {children}
        {footer ? <div className="dialog-foot">{footer}</div> : null}
      </div>
    </div>
  );
}

/**
 * "pushed 3 days ago", from an ISO timestamp.
 *
 * Rounded rather than precise, and it lives beside the dialog shell because
 * the pickers are the only surfaces that show one — every other timestamp in
 * this app is either live or absolute. An unparseable date returns an empty
 * string instead of "NaN days ago": GitHub can hand back a null `pushed_at`
 * for a repository that has never had a commit, and that is not an error.
 */
export function ago(iso: string | null): string {
  if (!iso) return "";
  const then = Date.parse(iso);
  if (Number.isNaN(then)) return "";
  const minutes = Math.round(Math.max(0, Date.now() - then) / 60_000);
  if (minutes < 1) return "just now";
  if (minutes < 60) return count(minutes, "minute");
  const hours = Math.round(minutes / 60);
  if (hours < 24) return count(hours, "hour");
  const days = Math.round(hours / 24);
  if (days < 30) return count(days, "day");
  const months = Math.round(days / 30);
  if (months < 12) return count(months, "month");
  return count(Math.round(months / 12), "year");
}

const count = (n: number, unit: string) => `${n} ${unit}${n === 1 ? "" : "s"} ago`;
