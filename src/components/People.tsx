/**
 * Who is on a track — or on a whole project — and how somebody else gets here.
 *
 * One dialog, two grains, because they are the same six controls over two
 * different nouns: a list, an invite box, a link, and a way out. Rendering
 * them from one component is not code-golf; it is what keeps the *sentences*
 * in step. The paragraph near the bottom of each has to describe what an
 * invitation actually buys, and the true answer is broader than the tidy one
 * — the worktrees share a machine, and the agent staying in its own directory
 * is a rule rather than a wall. `server/people.ts` holds the same paragraph in
 * its header. Three copies of it would have drifted by the second change.
 *
 * What differs between the two is held in `WIRING` and `WORDS` and nowhere
 * else. A track invitation is one branch; a project invitation is every branch
 * on the box, now and later, plus the ability to cut more. The dialog says
 * which it is doing in the words a person reads rather than only in the route
 * it posts to.
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
import type { InviteLink, Person, Presence, Project, Track } from "../../shared/api";
import { api } from "../lib/api";
import { subject } from "../lib/presence";
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

/**
 * A round avatar, or the first letter of the login when GitHub has no image.
 *
 * `here` rings it. The ring is never the only thing saying so — the button it
 * sits in carries the names in its label and its tooltip — because a coloured
 * outline on a small disc is precisely the signal a reader who cannot separate
 * the accent from the panel colour will miss.
 */
function Face({ person, here = false }: { person: Person; here?: boolean }) {
  const className = `face${here ? " here" : ""}`;
  if (person.avatarUrl) return <img className={className} src={person.avatarUrl} alt="" />;
  return (
    <span className={className} aria-hidden="true">
      {person.login.slice(0, 1).toUpperCase()}
    </span>
  );
}

