import type { Project, Track } from "../../shared/api";

export function attentionItems(projects: Project[], tracksByProject: Record<string, Track[]>) {
  return projects.flatMap((project) => (tracksByProject[project.id] ?? [])
    .filter((track) => track.status === "failed" || (track.status === "ready" && track.unread))
    .map((track) => ({ project, track })))
    .sort((a, b) => Number(b.track.status === "failed") - Number(a.track.status === "failed")
      || Date.parse(b.track.lastActiveAt ?? b.track.createdAt) - Date.parse(a.track.lastActiveAt ?? a.track.createdAt)
      || a.track.id.localeCompare(b.track.id));
}
