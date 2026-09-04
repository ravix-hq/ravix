/**
 * Who is on a track, and how somebody else gets here.
 *
 * Sharing in switchyard is per *track*, so this dialog is deliberately small:
 * it is a membership list for one branch, not a permissions matrix for a
 * project. The only genuinely difficult thing on the surface is the paragraph
 * near the bottom, which has to describe what an invitation actually buys —
 * and the true answer is broader than the tidy one. `server/people.ts` holds
 * the same sentence in its header, and the two must not drift: a member is
 * confined to this track by routing, but the worktrees share one machine, and
 * the agent staying in its own directory is a rule rather than a wall.
 *
 * Owners and members see different dialogs from the same component, because
 * the server enforces the same split and rendering a control that answers 403
 * is a worse experience than not offering it.
 */
import { useEffect, useId, useMemo, useRef, useState, type KeyboardEvent as ReactKeyboardEvent } from "react";
import type { Person, Track } from "../../shared/api";
import { api } from "../lib/api";
import { Search, X } from "../lib/icons";
import { Dialog } from "./Dialog";

const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

/** A round avatar, or the first letter of the login when GitHub has no image. */
function Face({ person }: { person: Person }) {
  if (person.avatarUrl) return <img className="face" src={person.avatarUrl} alt="" />;
  return (
    <span className="face" aria-hidden="true">
      {person.login.slice(0, 1).toUpperCase()}
    </span>
  );
}

export interface PeopleStackProps {
  people: Person[];
  onOpen: () => void;
  /** Faces drawn before the rest collapse into a `+N`. */
  max?: number;
}

/**
 * The overlapping faces in the track header.
 *
 * Nothing renders below two people. A track you have not shared is the normal
 * case, and a lone avatar of yourself in the header would be a permanent
 * ornament that never told anybody anything — the stack is only worth the room
 * it takes once it is reporting a fact you did not already know.
 */
export function PeopleStack({ people, onOpen, max = 3 }: PeopleStackProps) {
  if (people.length < 2) return null;
  const shown = people.slice(0, max);
  const rest = people.length - shown.length;
  return (
    <button
      type="button"
      className="ghost people-stack"
      onClick={onOpen}
      aria-label={`${people.length} people on this track`}
      title={people.map((p) => `@${p.login}`).join(", ")}
    >
      {shown.map((p) => (
        <Face key={p.login} person={p} />
      ))}
      {rest > 0 ? <span className="face more">+{rest}</span> : null}
    </button>
  );
}

export interface PeopleProps {
  track: Track;
  viewerLogin: string;
  onClose: () => void;
  /** The membership the server just returned, so the shell can re-read the track. */
  onChanged: (people: Person[]) => void;
}

