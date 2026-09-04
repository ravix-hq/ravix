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
 *
 * There are two doors, and they are drawn as two because they cost different
 * things. Naming somebody grants one named person access, and the row appears
 * whether or not they have ever been here. A link grants access to whoever
 * holds it — still not anonymously, since opening it requires signing in with
 * GitHub — and that is a weaker, wider thing, so it sits below the list under
 * a rule of its own rather than beside the invite box as an equal option.
 */
import { useEffect, useId, useMemo, useRef, useState, type KeyboardEvent as ReactKeyboardEvent } from "react";
import type { Person, Track, TrackLink } from "../../shared/api";
import { api } from "../lib/api";
import { AddPerson, Search, X } from "../lib/icons";
import { Dialog, ago } from "./Dialog";

const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

/**
 * The forward half of `ago`, which lives in `Dialog.tsx` beside the pickers.
 *
 * Not a flag on that function, because the two disagree about the past rather
 * than mirroring it: an expiry that has already passed is not "in -1 days", it
 * is over, and the sentence the caller wants is a different sentence. Null is
 * how that is said here. A week is the longest a link lasts, so days is the
 * largest unit worth having.
 */
function until(iso: string): string | null {
  const then = Date.parse(iso);
  if (Number.isNaN(then)) return null;
  const minutes = Math.round((then - Date.now()) / 60_000);
  if (minutes < 1) return null;
  if (minutes < 60) return ahead(minutes, "minute");
  const hours = Math.round(minutes / 60);
  if (hours < 24) return ahead(hours, "hour");
  return ahead(Math.round(hours / 24), "day");
}

const ahead = (n: number, unit: string) => `in ${n} ${unit}${n === 1 ? "" : "s"}`;

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
  // A track nobody has been invited to still needs a way in, and this is the
  // only one there is — a stack of one face is not a control anybody would
  // think to press, so a solo track gets a word instead. Hiding it until a
  // track was already shared made sharing impossible to start, which is the
  // kind of bug that only shows up when somebody looks for the button.
  if (people.length < 2) {
    return (
      <button type="button" className="ghost" onClick={onOpen} title="Invite somebody to this track">
        <AddPerson size={13} /> Share
      </button>
    );
  }
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
  /**
   * The viewer removed *themselves*.
   *
   * Distinct from `onChanged` because there is nothing to hand back: the
   * server answers 204, and the caller's next read of this track is a 404. The
   * shell has to leave rather than re-render — which is the one thing this
   * component cannot do for it.
   */
  onLeft: () => void;
}

