import { useCallback, useEffect, useRef, useState } from "react";
import type { BrowserInfo, BrowserResult } from "../../shared/browser";
import { BROWSER_WIDTH, BROWSER_HEIGHT } from "../../shared/browser";
import { api } from "../lib/api";
import { Dialog } from "./Dialog";

/** The card attaches to a machine session. Unmounting only releases input. */
export function SharedBrowser({ trackId, owner }: { trackId: string; owner: boolean }) {
  const [clientId] = useState(() => crypto.randomUUID());
  const [info, setInfo] = useState<BrowserInfo | null>(null), [state, setState] = useState<BrowserResult | null>(null);
  const [opened, setOpened] = useState(false), [expanded, setExpanded] = useState(false), [busy, setBusy] = useState(false);
  const [error, setError] = useState(""), [selected, setSelected] = useState(""), [image, setImage] = useState("");
  const [address, setAddress] = useState(""), [text, setText] = useState(""), [label, setLabel] = useState("");
  const [checkpointId, setCheckpointId] = useState(""), [restoreReview, setRestoreReview] = useState(false);
  const current = useRef(state), alive = useRef(true), selectedRef = useRef(selected), root = useRef<HTMLElement>(null);
  const inputQueue = useRef(Promise.resolve());
  const retiredRevisions = useRef(new Set<string>());
  const input = useRef<(body: Record<string, unknown>) => void>(() => {});
  current.current = state; selectedRef.current = selected;
  const controlled = opened && info?.session?.state === "ready" && !!state?.controller?.id.endsWith(`:${clientId}`) && state.controller.kind === "human";
  const refresh = useCallback(async () => { const next = await api.browser(trackId); if (alive.current) setInfo(next); }, [trackId]);
  const apply = useCallback((result: BrowserResult) => {
    if (!alive.current) return;
    if (retiredRevisions.current.has(result.revision)) return;
    if (result.revision === current.current?.revision && result.sequence < current.current.sequence) return;
    if (current.current && result.revision !== current.current.revision) retiredRevisions.current.add(current.current.revision);
    setState(result);
    if (result.revision !== current.current?.revision) { setImage(""); setRestoreReview(false); }
    current.current = result;
    const next = result.tabs.find(tab => tab.id === selectedRef.current)?.id ?? result.tabs[0]?.id ?? "";
    if (next !== selectedRef.current) { setImage(""); setSelected(next); }
  }, []);
  const command = useCallback(async (body: Record<string, unknown>) => {
    const result = await api.browserCommand(trackId, clientId, { revision: current.current?.revision, ...body });
    apply(result); return result;
  }, [trackId, clientId, apply]);
  const run = async (fn: () => Promise<unknown>) => {
    setBusy(true); setError("");
    try { await fn(); } catch (error) { if (alive.current) setError(error instanceof Error ? error.message : "Browser operation failed."); }
    finally { if (alive.current) setBusy(false); }
  };
  useEffect(() => {
    alive.current = true;
    void refresh().catch(() => {});
    const timer = setInterval(() => { if (!document.hidden) void refresh().catch(() => {}); }, 5000);
    return () => { alive.current = false; clearInterval(timer); void api.browserCommand(trackId, clientId, { action: "release" }).catch(() => {}); };
  }, [trackId, clientId, refresh]);
  useEffect(() => {
    if (!opened || info?.session?.state !== "ready") return;
    let active = true, timer: ReturnType<typeof setTimeout>;
    const poll = async () => {
      try {
        if (!document.hidden) {
          const tabId = selectedRef.current;
          const result = await command(tabId ? { action: "screenshot", tabId } : { action: "status" });
          if (active && result.image && tabId === selectedRef.current && result.revision === current.current?.revision && result.sequence === current.current.sequence) setImage(`data:image/jpeg;base64,${result.image}`);
        }
      } catch (error) { if (active) setError(error instanceof Error ? error.message : "Browser disconnected."); }
      if (active) timer = setTimeout(() => void poll(), controlled ? 250 : 1500);
    };
    void poll();
    return () => { active = false; clearTimeout(timer); };
  }, [opened, info?.session?.state, controlled, command]);
  useEffect(() => {
    if (!controlled) return;
    const release = () => { if (document.hidden || !document.hasFocus()) void command({ action: "release" }).catch(() => {}); };
    const timer = setInterval(() => { if (!document.hidden) void command({ action: "acquire" }).catch(() => {}); }, 10000);
    window.addEventListener("blur", release); document.addEventListener("visibilitychange", release);
    return () => { clearInterval(timer); window.removeEventListener("blur", release); document.removeEventListener("visibilitychange", release); };
  }, [controlled, command]);
  useEffect(() => {
    const screen = root.current?.querySelector<HTMLElement>(".browser-screen");
    if (!controlled || !screen) return;
    let timer: ReturnType<typeof setTimeout> | undefined, deltaX = 0, deltaY = 0, x = 0, y = 0;
    const wheel = (event: WheelEvent) => {
      event.preventDefault(); event.stopPropagation();
      const rect = screen.getBoundingClientRect();
      x = Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width));
      y = Math.max(0, Math.min(1, (event.clientY - rect.top) / rect.height));
      deltaX = Math.max(-2000, Math.min(2000, deltaX + event.deltaX)); deltaY = Math.max(-2000, Math.min(2000, deltaY + event.deltaY));
      if (timer) return;
      timer = setTimeout(() => { input.current({ action: "scroll", x, y, deltaX, deltaY }); deltaX = deltaY = 0; timer = undefined; }, 100);
    };
    screen.addEventListener("wheel", wheel, { passive: false });
    return () => { screen.removeEventListener("wheel", wheel); clearTimeout(timer); };
  }, [controlled, selected, expanded, opened]);
  const tab = state?.tabs.find(tab => tab.id === selected);
  useEffect(() => { setAddress(tab?.url ?? ""); }, [tab?.id, tab?.url]);
  const sendInput = (body: Record<string, unknown>) => {
    if (!controlled || !selected) return;
    const revision = current.current?.revision, tabId = selected;
    inputQueue.current = inputQueue.current.then(async () => {
      if (!alive.current || !current.current?.controller?.id.endsWith(`:${clientId}`) || current.current.revision !== revision) return;
      await command({ ...body, tabId, revision });
    }).catch(error => { if (alive.current) setError(error instanceof Error ? error.message : "Input failed."); });
  };
  input.current = sendInput;
  if (!info?.available) return null;
  const ready = info.session?.state === "ready";
  const card = <section ref={root} className={`shared-browser${expanded ? " expanded" : ""}`} aria-label="Shared browser">
    <div className="browser-heading"><strong>Shared browser</strong><span className="chip">One shared session</span><span className="spacer" />
      {opened ? <button type="button" onClick={() => { setOpened(false); setExpanded(false); void command({ action: "release" }).catch(() => {}); }}>Hide</button> : null}
      <button type="button" disabled={busy} onClick={() => void run(async () => {
        if (!ready) setInfo(await api.browserAction(trackId, "start", clientId));
        setOpened(true); await command({ action: "status" });
      })}>{busy && !opened ? "Opening…" : opened ? "Reconnect" : "Open browser"}</button>
    </div>
    <p className="fine">Shared across this machine’s tracks and people. Logins and tabs stay when you leave chat.</p>
    {error || info.session?.error ? <p className="error" role="alert">{error || info.session?.error}</p> : null}
    {opened && ready ? <>
      <div className="browser-toolbar">
        <select aria-label="Browser tab" value={selected} onChange={e => { setImage(""); setSelected(e.target.value); }}>
          {!state?.tabs.length ? <option value="">No tabs</option> : null}
          {state?.tabs.map(tab => <option key={tab.id} value={tab.id}>{tab.title || tab.url}</option>)}
        </select>
        <button type="button" onClick={() => setExpanded(!expanded)}>{expanded ? "Collapse" : "Expand"}</button>
        <button type="button" disabled={busy || (!!state?.controller && !controlled && state.controller.kind === "human")} onClick={() => void run(() => command({ action: controlled ? "release" : "acquire" }))}>{controlled ? "Hand back" : "Take control"}</button>
      </div>
      <p className="fine" role="status">{controlled ? "You have control" : state?.controller ? `${state.controller.label} has control` : "Available for you or the agent"}</p>
      <form className="browser-toolbar" onSubmit={e => { e.preventDefault(); void run(async () => {
        const result = await command({ action: selected ? "navigate" : "open", tabId: selected, url: address });
        if (result.tabId) setSelected(result.tabId);
      }); }}>
        <button type="button" aria-label="Go back" disabled={!controlled || !selected || busy} onClick={() => void run(() => command({ action: "back", tabId: selected }))}>←</button>
        <button type="button" aria-label="Reload page" disabled={!controlled || !selected || busy} onClick={() => void run(() => command({ action: "reload", tabId: selected }))}>↻</button>
        <input aria-label="Browser address" placeholder="https://example.com" value={address} onChange={e => setAddress(e.target.value)} disabled={!controlled} />
        <button type="submit" disabled={!controlled || busy || !address}>Go</button>
        <button type="button" disabled={!controlled || busy || !address} onClick={() => void run(async () => { const result = await command({ action: "open", url: address }); if (result.tabId) setSelected(result.tabId); })}>New tab</button>
        <button type="button" aria-label="Close browser tab" disabled={!controlled || busy || !selected} onClick={() => void run(() => command({ action: "close", tabId: selected }))}>×</button>
      </form>
      <div className={`browser-screen${controlled ? " controlled" : ""}`} tabIndex={controlled ? 0 : -1} role="group" aria-label="Remote browser screen. Click to focus; use the text field to type."
        onClick={e => {
          if (!controlled) { void run(() => command({ action: "acquire" })); return; }
          e.currentTarget.focus(); const rect = e.currentTarget.getBoundingClientRect();
          sendInput({ action: "click", x: (e.clientX - rect.left) / rect.width, y: (e.clientY - rect.top) / rect.height });
        }}
        onKeyDown={e => { if (!controlled || e.key === "Tab" || e.key === "Escape" || ["Meta", "Control", "Alt", "Shift"].includes(e.key)) return;
          e.preventDefault(); const prefix = `${e.ctrlKey || e.metaKey ? "ControlOrMeta+" : ""}${e.altKey ? "Alt+" : ""}${e.shiftKey && e.key.length > 1 ? "Shift+" : ""}`;
          sendInput(e.key.length === 1 && !prefix ? { action: "text", text: e.key } : { action: "key", key: prefix + e.key });
        }}>
        {image ? <img src={image} width={BROWSER_WIDTH} height={BROWSER_HEIGHT} alt={tab?.title || "Shared browser page"} draggable={false} /> : <div className="browser-placeholder">{selected ? "Connecting to tab…" : "Take control and enter a URL to open a tab."}</div>}
        {!controlled && image ? <span className="browser-interact">Click to take control</span> : null}
      </div>
      <form className="browser-toolbar" onSubmit={e => { e.preventDefault(); if (text) { sendInput({ action: "text", text }); setText(""); } }}>
        <input aria-label="Text for focused browser field" placeholder="Type or paste into the focused field…" value={text} onChange={e => setText(e.target.value)} disabled={!controlled || !selected} />
        <button type="submit" disabled={!controlled || !text}>Send text</button>
        <button type="button" disabled={!controlled || !selected} onClick={() => sendInput({ action: "key", key: "Tab" })}>Tab</button>
        <button type="button" disabled={!controlled || !selected} onClick={() => sendInput({ action: "key", key: "Enter" })}>Enter</button>
      </form>
      <details><summary>Session checkpoints</summary>
        <p className="fine">Save logins, browser storage, and tab addresses. Restore reloads pages; it does not undo actions on a website.</p>
        <form className="browser-toolbar" onSubmit={e => { e.preventDefault(); void run(async () => { await api.browserCheckpoint(trackId, clientId, label); setLabel(""); await refresh(); }); }}>
          <input aria-label="Checkpoint name" placeholder="Checkpoint name" value={label} maxLength={120} onChange={e => setLabel(e.target.value)} />
          <button type="submit" disabled={!controlled || busy}>Save checkpoint</button>
        </form>
        {info.checkpoints.map(cp => <div className="browser-checkpoint" key={cp.id}><span>{cp.label} · {new Date(cp.createdAt).toLocaleString()}<code>{cp.id}</code></span>{owner ? <>
          <button type="button" disabled={!controlled || busy} onClick={() => { setCheckpointId(cp.id); setRestoreReview(true); }}>Restore…</button>
          <button type="button" disabled={busy} onClick={() => void run(async () => setInfo(await api.browserAction(trackId, "delete-checkpoint", clientId, cp.id)))}>Delete</button>
        </> : null}</div>)}
        {owner ? <form className="browser-toolbar" onSubmit={e => { e.preventDefault(); setRestoreReview(true); }}>
          <input aria-label="Checkpoint ID to restore" placeholder="Checkpoint ID from this or another project you own" value={checkpointId} onChange={e => { setCheckpointId(e.target.value); setRestoreReview(false); }} />
          <button type="submit" disabled={!controlled || busy || !checkpointId}>Review restore</button>
        </form> : null}
        {restoreReview ? <div className="browser-restore"><p>Replace this machine’s shared browser with checkpoint <code>{checkpointId}</code>? Everyone will see its logins and reopened tabs. Current tabs will close.</p>
          <button type="button" disabled={!controlled || busy} onClick={() => void run(async () => { apply(await api.browserRestore(trackId, clientId, checkpointId)); setRestoreReview(false); await refresh(); })}>Restore shared session</button>
          <button type="button" onClick={() => setRestoreReview(false)}>Cancel</button>
        </div> : null}
      </details>
      {owner ? <button type="button" className="linkish" disabled={busy} onClick={() => void run(async () => { setInfo(await api.browserAction(trackId, "stop", clientId)); setOpened(false); setImage(""); })}>Stop browser · keep profile</button> : null}
    </> : null}
  </section>;
  return expanded ? <Dialog title="Shared browser" wide onClose={() => setExpanded(false)}><div className="dialog-body">{card}</div></Dialog> : card;
}
