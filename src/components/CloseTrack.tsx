/**
 * Closing a track: the one gesture in this app that takes a directory away.
 *
 * It is a dialog rather than an `x` on the rail row because the two things it
 * does have opposite weights and both have to be said before it happens. The
 * worktree goes, and it is the only copy of anything not committed. The branch
 * stays, and people expect "close" to mean "delete my work" — a track closed by
 * somebody who thought they were throwing the branch away is as bad an outcome
 * as the reverse.
 *
 * So the worktree is read for uncommitted changes *before* the button is drawn,
 * and the button says what it is about to do with them. `git worktree remove`
 * refuses a dirty worktree, so a close with changes in it is a discard whether
 * or not the person is told; the only choice is whether they were.
 */
import { useState } from "react";
import type { Track } from "../../shared/api";
import { api, ApiError } from "../lib/api";
import { useDiff } from "./Changes";
import { Dialog } from "./Dialog";

export interface CloseTrackProps {
  track: Track;
  onClose: () => void;
  /** Closed, and gone from the rail. The message is for the toast. */
  onClosed: (message: string) => void;
}

export function CloseTrack({ track, onClose, onClosed }: CloseTrackProps) {
  const diff = useDiff(track.id);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const changed = diff.report?.files ?? [];
  const dirty = changed.length;

  async function close(): Promise<void> {
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      // Forced exactly when there is something to force past. `--force` on a
      // clean worktree is harmless, but sending it always would make the
      // sentence in the transcript — "changes are being discarded on purpose"
      // — a lie in the ordinary case.
      await api.closeTrack(track.id, dirty > 0);
      onClosed(
        dirty > 0
          ? `Closed ${track.title}. The worktree and its uncommitted changes are gone; ${track.branch} is not.`
          : `Closed ${track.title}. The worktree is being removed; ${track.branch} is untouched.`,
      );
    } catch (err) {
      setBusy(false);
      setError(err instanceof ApiError ? err.message : "Could not close this track.");
    }
  }

  return (
    <Dialog
      title={`Close ${track.title}?`}
      onClose={onClose}
      footer={
        <>
          <span className="fine">
            {dirty > 0 ? "That work exists in this worktree and nowhere else." : "The branch survives this; the directory does not."}
          </span>
          <span className="spacer" />
          <button type="button" disabled={busy} onClick={onClose}>
            Cancel
          </button>
          {/* Disabled until the check is in, so the label cannot change under
              somebody's cursor between reading it and clicking it. */}
          <button type="button" className="danger" disabled={busy || diff.loading} onClick={() => void close()}>
            {busy
              ? "Closing…"
              : dirty > 0
                ? `Discard ${dirty} file${dirty === 1 ? "" : "s"} and close`
                : "Close track"}
          </button>
        </>
      }
    >
      <div className="dialog-body">
        {error ? <p className="fine error">{error}</p> : null}

        <p className="fine">
          The machine runs <code>git worktree remove</code> on <code>{track.workdir}</code> and this track&rsquo;s
          conversation ends. It ends for everybody in it, not only for you.
        </p>
        <p className="fine">
          The branch <code>{track.branch}</code> is left alone. Every commit on it survives, pushed or not, and nothing
          on GitHub is touched — a closed track is a tab shut, not work thrown away.
        </p>

        {diff.loading ? <p className="fine">Checking the worktree for uncommitted changes…</p> : null}

        {/* The check runs `git diff` on the box, so it fails for the ordinary
            reasons a box is unreachable — asleep, rebuilt, an opening turn that
            never landed. None of those are a reason to refuse to close a row,
            so the close goes ahead unforced and this says what was not known. */}
        {!diff.loading && !diff.report ? (
          <p className="fine">
            Could not look for uncommitted changes{diff.error ? `: ${diff.error.message.replace(/\.$/, "")}` : ""}. This
            close will not force, so if the worktree turns out to be dirty the machine says so and leaves the directory
            where it is.
          </p>
        ) : null}

        {dirty > 0 ? (
          <p className="fine error">
            {dirty === 1 ? "One file has" : `${dirty} files have`} uncommitted changes here
            {changed.length <= 3 ? (
              <>
                {" — "}
                {changed.map((f, i) => (
                  <span key={f.path}>
                    {i > 0 ? ", " : ""}
                    <code>{f.path}</code>
                  </span>
                ))}
              </>
            ) : null}
            . <code>git worktree remove</code> refuses a dirty worktree, so closing now discards them. Commit or push
            first if you want them.
          </p>
        ) : null}
      </div>
    </Dialog>
  );
}