export function People({ track, viewerLogin, onClose, onChanged, onLeft }: PeopleProps) {
  const [people, setPeople] = useState<Person[]>(track.people);
  const [q, setQ] = useState("");
  const [found, setFound] = useState<Person[]>([]);
  const [listOpen, setListOpen] = useState(false);
  const [at, setAt] = useState(0);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [leaving, setLeaving] = useState(false);
  const [link, setLink] = useState<TrackLink | null>(null);
  // Distinct from `link === null`, which is the answer "no link is out". Until
  // the read lands there is no answer at all, and drawing "no link is out" for
  // a track that has one would be a lie the next frame corrects.
  const [linkKnown, setLinkKnown] = useState(false);
  const [minted, setMinted] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [linkBusy, setLinkBusy] = useState(false);
  const [linkError, setLinkError] = useState<string | null>(null);
  const mintedField = useRef<HTMLInputElement>(null);
  const listId = useId();

  const owner = track.role === "owner";
  const expires = link ? until(link.expiresAt) : null;

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

  // Whether a link is out. Owner-only because the route is: a member asking
  // gets a 403, and an error banner about a control they cannot see would be
  // the dialog reporting its own bad question.
  useEffect(() => {
    if (!owner) return;
    let live = true;
    void api.link(track.id).then(
      (row) => {
        if (!live) return;
        setLink(row);
        setLinkKnown(true);
      },
      (err) => {
        if (!live) return;
        // Still `known`: the section renders with the failure in it rather
        // than vanishing, because a missing section reads as "this deployment
        // has no links" and the truth is that one read did not come back.
        setLinkKnown(true);
        setLinkError(err instanceof Error ? err.message : "Could not read this track's invite link.");
      },
    );
    return () => {
      live = false;
    };
  }, [track.id, owner]);

  // "Copied" is a claim with a shelf life: left up, it stops meaning the last
  // press and starts meaning the button's name.
  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => setCopied(false), 2000);
    return () => clearTimeout(timer);
  }, [copied]);

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
      // Including the 404, which now means the account does not exist on
      // GitHub at all rather than merely not here. The server checked with
      // GitHub to say that, and its sentence is better than a guess made on
      // this side before the call.
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
      onLeft();
    } catch (err) {
      setBusy(false);
      setError(err instanceof Error ? err.message : "Could not leave this track.");
    }
  }

  /**
   * Mint a link, replacing whatever was out.
   *
   * The URL goes into `minted` and deliberately not into `link`: `link` is
   * this component's copy of what the *server* holds, which is a hash and two
   * timestamps. Keeping them apart is what makes "shown once" true rather than
   * merely worded that way — nothing later in this dialog can read the URL
   * back out of the state that survives a re-read.
   */
  async function makeLink(): Promise<void> {
    if (linkBusy) return;
    setLinkBusy(true);
    setLinkError(null);
    try {
      const made = await api.mintLink(track.id);
      setLink({ url: null, createdAt: made.createdAt, expiresAt: made.expiresAt });
      setMinted(made.url);
      setCopied(false);
    } catch (err) {
      setLinkError(err instanceof Error ? err.message : "Could not make an invite link.");
    } finally {
      setLinkBusy(false);
    }
  }

  async function revokeLink(): Promise<void> {
    if (linkBusy) return;
    setLinkBusy(true);
    setLinkError(null);
    try {
      await api.revokeLink(track.id);
      setLink(null);
      // The URL on screen is dead the moment the server drops the row, and
      // leaving it visible would invite somebody to send a link that no longer
      // admits anyone.
      setMinted(null);
    } catch (err) {
      setLinkError(err instanceof Error ? err.message : "Could not revoke this track's invite link.");
    } finally {
      setLinkBusy(false);
    }
  }

  async function copyLink(): Promise<void> {
    const url = minted;
    if (!url) return;
    try {
      await navigator.clipboard.writeText(url);
      setCopied(true);
    } catch {
      // No clipboard over plain HTTP, and a rejection when the document is not
      // focused. Both end the same way: the URL is still on screen, so
      // selecting it leaves one keystroke between here and having it.
      const field = mintedField.current;
      if (!field) return;
      field.focus();
      field.select();
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
          {/* A pending row is a promise rather than a person: the invitation is
              held against their GitHub account and nothing is readable until
              they sign in. So it is dimmed and chipped instead of being hidden
              — the owner needs to see that the name they typed took, and needs
              to be able to take it back — but it must not read as somebody who
              is already in the room. The second line says what that means in
              words, since dimming alone is a convention, not a sentence. */}
          {people.map((person, i) => (
            <div key={person.login} className={person.pending ? "person-row pending" : "person-row"}>
              <Face person={person} />
              <span className="who truncate">
                {/* A pending entry has no display name — GitHub's is not worth
                    holding for somebody who may never arrive — so the handle
                    moves up into the strong line and takes the `@` with it,
                    rather than leaving a bare login where a name goes. */}
                <strong className="truncate">{person.pending ? `@${person.login}` : (person.name ?? person.login)}</strong>
                <small className="truncate">{person.pending ? "has not signed in here yet" : `@${person.login}`}</small>
              </span>
              <span className="spacer" />
              {i === 0 ? <span className="chip">owner</span> : null}
              {person.pending ? <span className="chip">invited</span> : null}
              {same(person.login, viewerLogin) ? <span className="chip">you</span> : null}
              {owner && i > 0 ? (
                // One button and one call for both kinds of row. The server
                // decides which it is — cancelling an invitation that was
                // never taken up, or removing a member — and it is the same
                // withdrawal either way, so the only difference here is the
                // word a screen reader hears.
                <button
                  type="button"
                  className="x"
                  disabled={busy}
                  aria-label={person.pending ? `Cancel the invitation to @${person.login}` : `Remove @${person.login}`}
                  title={person.pending ? `Cancel the invitation to @${person.login}` : `Remove @${person.login}`}
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
            <label htmlFor={`${listId}-input`}>Invite anybody by their GitHub username</label>
            <div className="row" onKeyDown={onKeyDown}>
              <Search size={14} />
              <input
                id={`${listId}-input`}
                value={q}
                onChange={(e) => {
                  setQ(e.target.value);
                  setListOpen(true);
                }}
                placeholder="any GitHub username"
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

            {/* The suggestions are people who have signed in here, and that is
                now a much smaller set than the people who can be invited — so
                an empty list is not a refusal, and the hint has to stop the
                owner reading it as one. */}
            {q.trim() && !showList ? (
              <p className="hint">
                Nobody who has signed in here matches “{q.trim().replace(/^@/, "")}”, which does not stop you. Press{" "}
                <kbd>⏎</kbd> to invite that GitHub username anyway: the invitation waits until they sign in. If no such
                account exists on GitHub, switchyard says so instead.
              </p>
            ) : null}
          </div>
        ) : null}

        {/* The other door. Gated on the read having landed rather than on
            having found something, so the controls never contradict the
            server for a frame. */}
        {owner && linkKnown ? (
          <div className="field link-box">
            <h4>Invite link</h4>
            <p className="fine">
              Anybody who opens the link and signs in with GitHub joins this track. It is not an anonymous door: signing
              in is the price of walking through it, so the transcript still says who asked for what.
            </p>

            {linkError ? <p className="fine error">{linkError}</p> : null}

            {minted ? (
              <>
                <div className="row">
                  <input
                    ref={mintedField}
                    className="mono"
                    readOnly
                    value={minted}
                    aria-label="The invite link for this track"
                    // Focusing it selects it, so Tab-then-copy works without
                    // the button, and so does the clipboard fallback below.
                    onFocus={(e) => e.currentTarget.select()}
                  />
                  <button type="button" onClick={() => void copyLink()}>
                    {copied ? "Copied" : "Copy"}
                  </button>
                </div>
                <span className="hint">
                  This is the only time the link is shown. Switchyard keeps a hash of it and nothing else, so if you
                  leave without copying it the only way back is a new link.
                  {expires ? ` It expires ${expires}.` : ""}
                </span>
              </>
            ) : link ? (
              <span className="hint">
                A link is out — made {ago(link.createdAt)}
                {expires ? `, and it expires ${expires}` : ", and it has expired"}. It cannot be shown again: only its
                hash is stored here, so switchyard does not have the link to show you.
              </span>
            ) : (
              // Not "everybody here was invited by name": a link that was
              // revoked leaves the people it let in, so the honest claim is
              // about the way in that is open now, not about how the list got
              // to be what it is.
              <span className="hint">No link is out. The only way onto this track right now is being invited by name.</span>
            )}

            <div className="row">
              <button type="button" disabled={linkBusy} onClick={() => void makeLink()}>
                {link ? "Make a new link" : "Make a link"}
              </button>
              {link ? (
                <button type="button" className="danger" disabled={linkBusy} onClick={() => void revokeLink()}>
                  Revoke
                </button>
              ) : null}
            </div>

            {link ? (
              <span className="hint">
                There is one link per track, so making a new one replaces this one and therefore revokes it. Revoking
                stops anybody new getting in on it. It does not remove the people who already joined that way — they
                are in the list above, and you take them out by name.
              </span>
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
