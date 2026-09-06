import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { createElement } from "react";
import type { Project, Track } from "../../shared/api";
import { attentionItems } from "./inbox";
import { Inbox } from "../components/Inbox";

const projects = [{ id: "a", name: "Alpha" }, { id: "b", name: "Beta" }] as Project[];
const track = (id: string, status: Track["status"], unread: boolean, date = "2026-09-01") =>
  ({ id, title: id, branch: "feature/" + id, status, unread, createdAt: date, lastActiveAt: date }) as Track;

test("collects attention across projects, with failures first and newest replies first", () => {
  const items = attentionItems(projects, {
    a: [track("old", "ready", true), track("read", "ready", false), track("running", "running", true)],
    b: [track("new", "ready", true, "2026-09-02"), track("failed", "failed", false), track("closed", "closed", true), track("opening", "opening", true)],
    removed: [track("inaccessible", "failed", true)],
  });
  expect(items.map((item) => item.track.id)).toEqual(["failed", "new", "old"]);
  expect(items[1]?.project.name).toBe("Beta");
});

test("missing projects do not hide loaded results or claim the inbox is caught up", () => {
  const html = renderToStaticMarkup(createElement(Inbox, {
    projects, tracksByProject: { a: [track("reply", "ready", true)] }, errors: { b: true },
    onRetry() {}, onPick() {},
  }));
  expect(html).toContain('href="/p/a/t/reply"');
  expect(html).toContain("Could not refresh Beta");
  expect(html).not.toContain("caught up");
});

test("loading and empty states are distinct", () => {
  const props = { projects, errors: {}, onRetry() {}, onPick() {} };
  expect(renderToStaticMarkup(createElement(Inbox, { ...props, tracksByProject: {} }))).toContain("Checking projects");
  expect(renderToStaticMarkup(createElement(Inbox, { ...props, tracksByProject: { a: [], b: [] } }))).toContain("caught up");
});