export interface PeopleStackProps {
  people: Person[];
  onOpen: () => void;
  /** Who has this track open right now. A subset of `people`, and often empty. */
  present?: Presence[];
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
export function PeopleStack({ people, onOpen, present = [], max = 3 }: PeopleStackProps) {
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
  const here = new Set(present.map((p) => p.login.toLowerCase()));
  // Named from the membership rather than from the presence list, so the order
  // is the order of the faces beside it and does not shuffle as people arrive.
  const hereNow = here.size ? `${subject(people.filter((p) => here.has(p.login.toLowerCase())).map((p) => p.login))} here now` : "";
  const membership =
    // Same distinction the footer draws: somebody invited is not somebody
    // who can reach it, and a label that said otherwise would be the one
    // part of this dialog a screen reader got wrong.
    people.filter((p) => !p.pending).length === people.length
      ? `${people.length} people on this track`
      : `${people.filter((p) => !p.pending).length} people on this track, ${people.filter((p) => p.pending).length} invited`;
  return (
    <button
      type="button"
      className="ghost people-stack"
      onClick={onOpen}
      aria-label={hereNow ? `${membership}, ${hereNow}` : membership}
      title={[people.map((p) => `@${p.login}`).join(", "), hereNow].filter(Boolean).join("\n")}
    >
      {shown.map((p) => (
        <Face key={p.login} person={p} here={here.has(p.login.toLowerCase())} />
      ))}
      {rest > 0 ? <span className="face more">+{rest}</span> : null}
    </button>
  );
}

// ── the two grains ─────────────────────────────────────────────────────

type Grain = "track" | "project";

/**
 * The calls each grain makes.
 *
 * Spelt out per grain rather than assembled from a path fragment: these are
 * six named operations on two different things, and a `` `/api/${noun}s/` ``
 * template would make the two look interchangeable at exactly the place where
 * confusing them hands somebody the wrong machine.
 */
const WIRING: Record<Grain, {
  read: (id: string) => Promise<Person[]>;
  add: (id: string, login: string) => Promise<Person[]>;
  drop: (id: string, login: string) => Promise<Person[] | undefined>;
  link: (id: string) => Promise<InviteLink | null>;
  mint: (id: string) => Promise<InviteLink>;
  revoke: (id: string) => Promise<null>;
}> = {
  track: { read: api.people, add: api.invite, drop: api.uninvite, link: api.link, mint: api.mintLink, revoke: api.revokeLink },
  project: {
    read: api.projectPeople,
    add: api.inviteToProject,
    drop: api.uninviteFromProject,
    link: api.projectLink,
    mint: api.mintProjectLink,
    revoke: api.revokeProjectLink,
  },
};

/**
 * Everything a person reads, per grain.
 *
 * Held together in one object so the difference between the two dialogs can be
 * reviewed as prose in one place. The project column is the one that has to
 * work harder: "every track here" is a claim somebody is agreeing to on
 * somebody else's behalf, and "and the ones opened later" is the half of it
 * they would not otherwise expect.
 */
const WORDS: Record<Grain, {
  title: string;
  reach: (n: number) => string;
  leaveButton: string;
  leaveWarning: string;
  /** Under the list. Ten words, spent on what would surprise somebody. */
  cost: string;
  linkGrants: string;
}> = {
  track: {
    title: "People on this track",
    reach: (n) => (n === 1 ? "Only you" : `${n} people can reach this track`),
    leaveButton: "Leave this track",
    leaveWarning: "You lose this track until somebody invites you back.",
    cost: "This track only — but one machine, so secrets are readable.",
    linkGrants: "Whoever opens it joins this track.",
  },
  project: {
    title: "People on this project",
    reach: (n) => (n === 1 ? "Only you" : `${n} people can reach every track on this project`),
    leaveButton: "Leave this project",
    leaveWarning: "You lose every track on this project. Any you were invited to by name, you keep.",
    cost: "Every track here, and the ones opened later. One machine, so secrets are readable.",
    linkGrants: "Whoever opens it joins the whole project — every track, and may open more.",
  },
};

// ── the dialog ─────────────────────────────────────────────────────────

interface PeopleDialogProps {
  grain: Grain;
  /** The track or the project this is about. */
  id: string;
  role: "owner" | "member";
  /**
   * The membership already in hand, when the caller has it.
   *
   * A track arrives with its people attached, so its list is drawn before the
   * read below lands. A project does not, so it passes nothing and the dialog
   * opens on one frame of an empty list rather than on a wrong one.
   */
  seed?: Person[];
  viewerLogin: string;
  onClose: () => void;
  onChanged: (people: Person[]) => void;
  onLeft: () => void;
}

function PeopleDialog({ grain, id, role, seed, viewerLogin, onClose, onChanged, onLeft }: PeopleDialogProps) {
  const wiring = WIRING[grain];
  const words = WORDS[grain];

  const [people, setPeople] = useState<Person[]>(seed ?? []);
  const [q, setQ] = useState("");
  const [found, setFound] = useState<Person[]>([]);
  const [listOpen, setListOpen] = useState(false);
  const [at, setAt] = useState(0);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [leaving, setLeaving] = useState(false);
  const [link, setLink] = useState<InviteLink | null>(null);
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

  const owner = role === "owner";
  const expires = link ? until(link.expiresAt) : null;

  // A track came with its membership attached, so its list is drawn before
  // this lands. Re-reading is for the case where somebody was added from
  // another window since the detail was fetched; a failure here leaves the
  // known-good list in place rather than replacing it with an error about a
  // refresh nobody asked for.
  useEffect(() => {
    let live = true;
    void wiring.read(id).then(
      (rows) => live && setPeople(rows),
      () => undefined,
    );
    return () => {
      live = false;
    };
  }, [wiring, id]);

  // And again whenever the shell re-reads the subject, which it now does on
  // the stream's `people` event. Without this the dialog is a photograph:
  // somebody joining by the link you are looking at does not appear in it,
  // which is the one moment this list is most worth being right.
  //
  // The server's list wins over local state rather than merging with it —
  // every mutation here already replaces `people` wholesale with what the
  // server returned, so there is nothing local to lose.
  useEffect(() => {
    if (seed) setPeople(seed);
  }, [seed]);

  // Whether a link is out. Owner-only because the route is: a member asking
  // gets a 403, and an error banner about a control they cannot see would be
  // the dialog reporting its own bad question.
  useEffect(() => {
    if (!owner) return;
    let live = true;
    void wiring.link(id).then(
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
        setLinkError(err instanceof Error ? err.message : "Could not read the invite link.");
      },
    );
    return () => {
      live = false;
    };
  }, [wiring, id, owner]);

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
      const next = await wiring.add(id, name);
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
      const next = await wiring.drop(id, login);
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
      await wiring.drop(id, viewerLogin);
      onLeft();
    } catch (err) {
      setBusy(false);
      setError(err instanceof Error ? err.message : "Could not leave.");
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
      const made = await wiring.mint(id);
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
      await wiring.revoke(id);
      setLink(null);
      // The URL on screen is dead the moment the server drops the row, and
      // leaving it visible would invite somebody to send a link that no longer
      // admits anyone.
      setMinted(null);
    } catch (err) {
      setLinkError(err instanceof Error ? err.message : "Could not revoke the invite link.");
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

  const here = people.filter((p) => !p.pending).length;
  const waiting = people.length - here;

  return (
    <Dialog
      title={words.title}
      onClose={onClose}
      footer={
        role === "member" ? (
          leaving ? (
            <>
              <span className="fine">{words.leaveWarning}</span>
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
                {words.leaveButton}
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
              {/* Pending people are counted separately, because they cannot
                  reach it — that is the whole difference between the two kinds
                  of row, and a footer that added them together would contradict
                  the "has not signed in here yet" line six inches above it. */}
              {words.reach(here)}
              {waiting > 0 ? `, ${waiting} invited` : ""}
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
              {/* A name on a track that nobody remembers inviting to it is
                  alarming until the row says how it got there. It is also the
                  one row whose × is in another dialog, so saying which is the
                  difference between a missing control and a lost one. */}
              {person.via === "project" ? (
                <span className="chip" title="In this whole project, so in every track on it. Remove them from the project's people.">
                  whole project
                </span>
              ) : null}
              {person.pending ? <span className="chip">invited</span> : null}
              {same(person.login, viewerLogin) ? <span className="chip">you</span> : null}
              {owner && i > 0 && person.via !== "project" ? (
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
            {linkError ? <p className="fine error">{linkError}</p> : null}

            {minted ? (
              <>
                <div className="row">
                  <input
                    ref={mintedField}
                    className="mono"
                    readOnly
                    value={minted}
                    aria-label="The invite link"
                    // Focusing it selects it, so Tab-then-copy works without
                    // the button, and so does the clipboard fallback below.
                    onFocus={(e) => e.currentTarget.select()}
                  />
                  <button type="button" onClick={() => void copyLink()}>
                    {copied ? "Copied" : "Copy"}
                  </button>
                </div>
                <span className="hint">
                  Shown once — copy it now.{expires ? ` Expires ${expires}.` : ""}
                </span>
              </>
            ) : link ? (
              <span className="hint">
                {/* "Cannot be shown again" survives the cut because it is the
                    one thing here nobody would assume. */}
                Made {ago(link.createdAt)}, {expires ? `expires ${expires}` : "expired"}. Cannot be shown again.
              </span>
            ) : (
              // Not "everybody here was invited by name": a link that was
              // revoked leaves the people it let in, so the honest claim is
              // about the way in that is open now, not about how the list got
              // to be what it is.
              <span className="hint">No link is out.</span>
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

            {/* What the link admits somebody to, said before it is minted
                rather than after. The project one is the sentence worth
                reading: it is the widest thing this app hands out, and it is
                two clicks from a button labelled the same as the track's. */}
            <span className="hint">{words.linkGrants}</span>
            {link ? (
              <span className="hint">A new link replaces this one. Revoking keeps whoever already joined.</span>
            ) : null}
          </div>
        ) : null}

        {/* Ten words, and they are spent on the part that would surprise
            somebody rather than the part that reassures them. What an
            invitation *covers* is guessable from the dialog it is in; that the
            worktrees share a machine, and that the separation between them is
            a rule the agent follows rather than a boundary, is not. The long
            version lives in the README and in the header of `server/people.ts`,
            where somebody deciding policy will read it. */}
        <p className="fine dimmer" style={{ marginTop: owner ? 4 : 14 }}>
          {words.cost}
        </p>
      </div>
    </Dialog>
  );
}

// ── the two of them ────────────────────────────────────────────────────

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
  return (
    <PeopleDialog
      grain="track"
      id={track.id}
      role={track.role}
      seed={track.people}
      viewerLogin={viewerLogin}
      onClose={onClose}
      onChanged={onChanged}
      onLeft={onLeft}
    />
  );
}

export interface ProjectPeopleProps {
  project: Project;
  viewerLogin: string;
  onClose: () => void;
  onChanged: (people: Person[]) => void;
  /**
   * The viewer left the project.
   *
   * Not necessarily the end of their access here — a track they were named on
   * individually survives — so the shell re-reads the rail rather than
   * assuming the project has gone from it.
   */
  onLeft: () => void;
}

export function ProjectPeople({ project, viewerLogin, onClose, onChanged, onLeft }: ProjectPeopleProps) {
  return (
    <PeopleDialog
      grain="project"
      id={project.id}
      // Only ever opened for an owner or a project member — somebody here by
      // way of a single track has no membership this dialog could show, and
      // the route behind it 404s them. The shell is what decides not to offer
      // it; this is the same owner/not-owner question every other dialog asks.
      role={project.role}
      viewerLogin={viewerLogin}
      onClose={onClose}
      onChanged={onChanged}
      onLeft={onLeft}
    />
  );
}
