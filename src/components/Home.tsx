/**
 * The splash, and the sign-in that precedes it.
 *
 * Conductor's home screen is three cards: open a local project, open one from
 * GitHub, or quick-start. Two of those three do not survive the move to a
 * machine in somebody else's cloud, and the honest thing is to say which and
 * why rather than to ship a card that opens a folder picker onto a computer
 * this app cannot see.
 *
 * So the GitHub card is the one that works, and it is the big one. "Open local
 * project" stays visible and disabled with a reason, because a person arriving
 * from Conductor will look for it and finding nothing is worse than finding
 * an explanation. "Quick start" becomes a real thing here — a project with no
 * repository, which is a bare machine you can talk to — rather than a card
 * borrowed from an app with a filesystem.
 */
import type { Project, SessionInfo } from "../../shared/api";
import { Folder, FolderPlus, GitHub, Globe, Machine, Sparkle } from "../lib/icons";
import { Wordmark } from "./Wordmark";
import { ThemePicker } from "./ThemePicker";

export function SignIn({ session }: { session: SessionInfo }) {
  return (
    <div className="centred">
      {/* The rail is not on this screen, so the picker would be unreachable
          until you had signed in — which is the wrong order for the one screen
          somebody looks at for a while before deciding to. */}
      <div className="corner-theme">
        <ThemePicker />
      </div>
      <div className="signin-card">
        <div style={{ color: "var(--ink)", marginBottom: 20 }}>
          <Wordmark unit={5} />
        </div>
        <h1>Parallel tracks on one machine</h1>
        <p className="lede">
          Point switchyard at a repository and it builds you a cloud machine. Every piece of work you start is its own
          git worktree on that machine, with its own agent, its own branch and its own conversation — so four things can
          be in flight without any of them touching another's files.
        </p>

        {session.capabilities.github ? (
          <a className="gh-button" href={session.signInUrl} style={{ textDecoration: "none" }}>
            <button type="button" className="primary gh-button">
              <GitHub size={17} />
              Sign in with GitHub
            </button>
          </a>
        ) : (
          <p className="error">
            This switchyard has no GitHub App configured, so there is no way to sign in. Set <code>GITHUB_APP_ID</code>{" "}
            and the rest of the App's variables on the server.
          </p>
        )}

        <ul className="points">
          <li>
            <span className="ico">
              <GitHub size={14} />
            </span>
            <span>
              Sign-in is a GitHub App, so the machine sees the repositories you pick and nothing else. A personal token
              would have handed it everything you can reach.
            </span>
          </li>
          <li>
            <span className="ico">
              <Machine size={14} />
            </span>
            <span>
              The machine is a persistent sandbox with your repository already cloned. It keeps its disk between visits.
            </span>
          </li>
          <li>
            <span className="ico">
              <Sparkle size={14} />
            </span>
            <span>
              The Fountain account every machine runs on belongs to this deployment, not to you — so there is no key to
              paste, and the turns are on the house.
            </span>
          </li>
        </ul>
      </div>
    </div>
  );
}

export interface HomeProps {
  session: SessionInfo;
  projects: Project[];
  onNewProject: () => void;
  onQuickStart: () => void;
  onPickProject: (id: string) => void;
}

export function Home({ session, projects, onNewProject, onQuickStart, onPickProject }: HomeProps) {
  const installed = session.viewer?.hasInstallation ?? false;
  return (
    <div className="centred">
      <div className="hero">
        <div style={{ color: "var(--ink)" }}>
          <Wordmark />
        </div>
        <p className="hero-sub">
          A project is a machine. A track is a worktree on it. Start as many as you like — they share one disk and take
          it in turns.
        </p>

        <div className="cards">
          <button type="button" className="card" onClick={onNewProject}>
            <span className="ico">
              <Globe size={19} />
            </span>
            <strong>{installed ? "Open GitHub project" : "Connect GitHub"}</strong>
            <small>
              {installed
                ? "Pick a repository switchyard can see and it builds the machine."
                : "Install the app on an account to choose which repositories switchyard may see."}
            </small>
          </button>

          <button type="button" className="card" onClick={onQuickStart}>
            <span className="ico">
              <FolderPlus size={19} />
            </span>
            <strong>Quick start</strong>
            <small>A machine with no repository. Somewhere to try things, or to start something new.</small>
          </button>

          <button
            type="button"
            className="card"
            disabled
            title="Switchyard's machines are in the cloud, so there is no local disk to open."
          >
            <span className="ico">
              <Folder size={19} />
            </span>
            <strong>Open local project</strong>
            <small>
              Not here: the machine is in the cloud, so there is no folder on this computer for it to open. Push the
              repository and open it from GitHub.
            </small>
          </button>
        </div>

        {projects.length ? (
          <div style={{ width: "100%" }}>
            <div className="yard-label" style={{ padding: "0 2px 8px" }}>
              <span>Recent</span>
            </div>
            {projects.slice(0, 8).map((p) => (
              <button key={p.id} type="button" className="pick-row" onClick={() => onPickProject(p.id)}>
                <span className="project-mark" aria-hidden="true">
                  {p.name.slice(0, 1).toUpperCase()}
                </span>
                <span className="truncate">{p.name}</span>
                <span className="meta">
                  <span className="mono">{p.repo ?? "no repository"}</span>
                </span>
              </button>
            ))}
          </div>
        ) : null}
      </div>
    </div>
  );
}
