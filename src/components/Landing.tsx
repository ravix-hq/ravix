import { GitHub, Machine } from "../lib/icons";
import { Wordmark } from "./Wordmark";
import { ThemePicker } from "./ThemePicker";

/** Public product overview. Authentication starts only after choosing to sign in. */
export function Landing() {
  return (
    <div className="landing">
      <header className="landing-nav">
        <a href="/" aria-label="Switchyard home"><Wordmark unit={3} /></a>
        <nav aria-label="Main navigation">
          <a href="#how-it-works">How it works</a>
          <ThemePicker />
          <a className="landing-button" href="/login">Sign in <span aria-hidden="true">↗</span></a>
        </nav>
      </header>
      <main>
        <section className="landing-hero" aria-labelledby="landing-title">
          <div>
            <p className="landing-eyebrow">Your code. A cloud machine. Room to work.</p>
            <h1 id="landing-title">One project.<br />Many tracks.</h1>
            <p className="landing-intro">A browser workspace for building software with AI coding agents. Keep a feature, a bug fix, and your next idea moving in their own branches, all on one persistent cloud machine.</p>
            <div className="landing-actions">
              <a className="landing-button landing-primary" href="/login">Get started <span aria-hidden="true">→</span></a>
              <a href="#how-it-works">See how it works <span aria-hidden="true">↓</span></a>
            </div>
            <p className="landing-note">Sign in with GitHub. No local setup or AI API key required.</p>
          </div>
          <div className="landing-example" aria-label="Example project with three separate tracks">
            <div className="landing-example-head"><Machine size={18} /><strong>your-project</strong><span>cloud workspace</span></div>
            <div className="landing-tracks">
              <div className="landing-track"><span className="landing-track-number">01</span><div><strong>Build the next feature</strong><code>feature/dashboard</code></div><span className="landing-tag">Working</span></div>
              <div className="landing-track"><span className="landing-track-number">02</span><div><strong>Fix a stubborn bug</strong><code>fix/sign-in</code></div><span className="landing-tag">Queued</span></div>
              <div className="landing-track"><span className="landing-track-number">03</span><div><strong>Try something new</strong><code>explore/new-idea</code></div><span className="landing-tag">Ready to review</span></div>
            </div>
            <div className="landing-example-foot"><span>Each track has its own</span><strong>Branch · Files · Agent conversation</strong></div>
          </div>
        </section>
        <section className="landing-workflow" id="how-it-works" aria-labelledby="workflow-title">
          <p className="landing-eyebrow">From repository to review</p>
          <h2 id="workflow-title">Less setup. More making.</h2>
          <div className="landing-steps">
            <article><span>01 / CONNECT</span><h3>Bring your repository</h3><p>Sign in with GitHub and choose a repository. Switchyard prepares a cloud machine with your code already cloned.</p></article>
            <article><span>02 / BUILD</span><h3>Give each task a track</h3><p>Tell an agent what you want to change. Each track gets its own branch, working files, and conversation, so separate tasks stay separate.</p></article>
            <article><span>03 / REVIEW</span><h3>See what changed</h3><p>Read the diff, check the files, and ask for a live preview. Iterate with your agent, then open a pull request when you’re ready.</p></article>
          </div>
        </section>
        <section className="landing-details" aria-label="About your workspace">
          <article><Machine size={22} /><div><h3>A workspace you can return to</h3><p>Your machine keeps its disk between visits. Tracks share its resources and agents take turns working on it.</p></div></article>
          <article><GitHub size={22} /><div><h3>You choose the repositories</h3><p>Connect through the GitHub App and select which repositories Switchyard can access. No personal access token to paste.</p></div></article>
        </section>
        <section className="landing-close"><div><h2>Give your next idea a track.</h2><p>Start with a repository. Take it from there.</p></div><a className="landing-button landing-primary" href="/login">Get started <span aria-hidden="true">→</span></a></section>
      </main>
      <footer className="landing-footer"><span>Switchyard</span><span>Parallel tracks on one cloud machine.</span></footer>
    </div>
  );
}
