import { useEffect, useState } from "react";
import type { PreviewConfig, PreviewInfo } from "../../shared/previews";
import { api } from "../lib/api";
import { Dialog } from "./Dialog";

const empty: PreviewConfig = { directory: ".", command: "", readinessPath: "/" };
export function PreviewFields({ value, onChange, disabled }: { value: PreviewConfig; onChange: (v: PreviewConfig) => void; disabled?: boolean }) {
  return <fieldset className="preview-fields" disabled={disabled}>
    <label>App directory<input value={value.directory} placeholder="apps/my-app" onChange={e => onChange({ ...value, directory: e.target.value })} /></label>
    <label>Startup command<textarea rows={2} value={value.command} placeholder={'npm run dev -- --host 127.0.0.1 --port "$PORT" --strictPort'} spellCheck={false} onChange={e => onChange({ ...value, command: e.target.value })} /></label>
    <label>Readiness path<input value={value.readinessPath} placeholder="/health" onChange={e => onChange({ ...value, readinessPath: e.target.value })} /></label>
    <p className="fine">The directory is relative to this track’s worktree. The command must use <code>$PORT</code> and fail if that port is occupied.</p>
  </fieldset>;
}

export function TrackPreview({ trackId, closed }: { trackId: string; closed: boolean }) {
  const [info, setInfo] = useState<PreviewInfo | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [editing, setEditing] = useState(false);
  const [logs, setLogs] = useState(false);
  const [draft, setDraft] = useState(empty);
  const [openUrl, setOpenUrl] = useState<string | null>(null);
  useEffect(() => {
    if (closed) return;
    let alive = true, pending = false;
    async function poll() {
      if (pending || document.visibilityState === "hidden") return;
      pending = true;
      try { const data = await api.preview(trackId); if (alive) setInfo(data); }
      catch (err) { if (alive) setError(err instanceof Error ? err.message : "Could not read preview state."); }
      finally { pending = false; }
    }
    void poll(); const timer = setInterval(() => void poll(), 2000);
    return () => { alive = false; clearInterval(timer); };
  }, [trackId, closed]);
  async function action(action: "open" | "restart" | "stop" | "logs") {
    // Create the tab within the click event, before waiting for the server.
    const tab = action === "open" ? window.open("about:blank", "_blank") : null;
    if (tab) tab.opener = null;
    setBusy(true); setError(null); setOpenUrl(null);
    try {
      const result = await api.previewAction(trackId, action); setInfo(result);
      if (action === "open" && result.openUrl) {
        if (tab) tab.location.href = result.openUrl;
        else setOpenUrl(result.openUrl);
      }
      if (action === "logs") setLogs(true);
    } catch (err) { tab?.close(); setError(err instanceof Error ? err.message : "Preview operation failed."); }
    finally { setBusy(false); }
  }
  async function save(config: PreviewConfig | null) {
    setBusy(true); setError(null);
    try { setInfo(await api.savePreview(trackId, config)); setEditing(false); }
    catch (err) { setError(err instanceof Error ? err.message : "Could not save preview settings."); }
    finally { setBusy(false); }
  }
  if (closed) return null;
  return <section className="track-preview" aria-label="Track preview">
    <div className="preview-controls">
      <button type="button" className="primary" disabled={busy || !info?.available || !info.config} onClick={() => void action("open")}>Open preview</button>
      <span className={`preview-state ${info?.state ?? "stopped"}`} role="status">{!info ? "Loading…" : !info.available ? "Unavailable" : ({ stopped: "Stopped", starting: "Starting", ready: "Ready", failed: "Failed" })[info.state]}</span>
      <button type="button" disabled={busy || !info?.config} onClick={() => void action("restart")}>Restart</button>
      <button type="button" disabled={busy || !info?.available || info.state === "stopped"} onClick={() => void action("stop")}>Stop</button>
      <button type="button" disabled={busy || !info} onClick={() => void action("logs")}>Logs</button>
      <button type="button" disabled={busy || !info} onClick={() => { setDraft(info?.config ?? empty); setEditing(true); }}>Configure</button>
    </div>
    <p className="fine">{info && !info.available ? info.unavailableReason : "Live working copy · agent edits can change the app while you view it."}</p>
    {info?.available && !info.config ? <p className="fine">Configure this track’s startup command, or set a default in project settings.</p> : null}
    {error || info?.error ? <p className="error" role="alert">{error || info?.error}</p> : null}
    {openUrl ? <a href={openUrl} target="_blank" rel="noreferrer">Continue to preview</a> : null}
    {editing ? <Dialog title="Track preview settings" onClose={() => setEditing(false)} footer={<>
      <button type="button" className="primary" disabled={busy || !draft.command.trim()} onClick={() => void save(draft)}>Save override</button>
      <button type="button" disabled={busy} onClick={() => void save(null)}>Use project default</button>
    </>}><div className="dialog-body"><PreviewFields value={draft} onChange={setDraft} disabled={busy} /><p className="fine">Saving stops this preview. Open it again to use the new configuration.</p>{error ? <p className="error" role="alert">{error}</p> : null}</div></Dialog> : null}
    {logs ? <Dialog title="Preview logs" wide onClose={() => setLogs(false)}><div className="dialog-body"><pre className="preview-logs">{info?.logs || "No startup output has been recorded yet."}</pre></div></Dialog> : null}
  </section>;
}

export function ProjectPreviewSettings({ projectId }: { projectId: string }) {
  const [draft, setDraft] = useState(empty);
  const [loaded, setLoaded] = useState(false);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState("");
  useEffect(() => {
    let alive = true;
    api.previewDefaults(projectId).then(config => { if (alive) { setDraft(config ?? empty); setLoaded(true); } }, err => { if (alive) setNote(err.message); });
    return () => { alive = false; };
  }, [projectId]);
  async function save(clear = false) {
    setBusy(true); setNote("");
    try { const config = await api.savePreviewDefaults(projectId, clear ? null : draft); setDraft(config ?? empty); setNote("Saved. Inheriting previews have stopped; open them to use this default."); }
    catch (err) { setNote(err instanceof Error ? err.message : "Could not save preview defaults."); }
    finally { setBusy(false); }
  }
  return <section aria-label="Project preview defaults"><h4>Preview defaults</h4><p className="fine">Every track can use this app directory and command, with an optional override of its own.</p>
    <PreviewFields value={draft} onChange={setDraft} disabled={busy || !loaded} />
    <div className="preview-controls"><button type="button" disabled={busy || !loaded || !draft.command.trim()} onClick={() => void save()}>Save preview defaults</button><button type="button" disabled={busy || !loaded} onClick={() => void save(true)}>Clear default</button></div>
    {note ? <p className="fine" role="status">{note}</p> : null}
  </section>;
}
