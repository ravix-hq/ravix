/**
 * One track: the ribbon that says what it is, the transcript, and the box you
 * type into.
 *
 * The ribbon is the part worth explaining. Conductor puts four lines at the
 * top of a new thread — what it is a copy of, what it branched from, what it
 * created, and an offer to add a setup script — and they are not decoration.
 * They are the answer to the question somebody actually has when a machine
 * hands them a directory: *where am I, and what is under me?* Switchyard shows
 * the same four, with one difference forced by the architecture: the worktree
 * is cut by a turn on a real machine, so for the first few seconds those lines
 * describe something that is still being made. They say so rather than showing
 * a fact that is not true yet.
 */
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { LogEvent } from "../../shared/fountain-types";
import type { Capabilities, Project, Track, TrackHeader, TurnRecord } from "../../shared/api";
import { api, ApiError, subscribe } from "../lib/api";
import { Branch, Clock, External, Folder, Info, Issue, Pull, Wrench } from "../lib/icons";
import { Composer } from "./Composer";
import { Transcript } from "./Transcript";

export interface TrackViewProps {
  project: Project;
  track: Track;
  header: TrackHeader;
  starters: { label: string; prompt: string }[];
  capabilities: Capabilities;
  onError: (message: string) => void;
  onOpenSettings: () => void;
  /** Called when a turn starts or ends, so the rail's dot agrees with the view. */
  onActivity: () => void;
}

