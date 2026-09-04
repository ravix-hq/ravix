/**
 * Who said what, on a track more than one person types into.
 *
 * Fountain's turn carries a prompt and nothing about who typed it — every turn
 * in this app goes in on the server's key, so as far as Fountain is concerned
 * a shared track is one person talking. That is fine until somebody scrolls
 * back through a track two people worked in and cannot tell which half was
 * theirs.
 *
 * So once a track is shared, the prompt the agent receives is prefixed
 * `[from @login] …`. The server writes it and the transcript reads it back off
 * for display, which is why this lives in `shared/`.
 *
 * Two things follow from the prefix being *in the prompt* rather than beside
 * it. The agent sees it, which is the point — "@ana asked for this" is context
 * a coding agent should have when two people are steering. And it is only
 * added when a track actually has more than one person in it, because a solo
 * track prefixed with your own name reads as the app talking to itself.
 */

const PREFIX = /^\[from @([A-Za-z0-9-]{1,39})\]\s?/;

export function withAuthor(login: string, prompt: string): string {
  return `[from @${login}] ${prompt}`;
}

/** The login a prompt names, and the prompt without the label. */
export function splitAuthor(prompt: string): { login: string | null; text: string } {
  const m = PREFIX.exec(prompt);
  if (!m) return { login: null, text: prompt };
  return { login: m[1]!, text: prompt.slice(m[0].length) };
}
