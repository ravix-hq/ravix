/**
 * Names for tracks that arrive without one.
 *
 * "Untitled" is a fine placeholder in an app where you have one of something.
 * It is a bad one here, because the whole premise is four tracks at once — and
 * four rows reading Untitled, Untitled 2, Untitled 3 is a sidebar you have to
 * decode instead of read. Conductor names its threads after places for exactly
 * this reason: a name you did not choose is still a name you can *recognise*,
 * which is all the sidebar is being asked to do.
 *
 * So these are real classification yards and junctions — the places where a
 * railway does what this app does, which is hold many things in parallel off
 * one main line. They are chosen to be short, unambiguous when slugified, and
 * pronounceable by somebody who has never heard of them, because a track's
 * name is also its directory, its branch and the thing you say out loud when
 * you ask a colleague to look at it.
 *
 * A name is a suggestion, not a label: `PATCH /api/tracks/:id` renames, and a
 * track started from a pull request or an issue never gets one of these
 * because it already has a better name of its own.
 */
import { slugify } from "./ids";

/**
 * The yard list.
 *
 * Every entry is a real place. Some read as common nouns — Hamlet, Clearing,
 * Alliance, Avon — and those are kept deliberately: they are genuinely the
 * names of yards, and the occasional word that means something else is what
 * stops the list feeling like a random-word generator.
 */
export const YARDS: readonly string[] = [
  // Britain
  "Crewe",
  "Didcot",
  "Tamworth",
  "Carstairs",
  "Willesden",
  "Toton",
  "Whitemoor",
  "Margam",
  "Grantham",
  "Doncaster",
  "Carlisle",
  "Swindon",
  "Preston",
  "Rugby",
  "Ely",
  "Wembley",
  "Severn",
  // North America
  "Bailey",
  "Argentine",
  "Barstow",
  "Roseville",
  "Proviso",
  "Corwith",
  "Bensenville",
  "Cicero",
  "Elkhart",
  "Conway",
  "Enola",
  "Altoona",
  "Selkirk",
  "Waycross",
  "Hamlet",
  "Linwood",
  "Markham",
  "Clearing",
  "Northtown",
  "Galesburg",
  "Willard",
  "Avon",
  "Decatur",
  "Pasco",
  "Hinkle",
  "Tucumcari",
  "Alliance",
  "Havelock",
  "Moncton",
  "Vaughan",
  // Elsewhere
  "Maschen",
  "Hallsberg",
  "Bettembourg",
  "Zeebrugge",
  "Antwerp",
  "Tarcoola",
  "Bandel",
];

/**
 * A name no live or closed track of this project has used.
 *
 * Closed tracks count, and that is the point of passing them in. A closed
 * track's slug is free as far as the database is concerned — the unique index
 * only covers open ones — but its *branch* still exists on GitHub, and
 * `git worktree add -b jhgaylor/crewe` a second time fails. The opening turn
 * recovers from that, so reusing a name is survivable rather than broken; it
 * is just needlessly confusing, and there are fifty other names.
 *
 * The walk starts at a random index and goes round once, so the common case is
 * one comparison and the list is exhausted in order only when it nearly is.
 * `random` is injected so the test can assert on the behaviour rather than on
 * a seed.
 */
export function nameTrack(taken: Iterable<string> = [], random: () => number = Math.random): string {
  const used = new Set<string>();
  for (const t of taken) used.add(slugify(t));

  const start = Math.floor(random() * YARDS.length) % YARDS.length;
  for (let i = 0; i < YARDS.length; i++) {
    const name = YARDS[(start + i) % YARDS.length]!;
    if (!used.has(slugify(name))) return name;
  }

  // Fifty tracks deep in one project. Suffixing beats refusing, and beats
  // handing back a name the caller would have to disambiguate anyway.
  const base = YARDS[start]!;
  for (let n = 2; n < 1000; n++) {
    if (!used.has(slugify(`${base} ${n}`))) return `${base} ${n}`;
  }
  return `${base} ${Date.now().toString(36)}`;
}