export function TrackView(props: TrackViewProps) {
  const { project, track, header, starters } = props;
  const [events, setEvents] = useState<LogEvent[]>([]);
  const [turns, setTurns] = useState<TurnRecord[]>([]);
  const [running, setRunning] = useState(track.status === "running" || track.status === "opening");
  const seen = useRef(new Set<number>());
  /**
   * Which track the state below belongs to.
   *
   * Every write into `events` and `turns` is made by a closure that captured a
   * track id at the time it was created, and lands some milliseconds later on
   * whatever track is on screen *now*. Those are not the same track the moment
   * somebody clicks a different one in the rail, and the failure is not a
   * flicker — a late `setTurns` writes another track's prompts into this one's
   * transcript and they stay there, which reads as the agent having said
   * things it never said.
   */
  const showing = useRef(track.id);
  showing.current = track.id;

  // The transcript so far, then the live stream. Both feed one list,
  // de-duplicated by event id — the stream replays what the fetch already
  // returned when a connection is resumed, and a duplicated tool chip is very
  // visible.
  useEffect(() => {
    let alive = true;
    seen.current = new Set();
    setEvents([]);
    setTurns([]);
    void api
      .events(track.id)
      .then((page) => {
        if (!alive || showing.current !== track.id) return;
        for (const e of page.events as LogEvent[]) seen.current.add(e.id);
        setEvents(page.events as LogEvent[]);
        setTurns(page.turns);
      })
      .catch((err: unknown) => {
        if (alive && err instanceof ApiError) props.onError(err.message);
      });
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [track.id]);

  useEffect(() => {
    // Fountain names each frame after the event's `kind`, so the two names
    // here are the whole vocabulary: `output` is a byte the machine produced,
    // `stage` is a change of state. `message` is kept as a fallback for a
    // Fountain that emits an unnamed frame — it costs one line and its absence
    // would be a transcript that silently never updates.
    const stop = subscribe(`/api/tracks/${track.id}/stream`, {
      output: (data) => absorb(data),
      stage: (data) => absorb(data),
      message: (data) => absorb(data),
    });
    const forTrack = track.id;
    function absorb(data: unknown): void {
      // A frame that arrives from the stream of a track we have navigated away
      // from — the socket is closed on cleanup, but a frame already in flight
      // still lands here — must not be appended to the transcript now on
      // screen.
      if (showing.current !== forTrack) return;
      const ev = data as LogEvent | null;
      if (!ev || typeof ev !== "object") return;
      if (typeof ev.id === "number") {
        if (seen.current.has(ev.id)) return;
        seen.current.add(ev.id);
      }
      setEvents((current) => [...current, ev]);

      // `stage: "turn"` is how Fountain says a turn began or ended. Anything
      // else with a stage — `server`, a runtime's own phases — is not a turn
      // boundary and must not move the indicator.
      if (ev.kind === "stage" && ev.stage === "turn") {
        if (ev.state === "started") {
          setRunning(true);
        } else {
          setRunning(false);
          // The turn is over, so its prompt is now recorded and the track's
          // status has moved. Re-read both rather than guessing at them.
          props.onActivity();
          const forTrack = track.id;
          void api
            .events(forTrack)
            .then((page) => {
              // The unguarded version of this line is how another track's
              // transcript ends up under this one's header.
              if (showing.current === forTrack) setTurns(page.turns);
            })
            .catch(() => undefined);
        }
      }
    }
    return stop;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [track.id]);

  const send = useCallback(
    async (text: string) => {
      setRunning(true);
      try {
        await api.prompt(track.id, text);
        props.onActivity();
      } catch (err) {
        setRunning(false);
        if (err instanceof ApiError) props.onError(err.message);
        throw err;
      }
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [track.id],
  );

  const interrupt = useCallback(() => {
    void api.interrupt(track.id).catch((err: unknown) => {
      if (err instanceof ApiError) props.onError(err.message);
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [track.id]);

  const empty = events.length === 0;

  return (
    <div className="centre">
      <Transcript
        trackId={track.id}
        turns={turns}
        events={events}
        people={track.people}
        runtime={project.runtime}
        running={running}
        head={
          <Ribbon
            project={project}
            track={track}
            header={header}
            onOpenSettings={props.onOpenSettings}
            onRetry={() => {
              void api.retry(track.id).catch((err: unknown) => {
                if (err instanceof ApiError) props.onError(err.message);
              });
            }}
          />
        }
      />

      {empty && !running ? (
        <div className="starters">
          {starters.map((s) => (
            <button key={s.label} type="button" className="starter" onClick={() => void send(s.prompt)}>
              {s.label}
            </button>
          ))}
        </div>
      ) : null}

      <Composer
        onSend={send}
        onInterrupt={interrupt}
        running={running}
        model={project.model}
        placeholder={
          track.status === "opening"
            ? "The worktree is still being cut — anything you send now runs straight after"
            : "Ask for a change, or a question about this branch"
        }
      />
    </div>
  );
}

/** The four lines at the top of a track. */
function Ribbon({
  project,
  track,
  header,
  onOpenSettings,
  onRetry,
}: {
  project: Project;
  track: Track;
  header: TrackHeader;
  onOpenSettings: () => void;
  onRetry: () => void;
}) {
  const opening = track.status === "opening";
  const failed = track.status === "failed";
  const originIcon = useMemo(() => {
    if (track.origin.kind === "pr") return <Pull size={14} />;
    if (track.origin.kind === "issue") return <Issue size={14} />;
    return <Branch size={14} />;
  }, [track.origin.kind]);

  return (
    <div className="ribbon">
      <div className="ribbon-lede">
        {header.copyOf ? (
          <>
            You are in a copy of <code>{header.copyOf}</code> called <code>{track.slug}</code>
          </>
        ) : (
          <>
            You are on a bare machine, in <code>{track.slug}</code>
          </>
        )}
      </div>

      {header.branchedFrom ? (
        <div className={`ribbon-line${opening ? " pending" : ""}`}>
          <span className="ico">{originIcon}</span>
          <span>
            {/* A pull request track checks out the branch the PR is already
                for, so there is no "from" — saying "branched X from origin/X"
                is both redundant and wrong about what happened. An issue track
                does cut a branch, and says which issue it is for. */}
            {track.origin.kind === "pr" && track.origin.number ? (
              <>
                {opening ? "Checking out" : "On"} <code>{header.branchedFrom.branch}</code>, the head of pull request #
                {track.origin.number}
              </>
            ) : (
              <>
                {opening ? "Branching" : "Branched"} <code>{header.branchedFrom.branch}</code>
                {header.branchedFrom.base && header.branchedFrom.base !== header.branchedFrom.branch ? (
                  <>
                    {" "}
                    from <code>origin/{header.branchedFrom.base}</code>
                  </>
                ) : null}
                {track.origin.kind === "issue" && track.origin.number ? <> for issue #{track.origin.number}</> : null}
              </>
            )}
          </span>
          {track.origin.url ? (
            <a href={track.origin.url} target="_blank" rel="noreferrer" title="Open on GitHub" aria-label="Open on GitHub">
              <External size={12} />
            </a>
          ) : null}
        </div>
      ) : null}

      <div className={`ribbon-line${opening ? " pending" : ""}`}>
        <span className="ico">
          <Folder size={14} />
        </span>
        <span>
          {opening ? "Creating" : "Created"} <code>{track.workdir}</code>
        </span>
      </div>

      {failed ? (
        <div className="ribbon-line">
          <span className="ico">
            <Info size={14} />
          </span>
          <span className="error">The opening turn did not land, so this track may have no worktree yet.</span>
          <button type="button" className="linkish" onClick={onRetry}>
            Try again
          </button>
        </div>
      ) : null}

      {opening ? (
        <div className="ribbon-line pending">
          <span className="ico">
            <Clock size={14} />
          </span>
          <span>
            The machine is cutting it now — this is a turn, and you are watching it below. The box may be waking, which
            takes a moment the first time.
          </span>
        </div>
      ) : null}

      {!header.hasSetupScript && project.repo ? (
        <div className="ribbon-line">
          <span className="ico">
            <Wrench size={14} />
          </span>
          <button type="button" className="linkish" onClick={onOpenSettings}>
            Optional: add a setup script
          </button>
          <span className="dimmer">— it runs when the disk is built</span>
        </div>
      ) : null}
    </div>
  );
}
