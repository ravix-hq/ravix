import { afterAll, beforeAll, expect, test } from "bun:test";
import { GlobalRegistrator } from "@happy-dom/global-registrator";
import { act } from "react";
import type { Root } from "react-dom/client";
import { PanelResizeHandle } from "./PanelResizeHandle";

let createRoot: (element: HTMLElement) => Root;
beforeAll(async () => {
  GlobalRegistrator.register({ url: "https://localhost/" });
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  ({ createRoot } = await import("react-dom/client"));
});
afterAll(async () => { await GlobalRegistrator.unregister(); });

for (const side of ["left", "right"] as const) {
  test(`${side} panel supports dragging, cancellation, keyboard limits and saved widths`, async () => {
    localStorage.clear();
    const app = document.createElement("div");
    app.className = "app";
    Object.defineProperty(app, "clientWidth", { value: 1500 });
    app.innerHTML = '<div class="yard"></div><div class="split"><div class="inspector"></div></div>';
    document.body.append(app);
    const split = app.querySelector<HTMLElement>(".split")!;
    Object.defineProperty(split, "clientWidth", { value: 1200 });
    const panel = app.querySelector<HTMLElement>(side === "left" ? ".yard" : ".inspector")!;
    panel.getBoundingClientRect = () => ({ width: 340 }) as DOMRect;
    const root = createRoot(panel);
    const property = side === "left" ? "--yard-width" : "--inspector-width";
    try {
      await act(async () => root.render(<PanelResizeHandle side={side} />));
      const handle = panel.querySelector<HTMLElement>('[role="separator"]')!;
      handle.setPointerCapture = () => {};
      handle.releasePointerCapture = () => {};
      const pointer = async (type: string, x: number) => act(async () => {
        handle.dispatchEvent(new PointerEvent(type, { bubbles: true, pointerId: 1, isPrimary: true, button: 0, clientX: x }));
      });
      await pointer("pointerdown", 500);
      await pointer("pointermove", side === "left" ? 550 : 450);
      expect(app.style.getPropertyValue(property)).toBe("390px");
      await pointer("pointercancel", 450);
      await pointer("pointermove", 800);
      expect(app.style.getPropertyValue(property)).toBe("390px");
      expect(handle.dataset.dragging).toBe("false");
      await act(async () => handle.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, key: "Home" })));
      expect(app.style.getPropertyValue(property)).toBe(side === "left" ? "220px" : "280px");
      await act(async () => handle.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, key: "End" })));
      const maximum = handle.getAttribute("aria-valuemax")!;
      expect(app.style.getPropertyValue(property)).toBe(`${maximum}px`);
      expect(localStorage.getItem(`switchyard.panel-width.${side}`)).toBe(maximum);
      await act(async () => root.render(null));
      app.style.removeProperty(property);
      await act(async () => root.render(<PanelResizeHandle side={side} />));
      expect(app.style.getPropertyValue(property)).toBe(`${maximum}px`);
    } finally {
      await act(async () => root.unmount());
      app.remove();
    }
  });
}
