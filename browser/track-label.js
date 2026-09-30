// How the app says a track still titled with its branch (`Track.label/1`,
// RAV-83): the name after `ravix/` with its hyphens as spaces and a capital
// first letter. Enough for the plain names specs type; issue keys and
// acronyms are the Elixir tests' to cover.
export const spoken = name => name[0].toUpperCase() + name.slice(1).replaceAll('-', ' ');
