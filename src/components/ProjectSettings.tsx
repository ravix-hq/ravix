/**
 * A project's settings, which are the machine's settings.
 *
 * Every field here is a mutation in place on records that already exist — the
 * environment, the vault and the agent made when the project was created — and
 * none of it replaces them, because their ids *are* the sandbox's identity and
 * a new id is a new disk. The one control that deliberately breaks that is
 * "Rebuild machine", and it says so before it does it.
 *
 * The panel also has to be honest about *when* a change lands. Fountain hands
 * an agent its system prompt and its secrets at the start of a session, so a
 * setting saved now reaches the next track and not the four already open. A
 * settings sheet that implied otherwise would be believed exactly once.
 */
import { useEffect, useState, type FormEvent } from "react";
import type { Project, ProjectSettings as Settings } from "../../shared/api";
import { api } from "../lib/api";
import { Machine, Wrench, X } from "../lib/icons";
import { ProjectPreviewSettings } from "./TrackPreview";
import { Dialog } from "./Dialog";

export interface ProjectSettingsProps {
  project: Project;
  onClose: () => void;
  /** The project changed underneath the shell: re-read it. */
  onChanged?: () => void;
  /** It is gone. The shell should stop pointing at it. */
  onDeleted?: () => void;
  /**
   * For the one outcome the person cannot read here, because this dialog is
   * closing as it happens: deletion. Everything else reports in the footer,
   * next to the button that caused it.
   */
  onNotify?: (text: string, bad?: boolean) => void;
}

