/**
 * The empty state, which in this app is a designed surface rather than a gap.
 *
 * Switchyard is a clone of a desktop app that has a local machine underneath
 * it, and this one has a sandbox in somebody else's cloud. Some of what
 * Conductor does therefore has no API behind it here — not yet, and in a
 * couple of cases not ever. Every one of those places gets this component
 * instead of a disabled button or, worse, a control that does nothing.
 *
 * It insists on three things, because a "coming soon" that leaves any of them
 * out is the kind that makes people stop trusting the rest of the app:
 *
 *   - **What it would do**, in a sentence, so the absence is legible.
 *   - **Why it is not here**, concretely — a missing environment variable, a
 *     capability the platform does not expose — rather than "coming soon".
 *   - **What to do instead**, when there is something, because most of the
 *     time there is.
 */
import type { ReactNode } from "react";

export interface EmptyProps {
  icon: ReactNode;
  title: string;
  /** One or two sentences. What this panel is for. */
  children: ReactNode;
  /** Set for a surface that genuinely is not built yet. */
  soon?: boolean;
  /** The concrete reason, when there is one: a variable, a permission, a state. */
  because?: ReactNode;
  action?: { label: string; onClick: () => void } | null;
}

export function Empty({ icon, title, children, soon, because, action }: EmptyProps) {
  return (
    <div className="empty">
      <span className="mark">{icon}</span>
      <h3>{title}</h3>
      <p>{children}</p>
      {because ? <p className="dimmer">{because}</p> : null}
      {soon ? <span className="soon">Coming soon</span> : null}
      {action ? (
        <button type="button" className="primary" style={{ marginTop: 6 }} onClick={action.onClick}>
          {action.label}
        </button>
      ) : null}
    </div>
  );
}

/**
 * A panel that is off because this deployment did not configure it.
 *
 * Distinguished from "coming soon" on purpose: this feature is *built*, and
 * whether you have it is a decision somebody made about this server. Saying
 * "coming soon" about working code is a lie that costs you the next honest
 * message too.
 */
export function NotConfigured({ icon, title, variable, children }: { icon: ReactNode; title: string; variable: string; children: ReactNode }) {
  return (
    <Empty
      icon={icon}
      title={title}
      because={
        <>
          This switchyard has no <code>{variable}</code>, so the feature is switched off here rather than unfinished.
        </>
      }
    >
      {children}
    </Empty>
  );
}
