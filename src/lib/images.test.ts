import { describe, expect, test } from "bun:test";
import { accept, encodeImage, MAX_IMAGE_BYTES, MAX_IMAGES, rejectionMessage } from "./images";

/**
 * The point of these limits is that they are the *server's*, so the assertions
 * worth having are the ones that would catch this file drifting away from
 * `readImages` in `server/tracks.ts`: the four types, the six, and the eight
 * megabytes.
 */

const png = (name: string, size = 10) => new File([new Uint8Array(size)], name, { type: "image/png" });

describe("accept", () => {
  test("takes the four types and turns away the rest", () => {
    const { accepted, rejected } = accept([png("a.png"), new File(["x"], "notes.pdf", { type: "application/pdf" })], 0);
    expect(accepted.map((f) => f.name)).toEqual(["a.png"]);
    expect(rejected).toEqual([{ name: "notes.pdf", why: "type" }]);
  });

  test("turns away an image over eight megabytes", () => {
    const { accepted, rejected } = accept([png("huge.png", MAX_IMAGE_BYTES + 1)], 0);
    expect(accepted).toEqual([]);
    expect(rejected).toEqual([{ name: "huge.png", why: "size" }]);
  });

  test("counts what is already attached, not just what was dropped", () => {
    const { accepted, rejected } = accept([png("a.png"), png("b.png")], MAX_IMAGES - 1);
    expect(accepted.map((f) => f.name)).toEqual(["a.png"]);
    expect(rejected).toEqual([{ name: "b.png", why: "count" }]);
  });
});

describe("rejectionMessage", () => {
  test("says nothing when nothing was turned away", () => {
    expect(rejectionMessage([])).toBeNull();
  });

  test("names every file and groups them by reason", () => {
    const message = rejectionMessage([
      { name: "a.pdf", why: "type" },
      { name: "b.txt", why: "type" },
      { name: "c.png", why: "size" },
    ]);
    expect(message).toBe("a.pdf and b.txt: only PNG, JPEG, GIF and WebP. c.png: larger than 8 MB.");
  });
});

test("encodeImage strips nothing and prefixes nothing", async () => {
  const file = new File([new Uint8Array([104, 105])], "hi.png", { type: "image/png" });
  expect(await encodeImage(file)).toEqual({ data: "aGk=", media_type: "image/png" });
});
