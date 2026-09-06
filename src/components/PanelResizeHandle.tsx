import { useLayoutEffect, useRef, useState } from "react";

/** A captured pointer keeps resizing when it leaves the narrow divider. */
export function PanelResizeHandle({ side }: { side: "left" | "right" }) {
  const handle = useRef<HTMLDivElement>(null);
  const drag = useRef<{ x: number; width: number; pointer: number } | null>(null);
  const [dragging, setDragging] = useState(false);
  const [width, setWidth] = useState(0);
  const [maximum, setMaximum] = useState(800);
  const minimum = side === "left" ? 220 : 280;
  const property = side === "left" ? "--yard-width" : "--inspector-width";
  const key = `switchyard.panel-width.${side}`;

  function resize(value: number) {
    const next = Math.round(Math.max(minimum, Math.min(maximum, value)));
    handle.current?.closest<HTMLElement>(".app")?.style.setProperty(property, `${next}px`);
    setWidth(next);
    try { localStorage.setItem(key, String(next)); } catch { /* Storage may be disabled. */ }
  }

  useLayoutEffect(() => {
    const app = handle.current!.closest<HTMLElement>(".app")!;
    const panel = app.querySelector<HTMLElement>(side === "left" ? ".yard" : ".inspector")!;
    try {
      const saved = Number(localStorage.getItem(key));
      if (Number.isFinite(saved) && saved >= minimum) app.style.setProperty(property, `${Math.min(side === "left" ? 480 : 800, saved)}px`);
    } catch { /* Resizing still works without storage. */ }
    const measure = () => {
      const available = side === "left"
        ? app.clientWidth - (window.innerWidth > 1100 ? 700 : 420)
        : panel.parentElement!.clientWidth - 420;
      setMaximum(Math.max(minimum, Math.min(side === "left" ? 480 : 800, available)));
      setWidth(Math.round(panel.getBoundingClientRect().width));
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(app);
    observer.observe(panel);
    return () => observer.disconnect();
  }, [side, key, minimum, property]);

  return <div
    ref={handle}
    className={`panel-resize-handle ${side}`}
    role="separator"
    aria-label={side === "left" ? "Sidebar width" : "Inspector width"}
    aria-orientation="vertical"
    aria-valuemin={minimum}
    aria-valuemax={maximum}
    aria-valuenow={width}
    tabIndex={0}
    data-dragging={dragging}
    onPointerDown={(event) => {
      if (event.button !== 0 || !event.isPrimary) return;
      event.preventDefault();
      event.currentTarget.focus();
      event.currentTarget.setPointerCapture(event.pointerId);
      drag.current = { x: event.clientX, width, pointer: event.pointerId };
      setDragging(true);
    }}
    onPointerMove={(event) => {
      const start = drag.current;
      if (start && start.pointer === event.pointerId) resize(start.width + (event.clientX - start.x) * (side === "left" ? 1 : -1));
    }}
    onPointerUp={(event) => {
      if (drag.current?.pointer !== event.pointerId) return;
      event.currentTarget.releasePointerCapture(event.pointerId);
      drag.current = null;
      setDragging(false);
    }}
    onPointerCancel={() => { drag.current = null; setDragging(false); }}
    onLostPointerCapture={() => { drag.current = null; setDragging(false); }}
    onKeyDown={(event) => {
      const direction = side === "left" ? 1 : -1;
      const step = event.shiftKey ? 50 : 10;
      if (event.key === "ArrowLeft") resize(width - step * direction);
      else if (event.key === "ArrowRight") resize(width + step * direction);
      else if (event.key === "Home") resize(minimum);
      else if (event.key === "End") resize(maximum);
      else return;
      event.preventDefault();
    }}
  />;
}
