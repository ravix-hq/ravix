import type { Project, Track } from "../../shared/api";
import { attentionItems } from "../lib/inbox";

export function Inbox({ projectsState = "ready", projects, tracksByProject, errors, onRetry, onPick }: {
  projectsState?: "loading" | "ready" | "error";
  projects: Project[];
  tracksByProject: Record<string, Track[]>;
  errors: Record<string, boolean>;
  onRetry: () => void;
  onPick: (projectId: string, trackId: string) => void;
}) {
  const items = attentionItems(projects, tracksByProject);
  const failed = projects.filter((p) => errors[p.id]);
  const loading = projectsState === "loading" || projects.some((p) => !tracksByProject[p.id] && !errors[p.id]);
  return (
    <section className="inbox" aria-labelledby="inbox-title">
      <header className="row">
        <div className="spacer">
          <h1 id="inbox-title">Inbox <span className="chip">{items.length}</span></h1>
          <p className="dim">Replies and failed turns across all your projects.</p>
        </div>
        <button type="button" className="ghost" onClick={onRetry}>Refresh</button>
      </header>
      {loading ? <p role="status" className="dim">Checking projects…</p> : null}
      {projectsState === "error" ? <p role="alert" className="error">Could not refresh your projects. Results may be incomplete. <button type="button" className="ghost" onClick={onRetry}>Retry</button></p> : null}
      {failed.length ? <p role="alert" className="error">Could not refresh {failed.map((p) => p.name).join(", ")}. Results may be incomplete or out of date. <button type="button" className="ghost" onClick={onRetry}>Retry</button></p> : null}
      {!items.length && !loading && projectsState === "ready" && !failed.length ? (
        <div className="inbox-empty"><h2>You're caught up</h2><p className="dim">New replies and failed turns will appear here. Updates refresh every 30 seconds.</p></div>
      ) : null}
      <ul className="inbox-list">
        {items.map(({ project, track }) => (
          <li key={track.id}>
            <a className="inbox-item" href={`/p/${project.id}/t/${track.id}`} onClick={(event) => {
              if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
              event.preventDefault();
              onPick(project.id, track.id);
            }}>
              <div className="row"><span className="chip">{track.status === "failed" ? "Turn failed" : "Unread reply"}</span><span className="dim truncate">{project.name}</span><span className="spacer" />
                <time className="dim" dateTime={track.lastActiveAt ?? track.createdAt}>{new Date(track.lastActiveAt ?? track.createdAt).toLocaleString()}</time>
              </div>
              <strong>{track.title}</strong>
              <span className="dim mono truncate">{track.branch}</span>
              <span className="dim">{track.status === "failed" ? "Open the conversation to review what went wrong." : "The agent finished. Open the conversation to read its reply."}</span>
            </a>
          </li>
        ))}
      </ul>
    </section>
  );
}
