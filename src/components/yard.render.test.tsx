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
  expect(html).toContain(`track-activity ${kind}`);
  expect(html).toContain(label);
  if (kind === "busy") expect(html).not.toContain("Needs attention");
});