export function People({ track, viewerLogin, onClose, onChanged }: PeopleProps) {
  const [people, setPeople] = useState<Person[]>(track.people);
  const [q, setQ] = useState("");
  const [found, setFound] = useState<Person[]>([]);
  const [listOpen, setListOpen] = useState(false);
  const [at, setAt] = useState(0);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [leaving, setLeaving] = useState(false);
  const listId = useId();

  const owner = track.role === "owner";

  // The track came with its membership attached, so the list is drawn before
  // this lands. Re-reading is for the case where somebody was added from
  // another window since the detail was fetched; a failure here leaves the
  // known-good list in place rather than replacing it with an error about a
  // refresh nobody asked for.
  useEffect(() => {
    let live = true;
    void api.people(track.id).then(
      (rows) => live && setPeople(rows),
      () => undefined,
    );
    return () => {
      live = false;
    };
  }, [track.id]);

  // The autocomplete. The timer is the debounce and the `live` flag is the
  // ordering guarantee: every keystroke tears down the previous effect, so a
  // slow response for "ja" cannot land after a fast one for "jake" and quietly
  // replace the newer list with the older one.
  useEffect(() => {
    const needle = q.trim().replace(/^@/, "");
    if (needle.length < 1) {
      setFound([]);
      return;
    }
    let live = true;
    const timer = setTimeout(() => {
      void api.findPeople(needle).then(
        (rows) => {
          if (!live) return;
          setFound(rows);
          setAt(0);
        },
        () => live && setFound([]),
      );
    }, 180);
    return () => {
      live = false;
      clearTimeout(timer);
    };
  }, [q]);

  // Suggesting somebody who is already here would offer an invitation that
  // cannot be sent, so they come out of the list rather than being shown and
  // then refused.
  const suggestions = useMemo(
    () => found.filter((f) => !people.some((p) => same(p.login, f.login))),
    [found, people],
  );
  const showList = listOpen && suggestions.length > 0;
  const cursor = suggestions.length ? Math.min(at, suggestions.length - 1) : 0;

  // Escape has two meanings while the suggestion list is up, and the inner one
  // has to win. `Dialog` listens on `document` in the capture phase, which runs
  // before anything React binds — so this listens one node further out, on the
  // window, where capture reaches it first and `stopPropagation` can keep the
  // dialog from closing out from under a half-typed name.
  const openRef = useRef(showList);
  openRef.current = showList;
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || !openRef.current) return;
      event.stopPropagation();
      setListOpen(false);
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, []);

  async function invite(login: string): Promise<void> {
    const name = login.trim().replace(/^@/, "");
    if (!name || busy) return;
    setBusy(true);
    setError(null);
    try {
      const next = await api.invite(track.id, name);
      setPeople(next);
      onChanged(next);
      setQ("");
      setFound([]);
      setListOpen(false);
    } catch (err) {
      // Including the 404 for a login nobody here has: the server's sentence
      // says why better than a guess made before the call would have.
      setError(err instanceof Error ? err.message : "Could not invite that person.");
    } finally {
      setBusy(false);
    }
  }

  async function drop(login: string): Promise<void> {
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      const next = await api.uninvite(track.id, login);
      if (next) {
        setPeople(next);
        onChanged(next);
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not remove that person.");
    } finally {
      setBusy(false);
    }
  }

  async function leave(): Promise<void> {
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      await api.uninvite(track.id, viewerLogin);
      onClose();
    } catch (err) {
      setBusy(false);
      setError(err instanceof Error ? err.message : "Could not leave this track.");
    }
  }

  function onKeyDown(event: ReactKeyboardEvent): void {
    if (event.key === "ArrowDown" && suggestions.length) {
      event.preventDefault();
      setListOpen(true);
      setAt((n) => (Math.min(n, suggestions.length - 1) + 1) % suggestions.length);
    } else if (event.key === "ArrowUp" && suggestions.length) {
      event.preventDefault();
      setListOpen(true);
      setAt((n) => (Math.min(n, suggestions.length - 1) + suggestions.length - 1) % suggestions.length);
    } else if (event.key === "Enter") {
      event.preventDefault();
      // A typed login with no suggestion behind it is still worth sending: the
      // person may have signed in since the search index was read, and if they
      // have not, the server says so in words worth reading.
      const picked = showList ? suggestions[cursor] : undefined;
      void invite(picked ? picked.login : q);
    }
  }

  return (
    <Dialog
      title="People on this track"
      onClose={onClose}
      footer={
        track.role === "member" ? (
          leaving ? (
            <>
              <span className="fine">You lose this track until somebody invites you back.</span>
              <span className="spacer" />
              <button type="button" disabled={busy} onClick={() => setLeaving(false)}>
                Cancel
              </button>
              <button type="button" className="danger" disabled={busy} onClick={() => void leave()}>
                {busy ? "Leaving…" : "Leave"}
              </button>
            </>
          ) : (
            <>
              <button type="button" className="danger" onClick={() => setLeaving(true)}>
                Leave this track
              </button>
              <span className="spacer" />
              <button type="button" onClick={onClose}>
                Done
              </button>
            </>
          )
        ) : (
          <>
            <span className="dimmer">
              {people.length === 1 ? "Only you" : `${people.length} people can reach this track`}
            </span>
            <span className="spacer" />
            <button type="button" onClick={onClose}>
              Done
            </button>
          </>
        )
      }
    >
      <div className="dialog-body">
        {error ? <p className="fine error">{error}</p> : null}

        <div className="people-list">
          {people.map((person, i) => (
            <div key={person.login} className="person-row">
              <Face person={person} />
              <span className="who truncate">
                <strong className="truncate">{person.name ?? person.login}</strong>
                <small className="truncate">@{person.login}</small>
              </span>
              <span className="spacer" />
              {i === 0 ? <span className="chip">owner</span> : null}
              {same(person.login, viewerLogin) ? <span className="chip">you</span> : null}
              {owner && i > 0 ? (
                <button
                  type="button"
                  className="x"
                  disabled={busy}
                  aria-label={`Remove @${person.login}`}
                  title={`Remove @${person.login}`}
                  onClick={() => void drop(person.login)}
                >
                  <X size={14} />
                </button>
              ) : null}
            </div>
          ))}
        </div>

        {owner ? (
          <div className="field" style={{ marginTop: 14 }}>
            <label htmlFor={`${listId}-input`}>Invite somebody by GitHub username</label>
            <div className="row" onKeyDown={onKeyDown}>
              <Search size={14} />
              <input
                id={`${listId}-input`}
                value={q}
                onChange={(e) => {
                  setQ(e.target.value);
                  setListOpen(true);
                }}
                placeholder="username"
                autoComplete="off"
                spellCheck={false}
                disabled={busy}
                role="combobox"
                aria-expanded={showList}
                aria-controls={listId}
                aria-autocomplete="list"
                aria-activedescendant={showList ? `${listId}-${cursor}` : undefined}
              />
            </div>

            <div id={listId} role="listbox" aria-label="People who have signed in here">
              {showList
                ? suggestions.map((person, i) => (
                    <button
                      key={person.login}
                      id={`${listId}-${i}`}
                      type="button"
                      role="option"
                      aria-selected={i === cursor}
                      tabIndex={-1}
                      className={`pick-row${i === cursor ? " on" : ""}`}
                      disabled={busy}
                      onMouseEnter={() => setAt(i)}
                      onClick={() => void invite(person.login)}
                    >
                      <Face person={person} />
                      <span className="truncate">@{person.login}</span>
                      {person.name ? <span className="meta">{person.name}</span> : null}
                    </button>
                  ))
                : null}
            </div>

            {q.trim() && !showList ? (
              <p className="hint">
                Nobody here matches “{q.trim().replace(/^@/, "")}”. Press <kbd>⏎</kbd> to send it anyway — switchyard can
                only invite people who have signed in, and it will say so if they have not.
              </p>
            ) : null}
          </div>
        ) : null}

        {/* The honest version, not the comfortable one. It is the same
            paragraph as the header of `server/people.ts` because the promise
            and the enforcement have to be one sentence apart. */}
        <p className="fine dimmer" style={{ marginTop: owner ? 4 : 14 }}>
          An invitation covers this track only — its transcript, files, diff, terminal and prompt box. It does not
          include the project's other tracks, the machine's settings, or closing the track. But every track on this
          project shares one machine, and the separation between the worktrees is a rule the agent follows rather than a
          boundary the kernel enforces: somebody you invite can ask the agent to read another track's directory, or to
          print the environment, which on a project with environment secrets means those secrets.
        </p>
      </div>
    </Dialog>
  );
}
