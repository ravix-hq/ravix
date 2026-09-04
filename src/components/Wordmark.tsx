/**
 * The wordmark, drawn as blocks.
 *
 * A five-by-seven bitmap rather than a font, for the reason Conductor's own
 * splash is one: at this size a typeface is somebody else's decision about
 * letterforms, and a grid is the app saying what it is — parallel lines with
 * gaps in them. It is also the only piece of ornament in the entire app, which
 * is what lets it be this literal without the rest of the UI having to match.
 *
 * SVG rather than a grid of divs so it scales, prints and screenshots cleanly,
 * and so the whole thing is one element for the shadow in `.wordmark`.
 */

const GLYPHS: Record<string, string[]> = {
  S: ["01110", "10001", "10000", "01110", "00001", "10001", "01110"],
  W: ["10001", "10001", "10001", "10101", "10101", "11011", "10001"],
  I: ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
  T: ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
  C: ["01110", "10001", "10000", "10000", "10000", "10001", "01110"],
  H: ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
  Y: ["10001", "10001", "01010", "00100", "00100", "00100", "00100"],
  A: ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
  R: ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
  D: ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
};

const COLS = 5;
const ROWS = 7;

export function Wordmark({ text = "SWITCHYARD", unit = 7, gap = 1 }: { text?: string; unit?: number; gap?: number }) {
  const letters = [...text.toUpperCase()].filter((c) => GLYPHS[c]);
  const letterWidth = COLS * (unit + gap) - gap;
  // A letter's worth of air between words is too much at this size; two cells
  // reads as a space without the wordmark falling apart into fragments.
  const stride = letterWidth + unit * 2;
  const width = letters.length * stride - unit * 2;
  const height = ROWS * (unit + gap) - gap;

  return (
    <svg
      className="wordmark"
      viewBox={`0 0 ${width} ${height}`}
      width={width}
      height={height}
      role="img"
      aria-label={text}
      style={{ height: "auto", maxWidth: "100%" }}
    >
      {letters.map((char, li) =>
        GLYPHS[char]!.flatMap((row, ri) =>
          [...row].map((cell, ci) =>
            cell === "1" ? (
              <rect
                key={`${li}-${ri}-${ci}`}
                x={li * stride + ci * (unit + gap)}
                y={ri * (unit + gap)}
                width={unit}
                height={unit}
                rx={1}
                fill="currentColor"
              />
            ) : null,
          ),
        ),
      )}
    </svg>
  );
}
