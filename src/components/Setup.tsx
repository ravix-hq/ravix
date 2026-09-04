/**
 * Setup: the script and the packages that make the disk what it is.
 *
 * Everything else in this app takes effect the moment you save it. This panel
 * does not, and pretending otherwise would be the most expensive small lie in
 * the product — somebody adds `ripgrep`, saves, runs `rg` in the terminal
 * beside this one, and gets `command not found`.
 *
 * The reason is where these two fields live. A setup script and a package list
 * are properties of the *environment*, which Fountain bakes into a disk image
 * when it builds one. A machine that already exists was built from the old
 * image and keeps running from it. So saving here changes what the next build
 * will produce, and the project menu's Rebuild is the thing that asks for one.
 * The line under the heading says exactly that, and there is deliberately no
 * "Apply" button, because there is no apply.
 */
import { useEffect, useState } from "react";
import type { Project, ProjectSettings } from "../../shared/api";
import { api, ApiError } from "../lib/api";
import { X } from "../lib/icons";

/**
 * The two managers this panel edits.
 *
 * Fountain's `packages` is keyed by manager and will store any key you send
 * it, including one that installs nothing because no such manager exists on
 * the image. Rather than offer a free-form key and let people invent
 * `apt-get`, the panel names the two that work and edits only those — but it
 * carries any other key through untouched on save, so a project configured
 * elsewhere does not quietly lose half its packages by being opened here.
 */
const MANAGERS = [
  { key: "apt", label: "apt", placeholder: "ripgrep" },
  { key: "npm", label: "npm (global)", placeholder: "typescript" },
] as const;

export function Setup({ project }: { project: Project }) {
  const [settings, setSettings] = useState<ProjectSettings | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);

  useEffect(() => {
    let live = true;
    setSettings(null);
    setError(null);
    api
      .settings(project.id)
      .then((s) => live && setSettings(s))
      .catch((err: unknown) => live && setError(err instanceof ApiError ? err.message : "Could not load this project's settings."));
    return () => {
      live = false;
    };
  }, [project.id]);

  // Any edit invalidates the "Saved" acknowledgement, so it can never sit
  // there over a textarea that has since changed underneath it.
  function edit(patch: Partial<ProjectSettings>) {
    setSaved(false);
    setSettings((prev) => (prev ? { ...prev, ...patch } : prev));
  }

  function setPackages(manager: string, names: string[]) {
    if (!settings) return;
    const next = { ...settings.packages };
    if (names.length) next[manager] = names;
    else delete next[manager];
    edit({ packages: next });
  }

  async function save() {
    if (!settings) return;
    setSaving(true);
    setError(null);
    try {
      await api.saveSettings(project.id, { setupScript: settings.setupScript, packages: settings.packages });
      setSaved(true);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Could not save.");
    } finally {
      setSaving(false);
    }
  }

  if (error && !settings) return <div className="empty error">{error}</div>;
  if (!settings) return <div className="empty dim">Loading settings…</div>;

  return (
    <div style={{ padding: "12px 14px" }}>
      <p className="fine">
        The setup script and packages are baked in when the disk is built, so they take effect on the next rebuild rather
        than on the machine that is running now. Rebuild is in the project menu.
      </p>

      <div className="field">
        <label htmlFor="setup-script">Setup script</label>
        <textarea
          id="setup-script"
          rows={7}
          spellCheck={false}
          value={settings.setupScript}
          placeholder={"#!/bin/sh\nnpm ci"}
          onChange={(e) => edit({ setupScript: e.target.value })}
        />
        <span className="hint">
          Runs once while the image is being built, from the repository root. It has no network restrictions and no
          secrets that are not already in this project's environment.
        </span>
      </div>

      {MANAGERS.map((manager) => (
        <PackageList
          key={manager.key}
          label={manager.label}
          placeholder={manager.placeholder}
          names={settings.packages[manager.key] ?? []}
          onChange={(names) => setPackages(manager.key, names)}
        />
      ))}

      <div className="row">
        <button type="button" className="primary" onClick={() => void save()} disabled={saving}>
          {saving ? "Saving…" : "Save"}
        </button>
        {saved ? <span className="dim">Saved. It lands on the next rebuild.</span> : null}
        {error ? <span className="error">{error}</span> : null}
      </div>
    </div>
  );
}

/**
 * One manager's packages, as chips you add to and take from.
 *
 * A comma-separated text field would be fewer lines here and worse everywhere
 * else: it makes a typo in the fourth name invisible until a build fails, and
 * it gives no obvious place to put the one-at-a-time removal that people
 * actually want. Chips make the list the thing you are editing.
 */
function PackageList({
  label,
  placeholder,
  names,
  onChange,
}: {
  label: string;
  placeholder: string;
  names: string[];
  onChange: (names: string[]) => void;
}) {
  const [draft, setDraft] = useState("");

  function add() {
    const name = draft.trim();
    if (!name || names.includes(name)) {
      setDraft("");
      return;
    }
    onChange([...names, name]);
    setDraft("");
  }

  return (
    <div className="field">
      <label>{label}</label>
      {names.length ? (
        <div className="row" style={{ flexWrap: "wrap", gap: 6 }}>
          {names.map((name) => (
            <span className="chip" key={name}>
              {name}
              <button type="button" className="x" aria-label={`Remove ${name}`} onClick={() => onChange(names.filter((n) => n !== name))}>
                <X size={11} />
              </button>
            </span>
          ))}
        </div>
      ) : (
        <span className="hint">Nothing yet.</span>
      )}
      <div className="row">
        <input
          value={draft}
          spellCheck={false}
          placeholder={placeholder}
          aria-label={`Add a ${label} package`}
          style={{ flex: 1, minWidth: 0 }}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key !== "Enter") return;
            e.preventDefault();
            add();
          }}
        />
        <button type="button" onClick={add} disabled={!draft.trim()}>
          Add
        </button>
      </div>
    </div>
  );
}
