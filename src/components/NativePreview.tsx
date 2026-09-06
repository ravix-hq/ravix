import type { RunnerInfo } from '../../shared/runners';
import { useCallback, useEffect, useRef, useState } from 'react';
import { api } from '../lib/api';
import { avcCodec, nativeFrame, parseNativeInput, type NativeInfo, type NativePlatform, type NativeInput, type NativeVideo } from '../../shared/native-preview';
export function NativePreviewLauncher({ trackId, owner }: {
    trackId: string;
    owner: boolean;
}) {
    const [info, setInfo] = useState<{
        available: boolean;
        platforms: NativePlatform[];
        runners: RunnerInfo[];
        session: NativeInfo | null;
    } | null>(null), [busy, setBusy] = useState(false), [error, setError] = useState(''), [code, setCode] = useState('');
    const [pairing,setPairing]=useState<{code:string;expiresAt:number}|null>(null);
    const [platform, setPlatform] = useState<NativePlatform>('android');
    const refresh = useCallback(async () => { try {
        setInfo(await api.nativePreview(trackId));
    }
    catch { /* Ordinary conversation work stays available. */ } }, [trackId]);
    useEffect(() => { void refresh(); const timer = setInterval(() => { if (!document.hidden)
        void refresh(); }, 5000); return () => clearInterval(timer); }, [refresh]);
    if (!info?.available)
        return null;
    const session = info.session, cleanupPending = session?.error?.startsWith('Cleanup pending:'), active = session && !['Failed', 'Stopped'].includes(session.phase);
    const action = async (start: boolean) => { setBusy(true); setError(''); try {
        if (start) {
            const next = await api.startNativePreview(trackId, platform);
            setCode(next.pairingCode ?? '');
        }
        else {
            await api.stopNativePreview(trackId);
            setCode('');
        }
        await refresh();
    }
    catch (error) {
        setError(String(error));
    }
    finally {
        setBusy(false);
    } };
    return <section className="native-launcher" aria-label="Native preview">
    <div className="row"><strong>{session?.platform === 'ios' ? 'iOS' : 'Native'} preview</strong><span className="chip">Experiment</span><span role="status">{session?.phase ?? 'Stopped'}{session?.queuePosition ? ` · queue position ${session.queuePosition}` : ''}</span><span className="spacer"/>
      {active ? <a className="ghost" href={`/native/${session.id}`} target="_blank" rel="noopener">Open device</a> : null}
      {owner && !active ? <select aria-label="Device platform" value={platform} onChange={event => setPlatform(event.target.value as NativePlatform)}>{(info.platforms ?? ['android']).map(p => <option key={p} value={p}>{p === 'ios' ? 'iOS' : 'Android'}</option>)}</select> : null}
      {owner ? <button type="button" disabled={busy} onClick={() => void action(!active && !cleanupPending)}>{cleanupPending ? 'Retry cleanup' : active ? 'Stop' : `Start ${platform === 'ios' ? 'iOS' : 'Android'} preview`}</button> : null}
    </div>
    {owner ? <div className="row"><button disabled={busy} onClick={async()=>{setBusy(true);setError('');try{setPairing(await api.pairNativeRunner(trackId));}catch(e){setError(String(e));}finally{setBusy(false);}}}>Pair a Mac runner</button>
      {(info.runners??[]).filter(r=>!r.revoked).map(r=><span key={r.id}>{r.name} · {r.online?'Online':'Offline'} <button disabled={busy} onClick={async()=>{setBusy(true);try{await api.revokeNativeRunner(r.id);await refresh();}catch(e){setError(String(e));}finally{setBusy(false);}}}>Revoke {r.name}</button></span>)}
    </div> : null}
    {pairing && pairing.expiresAt>Date.now() ? <div><p>Run the account setup with <code>--pair-runner</code> and paste this code. It expires in five minutes; the registered Mac can run future previews without pairing again.</p><code className="native-pairing">{pairing.code}</code></div> : null}
    {code && session?.phase === 'Awaiting runner' ? <div><p>Pair the Mac runner with this experiment. This code works once and expires in five minutes.</p><code className="native-pairing">{code}</code></div> : null}
    {error || session?.error ? <p className="error" role="alert">{error || session?.error}</p> : null}
  </section>;
}
export function NativeViewer({ id }: {
    id: string;
}) {
    const canvas = useRef<HTMLCanvasElement>(null), inputSocket = useRef<WebSocket | null>(null), videoInfo = useRef<NativeVideo | null>(null), pointer = useRef<number | null>(null);
    const [info, setInfo] = useState<(NativeInfo & {
        trackUrl: string;
    }) | null>(null), [error, setError] = useState(''), [controlled, setControlled] = useState(false), [text, setText] = useState(''), [fps, setFps] = useState(0);
    const [controlAttempt, setControlAttempt] = useState(0), [watching, setWatching] = useState(false);
    useEffect(() => {
        let alive = true, video: WebSocket | null = null, decoder: VideoDecoder | null = null, configuration: Uint8Array | null = null, waiting = true, rendered = 0, lastRendered = 0, retries = 0, retry: ReturnType<typeof setTimeout> | undefined;
        const url = (role: string) => `${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/api/native/sessions/${id}/${role}`;
        const end = (message: string) => { if (!alive)
            return; setError(message); video?.close(); inputSocket.current?.close(); };
        const closeDecoder = () => { if (decoder?.state !== 'closed')
            decoder?.close(); decoder = null; waiting = true; };
        const decode = (buffer: ArrayBuffer) => {
            const frame = nativeFrame(new Uint8Array(buffer));
            if (frame.config) {
                configuration = frame.data.slice();
                closeDecoder();
                return;
            }
            if (!configuration || !videoInfo.current)
                return;
            if (!decoder) {
                if (!('VideoDecoder' in window))
                    throw Error('This browser does not support live H.264 decoding. Open the device in a browser with WebCodecs support.');
                decoder = new VideoDecoder({ output: frame => { try {
                        const c = canvas.current;
                        if (c) {
                            c.width = frame.displayWidth;
                            c.height = frame.displayHeight;
                            c.getContext('2d')?.drawImage(frame, 0, 0);
                            rendered++;
                            setWatching(true);
                        }
                    }
                    finally {
                        frame.close();
                    } }, error: error => { setError(`Video decoder: ${error.message}`); closeDecoder(); } });
                decoder.configure({ codec: avcCodec(configuration), optimizeForLatency: true });
            }
            if (decoder.decodeQueueSize > 3) {
                closeDecoder();
                return;
            }
            if (waiting && !frame.key)
                return;
            let bytes = frame.data;
            if (waiting) {
                bytes = new Uint8Array(configuration.length + frame.data.length);
                bytes.set(configuration);
                bytes.set(frame.data, configuration.length);
                waiting = false;
            }
            decoder.decode(new EncodedVideoChunk({ type: frame.key ? 'key' : 'delta', timestamp: frame.timestamp, data: bytes }));
        };
        const connectVideo = () => {
            if (!alive || (video && video.readyState !== WebSocket.CLOSED))
                return;
            video = new WebSocket(url('view'));
            video.binaryType = 'arraybuffer';
            video.onmessage = event => { try {
                if (typeof event.data === 'string') {
                    const meta = JSON.parse(event.data) as NativeVideo;
                    if (meta.type !== 'video' || meta.codec !== 'h264')
                        throw Error('Invalid video metadata');
                    videoInfo.current = meta;
                    configuration = null;
                    closeDecoder();
                }
                else
                    decode(event.data);
            }
            catch (error) {
                end(String(error));
            } };
            video.onopen = () => { retries=0;setError(''); };
            video.onclose = event => { setWatching(false); if (alive && event.code === 1013 && retries++ < 3)
                retry = setTimeout(connectVideo, 500);
            else if (alive)
                setError(event.reason || 'Device stream disconnected. Reload to reconnect.'); };
        };
        const poll = async () => { try {
            const next = await api.nativeSession(id);
            if (!alive)
                return;
            setInfo(next);
            if (['Failed', 'Stopped'].includes(next.phase)) end(next.error || 'Preview stopped.');
            else if (['Connecting','Ready'].includes(next.phase) && (!video || video.readyState===WebSocket.CLOSED)) { setError('');connectVideo(); }
            else if (['Queued','Reconciling'].includes(next.phase)) { video?.close();inputSocket.current?.close();setWatching(false);setError(''); }
        }
        catch (error) {
            end(String(error));
        } };
        void poll();
        const timer = setInterval(() => { if (!document.hidden) {
            void poll();
            if (video?.readyState === WebSocket.OPEN)
                video.send(JSON.stringify({ type: 'heartbeat' }));
        } setFps(rendered - lastRendered); lastRendered = rendered; }, 1000);
        return () => { alive = false; clearInterval(timer); if (retry)
            clearTimeout(retry); video?.close(); inputSocket.current?.close(); closeDecoder(); inputSocket.current = null; };
    }, [id]);
    useEffect(() => {
        if (!controlAttempt) return;
        const controls = new WebSocket(`${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/api/native/sessions/${id}/input`);
        inputSocket.current = controls;
        controls.onmessage = event => {
            try { const message = JSON.parse(String(event.data)); if (message.type === 'controller') setControlled(message.active === true); }
            catch { controls.close(); setError('Invalid controller response'); }
        };
        controls.onclose = event => { setControlled(false); pointer.current = null; if (event.code === 1008) setError(event.reason); if (inputSocket.current === controls) inputSocket.current = null; };
        const cancel = () => {
            if (pointer.current !== null && videoInfo.current && controls.readyState === WebSocket.OPEN)
                controls.send(JSON.stringify({type: 'touch', action: 'cancel', x: 0, y: 0, width: videoInfo.current.width, height: videoInfo.current.height}));
            pointer.current = null;
        };
        const timer = setInterval(() => { if (!document.hidden && controls.readyState === WebSocket.OPEN) controls.send(JSON.stringify({type: 'heartbeat'})); }, 10000);
        window.addEventListener('blur', cancel);
        document.addEventListener('visibilitychange', cancel);
        return () => { cancel(); clearInterval(timer); window.removeEventListener('blur', cancel); document.removeEventListener('visibilitychange', cancel); controls.close(); if (inputSocket.current === controls) inputSocket.current = null; };
    }, [id, controlAttempt]);
    const send = (value: NativeInput) => { try {
        const input = parseNativeInput(value);
        if (info?.platform === 'ios' && input.type === 'text' && /[^\x20-\x7e]/.test(input.text)) throw Error('iOS text input supports printable ASCII characters.');
        if (inputSocket.current?.readyState !== WebSocket.OPEN)
            throw Error('Take control before interacting with the device.');
        inputSocket.current.send(JSON.stringify(input));
    }
    catch (error) {
        setError(String(error));
    } };
    const position = (x: number, y: number) => { const rect = canvas.current!.getBoundingClientRect(), v = videoInfo.current!; return { x: Math.max(0, Math.min(1, (x - rect.left) / rect.width)), y: Math.max(0, Math.min(1, (y - rect.top) / rect.height)), width: v.width, height: v.height }; };
    const touch = (action: 'down' | 'move' | 'up' | 'cancel', event: React.PointerEvent<HTMLCanvasElement>) => {
        if (!controlled || !videoInfo.current)
            return;
        if ((action === 'down' && pointer.current !== null) || (action !== 'down' && pointer.current !== event.pointerId))
            return;
        event.preventDefault();
        if (action === 'down') {
            pointer.current = event.pointerId;
            event.currentTarget.setPointerCapture(event.pointerId);
        }
        send({ type: 'touch', action, ...position(event.clientX, event.clientY) });
        if (action === 'up' || action === 'cancel') {
            pointer.current = null;
            if (event.currentTarget.hasPointerCapture(event.pointerId))
                event.currentTarget.releasePointerCapture(event.pointerId);
        }
    };
    return <main className="native-viewer">
    <header className="row"><a href={info?.trackUrl ?? '/'}>← Back to track</a><strong>{info?.platform === 'ios' ? 'iOS' : 'Android'} preview</strong><span role="status">{info?.phase ?? 'Connecting'}</span><span className="spacer"/><span>{watching ? `${fps} fps` : 'Waiting for screen'}</span></header>
    {error ? <p className="error" role="alert">{error} <a href="/">Open Switchyard</a></p> : null}
    <div className="native-screen"><canvas ref={canvas} style={{height: 'auto', width: `min(100%, ${68 * (info?.video ? info.video.width / info.video.height : 576 / 1280)}dvh)`}} width={576} height={1280} aria-label={`${info?.platform === 'ios' ? 'iOS' : 'Android'} device screen`} onPointerDown={event => touch('down', event)} onPointerMove={event => touch('move', event)} onPointerUp={event => touch('up', event)} onPointerCancel={event => touch('cancel', event)} onLostPointerCapture={event => touch('cancel', event)} onWheel={event => { if (controlled && videoInfo.current) {
        event.preventDefault();
        send({ type: 'scroll', delta: Math.max(-16, Math.min(16, -event.deltaY / 50)), ...position(event.clientX, event.clientY) });
    } }}/></div>
    <div className="row native-controls"><button disabled={!controlled && info?.phase !== 'Ready'} onClick={() => { if (controlled) {
        inputSocket.current?.close();
        setControlled(false);
    }
    else {
        setError('');
        setControlAttempt(n => n + 1);
    } }}>{controlled ? 'Release control' : 'Take control'}</button>
      {(['back', 'home', 'enter', 'backspace'] as const).filter(key => info?.platform !== 'ios' || key !== 'back').map(key => <button key={key} disabled={!controlled} onClick={() => send({ type: 'key', key })}>{key}</button>)}
      <button disabled={!watching} onClick={() => { const a = document.createElement('a'); a.href = canvas.current!.toDataURL('image/png'); a.download = `switchyard-${info?.platform ?? 'android'}.png`; a.click(); }}>Screenshot</button>
      <button disabled={!info} onClick={() => { if (info)
        void api.stopNativePreview(info.trackId).catch(error => setError(String(error))); }}>Stop</button>
    </div>
    <form className="row native-controls" onSubmit={event => { event.preventDefault(); if (text) {
        send({ type: 'text', text });
        setText('');
    } }}><input aria-label="Text to type on device" placeholder={info?.platform === 'ios' ? 'Tap a device text field, then type here (ASCII)' : 'Tap a device text field, then type here'} maxLength={300} value={text} onChange={event => setText(event.target.value)} disabled={!controlled}/><button disabled={!controlled || !text}>Send text</button></form>
    <p className="fine">Live Sprite workspace · H.264 · one controller at a time. Closing the viewer releases control; Stop ends the experiment.</p>
  </main>;
}
