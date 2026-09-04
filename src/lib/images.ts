/**
 * What may ride along with a prompt.
 *
 * The limits here are the server's limits, copied deliberately rather than
 * shared by import: `server/tracks.ts` is the only thing that can *enforce*
 * them, and it goes on doing that. What this file buys is that a person who
 * drops nine screenshots on the composer is told which two did not fit before
 * they press send, instead of after — a rejection that arrives as a failed turn
 * is a rejection nobody can act on.
 */

export interface OutgoingImage {
  data: string;
  media_type: string;
}

/** The four Fountain takes, and so the four the file picker offers. */
export const ACCEPTED = ["image/png", "image/jpeg", "image/gif", "image/webp"];
export const MAX_IMAGES = 6;
export const MAX_IMAGE_BYTES = 8 * 1024 * 1024;

export interface Rejection {
  name: string;
  why: "type" | "size" | "count";
}

/**
 * Sort what somebody just handed us into what can go and what cannot.
 *
 * `held` is how many are already attached, because the count limit is on the
 * prompt rather than on the gesture: two pastes of four images is the same
 * seven-image prompt as one paste of seven, and only one of them would be
 * caught by looking at the drop alone.
 */
export function accept(files: File[], held: number): { accepted: File[]; rejected: Rejection[] } {
  const accepted: File[] = [];
  const rejected: Rejection[] = [];
  for (const file of files) {
    const name = file.name || "that image";
    if (!ACCEPTED.includes(file.type)) rejected.push({ name, why: "type" });
    else if (file.size > MAX_IMAGE_BYTES) rejected.push({ name, why: "size" });
    else if (held + accepted.length >= MAX_IMAGES) rejected.push({ name, why: "count" });
    else accepted.push(file);
  }
  return { accepted, rejected };
}

/** One line saying what was turned away and why. Null when nothing was. */
export function rejectionMessage(rejected: Rejection[]): string | null {
  if (!rejected.length) return null;
  const of = (why: Rejection["why"]) => rejected.filter((r) => r.why === why).map((r) => r.name);
  const parts: string[] = [];
  const wrongType = of("type");
  const tooBig = of("size");
  const overflow = of("count");
  if (wrongType.length) parts.push(`${list(wrongType)}: only PNG, JPEG, GIF and WebP.`);
  if (tooBig.length) parts.push(`${list(tooBig)}: larger than 8 MB.`);
  if (overflow.length) parts.push(`${list(overflow)}: ${MAX_IMAGES} images at a time.`);
  return parts.join(" ");
}

function list(names: string[]): string {
  if (names.length <= 1) return names[0] ?? "";
  return `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]!}`;
}

/**
 * A file, as the prompt route wants it: base64 with no data-URL prefix.
 *
 * `arrayBuffer` rather than `FileReader.readAsDataURL` because the prefix would
 * only have to be sliced off again, and because this way the conversion is a
 * function of bytes — which is a thing that can be tested without a browser.
 */
export async function encodeImage(file: File): Promise<OutgoingImage> {
  const bytes = new Uint8Array(await file.arrayBuffer());
  return { data: toBase64(bytes), media_type: file.type };
}

function toBase64(bytes: Uint8Array): string {
  // In chunks: `String.fromCharCode(...bytes)` on eight megabytes is an
  // argument list long enough to overflow the stack, which shows up as a
  // paste that works on small screenshots and crashes on large ones.
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}