export function ProjectSettings({ project, onClose, onChanged, onDeleted, onNotify }: ProjectSettingsProps) {
  const [settings, setSettings] = useState<Settings | null>(null);
  const [name, setName] = useState(project.name);
  const [instructions, setInstructions] = useState("");
  const [runtime, setRuntime] = useState(project.runtime);
  const [model, setModel] = useState(project.model);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const [secretKey, setSecretKey] = useState("");
  const [secretValue, setSecretValue] = useState("");
  const [secretStore, setSecretStore] = useState<"env" | "vault">("env");

  // Which destructive thing has been asked for but not yet confirmed. Kept as
  // one value because both cannot be pending at once, and a stray `true` on
  // the other is exactly the bug you do not want in this section.
  const [confirming, setConfirming] = useState<"rebuild" | "delete" | null>(null);
  const [typedName, setTypedName] = useState("");

  useEffect(() => {
    let live = true;
    api.settings(project.id).then(
      (data) => {
        if (!live) return;
        setSettings(data);
        setName(data.name);
        setInstructions(data.instructions);
        setModel(data.model);
        setRuntime(data.runtime);
      },
      (err: unknown) => live && setError(err instanceof Error ? err.message : "Could not read these settings."),
    );
    return () => {
      live = false;
    };
  }, [project.id]);

  async function save(): Promise<void> {
    setBusy(true);
    setError(null);
    setNote(null);
    try {
      await api.saveSettings(project.id, { name: name.trim() || project.name, instructions, runtime, model });
      setNote("Saved. Tracks opened from now on will use it.");
      onChanged?.();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not save these settings.");
    } finally {
      setBusy(false);
    }
  }

  async function addSecret(event: FormEvent): Promise<void> {
    event.preventDefault();
    const key = secretKey.trim();
    if (!key || !secretValue) return;
    setBusy(true);
    setError(null);
    setNote(null);
    try {
      await api.saveSettings(project.id, { secret: { store: secretStore, key, value: secretValue } });
      // The value is never read back — the server only ever returns key names
      // — so the list is updated here rather than re-fetched.
      setSettings((s) =>
        s
          ? secretStore === "env"
            ? { ...s, envKeys: [...new Set([...s.envKeys, key])] }
            : { ...s, vaultKeys: [...new Set([...s.vaultKeys, key])] }
          : s,
      );
      setSecretKey("");
      setSecretValue("");
      setNote(`${key} is set. It reaches the machine when the next track opens.`);
      onChanged?.();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not save that secret.");
    } finally {
      setBusy(false);
    }
  }

  async function removeSecret(store: "env" | "vault", key: string): Promise<void> {
    setBusy(true);
    setError(null);
    setNote(null);
    try {
      // An empty value is the delete: the server reads "no value" as "take it
      // away" rather than as "store an empty string".
      await api.saveSettings(project.id, { secret: { store, key, value: "" } });
      setSettings((s) =>
        s
          ? store === "env"
            ? { ...s, envKeys: s.envKeys.filter((k) => k !== key) }
            : { ...s, vaultKeys: s.vaultKeys.filter((k) => k !== key) }
          : s,
      );
      onChanged?.();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not remove that secret.");
    } finally {
      setBusy(false);
    }
  }

  async function rebuild(): Promise<void> {
    setBusy(true);
    setError(null);
    setNote(null);
    try {
      const result = await api.rebuild(project.id);
      setConfirming(null);
      setNote(
        result.failed.length
          ? `The machine was rebuilt, but ${result.failed.length} thing${result.failed.length === 1 ? "" : "s"} could not be cleaned up: ${result.failed.map((f) => `${f.what} (${f.why})`).join(", ")}.`
          : "The machine was rebuilt. Open a track to build the new disk.",
      );
      onChanged?.();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not rebuild the machine.");
    } finally {
      setBusy(false);
    }
  }

  async function destroy(): Promise<void> {
    setBusy(true);
    setError(null);
    try {
      await api.deleteProject(project.id);
      onNotify?.("Project deleted. Its machine, disk and secrets are gone; the repository is untouched.", false);
      onDeleted?.();
    } catch (err) {
      setBusy(false);
      setError(err instanceof Error ? err.message : "Could not delete this project.");
    }
  }

  return (
    <Dialog
      title="Project settings"
      wide
      onClose={onClose}
      footer={
        <>
          <button type="button" className="primary" disabled={busy || !settings || !model} onClick={() => void save()}>
            {busy ? "Saving…" : "Save changes"}
          </button>
          <button type="button" onClick={onClose}>
            Close
          </button>
          <span className="spacer" />
          {error ? <span className="error">{error}</span> : note ? <span className="dimmer">{note}</span> : null}
        </>
      }
    >
      <div className="dialog-body">
        {!settings ? (
          <p className="fine">Reading this project's settings…</p>
        ) : (
          <>
            <div className="field">
              <label htmlFor="sy-name">Name</label>
              <input id="sy-name" value={name} onChange={(e) => setName(e.target.value)} />
              <span className="hint">
                What this project is called here. The repository it clones and the directory it clones into do not change
                with it.
              </span>
            </div>

            <div className="field">
              <label htmlFor="sy-runtime">Harness</label>
              <select id="sy-runtime" value={runtime} disabled={busy || !settings.catalog} onChange={(e) => {
                const next = e.target.value;
                setRuntime(next);
                const models = settings.catalog?.models[next] ?? [];
                setModel(next === settings.runtime ? settings.model : models[0] ?? "");
              }}>
                {!settings.catalog?.runtimes.includes(settings.runtime) && <option value={settings.runtime}>{settings.runtime} (current)</option>}
                {settings.catalog?.runtimes.map((item) => <option key={item} value={item} disabled={!settings.catalog?.models[item]?.length}>{item === "claude" ? "Claude Code" : item === "codex" ? "Codex" : item}</option>)}
              </select>
              <span className="hint">The coding agent used by new tracks. Existing tracks keep their current harness and model. Your machine and worktrees are kept.</span>
            </div>

            <div className="field">
              <label htmlFor="sy-model">Model</label>
              <select id="sy-model" className="mono" value={model} disabled={busy || !settings.catalog} onChange={(e) => setModel(e.target.value)}>
                {runtime === settings.runtime && !settings.catalog?.models[runtime]?.includes(settings.model) && <option value={settings.model}>{settings.model} (current)</option>}
                {!model && <option value="">No models available</option>}
                {settings.catalog?.models[runtime]?.map((item) => <option key={item} value={item}>{item}</option>)}
              </select>
              <span className="hint">{settings.catalog ? "Models available for the selected harness." : "Could not load available harnesses and models. Reopen settings to try again."}</span>
            </div>

            <div className="field">
              <label htmlFor="sy-instructions">Instructions</label>
              <textarea id="sy-instructions" rows={6} value={instructions} onChange={(e) => setInstructions(e.target.value)} />
              <span className="hint">
                Appended to the agent's system prompt, after the rule that keeps each track inside its own worktree — so
                nothing written here can talk a track into working in another track's directory. It is read when a session
                starts, which means it reaches the next track you open and not the ones already running.
              </span>
            </div>

            <ProjectPreviewSettings key={project.id} projectId={project.id} />

            <h4>Secrets</h4>
            <p className="fine">
              Two stores, and the difference is where the value ends up. An <strong>environment</strong> secret is an
              environment variable inside the machine, so anything running there — including the agent, and anything it
              runs — can read it. A <strong>vault</strong> secret never reaches the machine at all: Fountain's egress
              broker holds it and substitutes it into outbound requests in flight, so the box only ever sees a
              placeholder.
            </p>

            <div className="field">
              <label>Environment ({settings.envKeys.length})</label>
              {settings.envKeys.length === 0 ? (
                <span className="hint">None yet.</span>
              ) : (
                settings.envKeys.map((key) => (
                  <div key={key} className="keyline">
                    <span>{key}</span>
                    <span className="spacer" />
                    <button
                      type="button"
                      className="x"
                      aria-label={`Remove environment secret ${key}`}
                      disabled={busy}
                      onClick={() => void removeSecret("env", key)}
                    >
                      <X size={14} />
                    </button>
                  </div>
                ))
              )}
            </div>

            <div className="field">
              <label>Vault ({settings.vaultKeys.length})</label>
              {settings.vaultKeys.length === 0 ? (
                <span className="hint">None yet.</span>
              ) : (
                settings.vaultKeys.map((key) => (
                  <div key={key} className="keyline">
                    <span>{key}</span>
                    <span className="spacer" />
                    <button
                      type="button"
                      className="x"
                      aria-label={`Remove vault secret ${key}`}
                      disabled={busy}
                      onClick={() => void removeSecret("vault", key)}
                    >
                      <X size={14} />
                    </button>
                  </div>
                ))
              )}
            </div>

            <form className="field" onSubmit={(e) => void addSecret(e)}>
              <label htmlFor="sy-secret-key">Add a secret</label>
              <div className="row">
                <input
                  id="sy-secret-key"
                  className="mono"
                  value={secretKey}
                  onChange={(e) => setSecretKey(e.target.value)}
                  placeholder="NPM_TOKEN"
                  aria-label="Secret name"
                />
                <input
                  type="password"
                  value={secretValue}
                  onChange={(e) => setSecretValue(e.target.value)}
                  placeholder="Value"
                  aria-label="Secret value"
                />
                <select
                  value={secretStore}
                  onChange={(e) => setSecretStore(e.target.value === "vault" ? "vault" : "env")}
                  aria-label="Where to keep it"
                >
                  <option value="env">Environment</option>
                  <option value="vault">Vault</option>
                </select>
                <button type="submit" disabled={busy || !secretKey.trim() || !secretValue}>
                  Add
                </button>
              </div>
              <span className="hint">
                A name is letters, digits and underscores. Values are write-only: once saved, this panel can show you the
                name and replace the value, and nothing can read it back out.
              </span>
            </form>

            <h4>Danger</h4>

            <div className="field">
              {confirming === "rebuild" ? (
                <>
                  <p className="fine">
                    Rebuilding retires this project's agent and builds a new one on the same environment and vault. Every
                    packet of work in flight stops: <strong>every track closes, and every uncommitted change in every
                    worktree is gone</strong>, because the disk they live on is the thing being replaced. Your
                    repositories, packages, secrets and instructions are kept.
                  </p>
                  <div className="row">
                    <button type="button" className="danger" disabled={busy} onClick={() => void rebuild()}>
                      {busy ? "Rebuilding…" : "Yes, rebuild the machine"}
                    </button>
                    <button type="button" disabled={busy} onClick={() => setConfirming(null)}>
                      Cancel
                    </button>
                  </div>
                </>
              ) : (
                <div className="row">
                  <button type="button" className="danger" disabled={busy} onClick={() => setConfirming("rebuild")}>
                    <span className="row">
                      <Wrench size={14} /> Rebuild machine
                    </span>
                  </button>
                  <span className="hint">A fresh disk when the machine is wedged. It closes every track.</span>
                </div>
              )}
            </div>

            <div className="field">
              {confirming === "delete" ? (
                <>
                  <p className="fine">
                    Deleting removes the agent, the environment and the vault, and with them the machine, its disk and
                    every secret this project holds. It cannot be undone and it does not touch anything on GitHub. Type{" "}
                    <strong>{project.name}</strong> to confirm.
                  </p>
                  <div className="row">
                    <input
                      value={typedName}
                      onChange={(e) => setTypedName(e.target.value)}
                      placeholder={project.name}
                      aria-label="Type the project name to confirm"
                    />
                    <button
                      type="button"
                      className="danger"
                      disabled={busy || typedName.trim() !== project.name}
                      onClick={() => void destroy()}
                    >
                      {busy ? "Deleting…" : "Delete project"}
                    </button>
                    <button type="button" disabled={busy} onClick={() => { setConfirming(null); setTypedName(""); }}>
                      Cancel
                    </button>
                  </div>
                </>
              ) : (
                <div className="row">
                  <button type="button" className="danger" disabled={busy} onClick={() => setConfirming("delete")}>
                    <span className="row">
                      <Machine size={14} /> Delete project
                    </span>
                  </button>
                  <span className="hint">The machine, its disk and its secrets. The repository is untouched.</span>
                </div>
              )}
            </div>
          </>
        )}
      </div>
    </Dialog>
  );
}
