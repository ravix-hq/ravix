import { GitHub, Machine } from "../lib/icons";
import { Wordmark } from "./Wordmark";
import { ThemePicker } from "./ThemePicker";

/** Public product overview. Authentication starts only after choosing to sign in. */
export function Landing() {
  return (
    <div className="landing">
      <header className="landing-nav">
        <a href="/" aria-label="Ravix home">
          <Wordmark unit={4} />
        </a>
        <nav aria-label="Main navigation">
          <a href="#how-it-works">How it works</a>
          <ThemePicker />
          <a className="landing-button landing-primary" href="/login">
            Sign in
          </a>
        </nav>
      </header>
      <main>
        <section className="landing-hero" aria-labelledby="landing-title">
          <div>
            <h1 id="landing-title">
              One project.
              <br />
              Many tracks.
            </h1>
            <p className="landing-intro">
              Ravix is a browser workspace for building software with coding agents. Give a feature, a bug fix and your
              next idea their own branches on one persistent cloud machine, and the work keeps going after you close the
              lid.
            </p>
            <div className="landing-actions">
              <a className="landing-button landing-primary" href="/login">
                Sign in with GitHub
              </a>
              <a href="#how-it-works">How it works</a>
            </div>
            <p className="landing-note">No local setup. No API key to bring. Inference is included.</p>
          </div>
          <div className="landing-example" aria-label="Example project with three separate tracks">
            <div className="landing-example-head">
              <span className="project-mark" aria-hidden="true">
                Y
              </span>
              <strong>your-project</strong>
              <span className="chip mono">owner/repo</span>
            </div>
            <div className="landing-tracks">
              <div className="landing-track">
                <span className="dot running" aria-hidden="true" />
                <div>
                  <strong>Build the next feature</strong>
                  <code>feature/dashboard</code>
                </div>
                <span className="landing-tag">Working</span>
              </div>
              <div className="landing-track">
                <span className="dot" aria-hidden="true" />
                <div>
                  <strong>Fix a stubborn bug</strong>
                  <code>fix/sign-in</code>
                </div>
                <span className="landing-tag">Queued</span>
              </div>
              <div className="landing-track">
                <span className="dot ready" aria-hidden="true" />
                <div>
                  <strong>Try something new</strong>
                  <code>explore/new-idea</code>
                </div>
                <span className="landing-tag">Ready</span>
              </div>
            </div>
            <div className="landing-example-foot">
              Each track is its own worktree, branch, and conversation — on one machine.
            </div>
          </div>
        </section>
        <section className="landing-workflow" id="how-it-works" aria-labelledby="workflow-title">
          <h2 id="workflow-title">From a repository to a review</h2>
          <div className="landing-steps">
            <article>
              <h3>Connect the repository</h3>
              <p>Sign in with GitHub and choose a repository. Ravix prepares a cloud machine with your code already cloned.</p>
            </article>
            <article>
              <h3>Open a track</h3>
              <p>Tell an agent what you want to change. Each track gets its own branch, files and conversation, so separate tasks stay separate.</p>
            </article>
            <article>
              <h3>Read what changed</h3>
              <p>Read the diff, check the files, and ask for a live preview. Iterate, then open a pull request when you are ready.</p>
            </article>
          </div>
        </section>
        <section className="landing-details" aria-label="About your workspace">
          <article>
            <Machine size={18} />
            <div>
              <h3>A machine you can leave running</h3>
              <p>The disk persists between visits. Tracks share its resources, agents take turns on it, and nothing is left running on your laptop.</p>
            </div>
          </article>
          <article>
            <GitHub size={18} />
            <div>
              <h3>Only the repositories you pick</h3>
              <p>Connect through the GitHub App and select which repositories Ravix can access. No personal access token to paste.</p>
            </div>
          </article>
        </section>
        <section className="landing-close">
          <div>
            <h2>Give the next idea a track</h2>
            <p>Start with a repository. Send a teammate a link, and they review the plan, not the pull request.</p>
          </div>
          <a className="landing-button landing-primary" href="/login">
            Sign in with GitHub
          </a>
        </section>
      </main>
      <footer className="landing-footer">
        <span>Ravix</span>
        <span>Parallel tracks on one cloud machine</span>
      </footer>
    </div>
  );
}
