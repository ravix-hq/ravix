import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { Track } from "../../shared/api";
import { TrackActivity } from "./Yard";

test.each([
  ["running", true, "Running", "busy"],
  ["running", false, "Running", "busy"],
  ["opening", true, "Opening", "busy"],
  ["ready", true, "Needs attention", "attention"],
  ["ready", false, "Idle", "idle"],
  ["failed", false, "Needs attention", "attention"],
  ["closed", true, "Closed", "idle"],
] as const)("%s with unread=%s displays %s", (status: Track["status"], unread, label, kind) => {
  const html = renderToStaticMarkup(<TrackActivity track={{ status }} unread={unread} />);
  if (kind === "idle") {
    expect(html).toBe("");
    return;
  }
  expect(html).toContain(`track-activity ${kind}`);
  expect(html).toContain(`aria-label="${label}"`);
  expect(html.replace(/<[^>]*>/g, "")).not.toMatch(/Idle|Needs attention|Running|Opening/);
  if (kind === "busy") expect(html).not.toContain("Needs attention");
});

test("idle tracks retain their ordinal without a status line", () => {
  expect(renderToStaticMarkup(<TrackActivity track={{ status: "ready" }} unread={false} ordinal={4} />)).toBe("4");
});
