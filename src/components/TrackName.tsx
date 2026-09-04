/**
 * The track's name in the crumb bar, editable where it is shown.
 *
 * A track is named before anybody knows what it is: from a pull request's
 * title, a branch, or the yard's own list when it started from nothing. By the
 * time the work has a shape that name is often wrong, and the rail is the one
 * place four tracks are told apart — so it has to be fixable, and fixable
 * where you read it rather than behind a settings panel.
 *
 * It changes the *label* and nothing else. The slug, the branch and the
 * worktree were cut on a real machine when the track opened; moving them now
 * would mean moving a directory somebody is working in, and a rename box is
 * not the place to offer that.
 */
import { useEffect, useRef, useState } from "react";
import type { Track } from "../../shared/api";
import { api, ApiError } from "../lib/api";
import { Pencil } from "../lib/icons";

export interface TrackNameProps {
  track: Track;
  /** Whose name to compare against the track's cutter. */
  viewerLogin: string;
  /** Called once the server has taken it, so the rail and the crumb agree. */
  onRenamed: () => void;
  onError: (message: string) => void;
}

export function TrackName({ track, viewerLogin, onRenamed, onError }: TrackNameProps) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(track.title);
  const [saving, setSaving] = useState(false);
  const box = useRef<HTMLInputElement>(null);
  // Escape and Enter both take the focus off the box, and the browser follows
  // either with a blur — which is also how you save. Without these two the
  // gesture you meant arrives a second time as the one you did not.
  const done = useRef(false);

  // Selecting another track while the box is open closes it. Carrying an
  // unsaved name onto a different track is the one outcome here that would be
  // worse than losing it.
  useEffect(() => setEditing(false), [track.id]);

  useEffect(() => {
    if (editing) box.current?.select();
  }, [editing]);

  // The two the server takes: the project's owner, and whoever cut this track
  // — a project member can open one, and a name they chose that they cannot
  // then fix is a worse rule than the one this is guarding. Anybody else gets
  // the name as text rather than a control that answers 403.
  const mine = track.role === "owner" || track.createdByLogin.toLowerCase() === viewerLogin.toLowerCase();
  if (!mine) return <span className="truncate">{track.title}</span>;

  async function commit(): Promise<void> {
    if (done.current) return;
    const title = draft.trim();
    if (!title || title === track.title) {
      setEditing(false);
      return;
    }
    done.current = true;
    setSaving(true);
    try {
      await api.renameTrack(track.id, title);
      setEditing(false);
      onRenamed();
    } catch (err) {
      // The box stays open, holding what they typed. A failed save that also
      // throws the name away asks somebody to type it twice.
      done.current = false;
      onError(err instanceof ApiError ? err.message : "That rename did not go through.");
    } finally {
      setSaving(false);
    }
  }

  if (!editing) {
    return (
      <button
        type="button"
        className="crumb-name"
        title={`${track.title} — click to rename`}
        onClick={() => {
          setDraft(track.title);
          done.current = false;
          setEditing(true);
        }}
      >
        <span className="truncate">{track.title}</span>
        <span className="ico" aria-hidden="true">
          <Pencil size={11} />
        </span>
      </button>
    );
  }

  return (
    <input
      ref={box}
      className="crumb-name"
      autoFocus
      aria-label="Track name"
      value={draft}
      disabled={saving}
      maxLength={200}
      onChange={(e) => setDraft(e.target.value)}
      // Clicking away saves, the way every other rename-in-place does. Escape
      // is the way out, and it has to come before the blur that follows it.
      onBlur={() => void commit()}
      onKeyDown={(e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          void commit();
        } else if (e.key === "Escape") {
          e.preventDefault();
          done.current = true;
          setEditing(false);
        }
      }}
    />
  );
}
