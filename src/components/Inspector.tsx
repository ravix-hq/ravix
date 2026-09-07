/**
 * The right-hand panel: the machine's side of the track, in tabs.
 *
 * Files, changes and checks are the three questions you ask about work you did
 * not do yourself — what is there, what moved, and whether it is good. They
 * are tabs rather than three stacked panels because the inspector is thirty
 * per cent of a window and each of them wants all of it.
 *
 * The diff is loaded here rather than inside `Changes`, which is the one piece
 * of structure in this file. The tab strip shows how many files have changed,
 * and a number on an unopened tab is most of the reason to have one — you look
 * at the inspector to find out that something changed, not after you already
 * know. That means the diff has to be fetched by whoever draws the tab, so it
 * is fetched once here and handed down, rather than twice.
 */
import { useState } from "react";
import type { Capabilities, Project, Track } from "../../shared/api";
import { Changes, useDiff } from "./Changes";
import { Checks } from "./Checks";
import { Files } from "./Files";
import { TrackPreview } from "./TrackPreview";

type Tab = "files" | "changes" | "checks" | "previews";

export function Inspector({ track, project, capabilities }: { track: Track; project: Project; capabilities: Capabilities }) {
  const [tab, setTab] = useState<Tab>("files");
  const diff = useDiff(track.id);
  const changed = diff.report?.files.length ?? 0;

  // A fragment rather than a panel element: `.inspector` is the shell's, so
  // that the narrow-window rule which forces the panel open has something to
  // put the class on.
  return (
    <>
      <div className="tabs inspector-tabs">
        <button type="button" className={`tab${tab === "files" ? " on" : ""}`} onClick={() => setTab("files")}>
          All files
        </button>
        <button type="button" className={`tab${tab === "changes" ? " on" : ""}`} onClick={() => setTab("changes")}>
          Changes
          {/* No badge at zero: "Changes 0" is a worse way of saying "Changes". */}
          {changed > 0 ? <span className="count">{changed}</span> : null}
        </button>
        <button type="button" className={`tab${tab === "checks" ? " on" : ""}`} onClick={() => setTab("checks")}>
          Checks
        </button>
        <button type="button" className={`tab${tab === "previews" ? " on" : ""}`} onClick={() => setTab("previews")}>
          Previews
        </button>
      </div>

      <div className="scroll">
        {tab === "files" ? <Files track={track} /> : null}
        {tab === "changes" ? <Changes diff={diff} /> : null}
        {tab === "checks" ? <Checks track={track} project={project} capabilities={capabilities} /> : null}
        {tab === "previews" ? <div className="preview-platforms">
          <section className="preview-platform" aria-label="Web preview">
            <h3>Web</h3>
            {track.status === "closed" ? <p className="fine">Previews are unavailable for closed tracks.</p> : <TrackPreview key={track.id} trackId={track.id} closed={false} />}
          </section>
          {(["iOS", "Android"] as const).map(platform => <section className="preview-platform" aria-label={`${platform} preview`} key={platform}>
            <div className="row"><h3>{platform}</h3><span className="chip">Coming soon</span></div>
            <p className="fine">{platform} previews will be available here.</p>
          </section>)}
        </div> : null}
      </div>
    </>
  );
}
