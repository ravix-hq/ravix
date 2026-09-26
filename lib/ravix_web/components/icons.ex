defmodule RavixWeb.Icons do
  @moduledoc """
  The icon set, inline.

  A dependency would be a megabyte of tree-shaken SVG for the thirty glyphs
  this app actually draws, and every one of them here is a 24-grid stroke
  path at the same weight, which is what makes a row of them read as a set
  rather than as a collection. `currentColor` throughout, so an icon inherits
  the state of whatever it sits in and nothing has to be re-coloured per
  theme. The paths are the SPA's (`src/lib/icons.tsx`), unchanged.

      <.icon name="machine" />
      <.icon name="chevron" size={13} open={@open} />
      <.icon name="github" size={16} class="ico" />

  `RavixWeb.CoreComponents.icon/1` is the same component, re-exported so the
  `<.icon>` every template already has in scope draws from this set. Import
  one or the other, never both.
  """
  use Phoenix.Component

  # Every glyph but GitHub's: a 24-grid, stroked. GitHub's own mark is filled
  # rather than stroked, and deliberately: a "Sign in with GitHub" button
  # whose mark is a reinterpretation reads as a phishing page. Third-party
  # marks are the one place consistency loses.
  @glyphs %{
    "code" => ~S(<path d="m8 6-6 6 6 6m8-12 6 6-6 6M14 4l-4 16" />),
    "document" => ~S(<path d="M14 3H5v18h14V8zM14 3v5h5M8 12h8M8 16h6" />),
    "home" => ~S(<path d="M3 10.5 12 3l9 7.5" /><path d="M5 9.5V21h14V9.5" />),
    "plus" => ~S(<path d="M12 5v14M5 12h14" />),
    "search" => ~S(<circle cx="11" cy="11" r="7" /><path d="m20 20-3.6-3.6" />),
    "folder" =>
      ~S(<path d="M3 7.5A1.5 1.5 0 0 1 4.5 6h4l2 2.5h7A1.5 1.5 0 0 1 19 10v7.5A1.5 1.5 0 0 1 17.5 19h-13A1.5 1.5 0 0 1 3 17.5z" />),
    "folder-plus" =>
      ~S(<path d="M3 7.5A1.5 1.5 0 0 1 4.5 6h4l2 2.5h7A1.5 1.5 0 0 1 19 10v7.5A1.5 1.5 0 0 1 17.5 19h-13A1.5 1.5 0 0 1 3 17.5z" /><path d="M11 13.5h4M13 11.5v4" />),
    "file" =>
      ~S(<path d="M14 3H7a1.5 1.5 0 0 0-1.5 1.5v15A1.5 1.5 0 0 0 7 21h10a1.5 1.5 0 0 0 1.5-1.5V7.5z" /><path d="M14 3v4.5h4.5" />),
    "globe" =>
      ~S(<circle cx="12" cy="12" r="9" /><path d="M3 12h18M12 3c2.5 2.7 2.5 15.3 0 18M12 3c-2.5 2.7-2.5 15.3 0 18" />),
    "branch" =>
      ~S(<circle cx="7" cy="5.5" r="2.2" /><circle cx="7" cy="18.5" r="2.2" /><circle cx="17" cy="9" r="2.2" /><path d="M7 7.7v8.6" /><path d="M17 11.2c0 3.4-3 4.1-6 5" />),
    "pull" =>
      ~S(<circle cx="6.5" cy="5.5" r="2.2" /><circle cx="6.5" cy="18.5" r="2.2" /><circle cx="17.5" cy="18.5" r="2.2" /><path d="M6.5 7.7v8.6" /><path d="M17.5 16.3V11a3 3 0 0 0-3-3h-3" /><path d="m13.5 5.8-2 2.2 2 2.2" />),
    "issue" => ~S(<circle cx="12" cy="12" r="8.5" /><circle cx="12" cy="12" r="2.6" />),
    "terminal" =>
      ~S(<rect x="3" y="4.5" width="18" height="15" rx="2" /><path d="m7.5 10 2.5 2-2.5 2M13 14h3.5" />),
    "play" => ~S(<path d="M8 5.5v13l11-6.5z" />),
    "wrench" =>
      ~S(<path d="M15.5 3.5a5 5 0 0 0-5.9 6.4L3.6 15.9a2 2 0 0 0 2.8 2.8l6-6a5 5 0 0 0 6.4-5.9L16 9.6l-2.1-.5-.5-2.1z" />),
    "check" => ~S(<path d="m5 12.5 4.5 4.5L19 7" />),
    "copy" =>
      ~S(<rect x="8.5" y="8.5" width="12" height="12" rx="2" /><path d="M15.5 8.5V5.5a2 2 0 0 0-2-2h-8a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h3" />),
    "x" => ~S(<path d="M6 6l12 12M18 6 6 18" />),
    "more" =>
      ~S(<circle cx="5.5" cy="12" r="1.4" fill="currentColor" stroke="none" /><circle cx="12" cy="12" r="1.4" fill="currentColor" stroke="none" /><circle cx="18.5" cy="12" r="1.4" fill="currentColor" stroke="none" />),
    "dot" => ~S(<circle cx="12" cy="12" r="4" fill="currentColor" stroke="none" />),
    "picture" =>
      ~S(<rect x="3" y="4.5" width="18" height="15" rx="2" /><circle cx="8.5" cy="10" r="1.5" /><path d="m3.5 17.5 4.5-4.5 3.5 3.5 3-2.5 6 5" />),
    "pencil" =>
      ~S(<path d="M4.5 19.5h4L19.5 8.5a2.1 2.1 0 0 0-3-3L5.5 16.5z" /><path d="m14.5 6.5 3 3" />),
    "clock" => ~S(<circle cx="12" cy="12" r="8.5" /><path d="M12 7.5V12l3 1.8" />),
    "chevron" => ~S(<path d="m9.5 6 6 6-6 6" />),
    # Three quarters of a ring, drawn open at the top so that it reads as
    # turning once something turns it. A circle that is missing a piece is
    # legible as activity even standing still, which is what a reader with
    # reduced motion on gets.
    "spinner" => ~S(<path d="M12 3.5a8.5 8.5 0 1 1-8.5 8.5" />),
    "arrow-up" => ~S(<path d="M12 19V5M6 11l6-6 6 6" />),
    "external" =>
      ~S(<path d="M14 4h6v6" /><path d="M20 4 10.5 13.5" /><path d="M18 14.5V19a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 4 19V8a1.5 1.5 0 0 1 1.5-1.5H10" />),
    "settings" =>
      ~S(<circle cx="12" cy="12" r="3" /><path d="M19.4 14.5a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-1.8-.3 1.6 1.6 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.6 1.6 0 0 0-1-1.5 1.6 1.6 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.6 1.6 0 0 0 .3-1.8 1.6 1.6 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.6 1.6 0 0 0 1.5-1 1.6 1.6 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.6 1.6 0 0 0 1.8.3H9a1.6 1.6 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.6 1.6 0 0 0 1 1.5 1.6 1.6 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.6 1.6 0 0 0-.3 1.8V9a1.6 1.6 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.6 1.6 0 0 0-1.5 1z" />),
    "sparkle" => ~S(<path d="M12 3.5 13.7 9l5.5 1.7-5.5 1.8L12 18l-1.7-5.5L4.8 10.7 10.3 9z" />),
    "info" => ~S(<circle cx="12" cy="12" r="8.5" /><path d="M12 11.5V16M12 8.2v.1" />),
    "machine" =>
      ~S(<rect x="3" y="5" width="18" height="11" rx="2" /><path d="M8.5 20h7M12 16v4" />),
    # A person with a plus: the invitation that has not happened yet.
    "add-person" =>
      ~S(<circle cx="9.5" cy="8" r="3.5" /><path d="M3.5 20a6 6 0 0 1 12 0" /><path d="M18.5 7.5v5M21 10h-5" />)
  }

  @github ~S(<path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8" />)

  @names Map.keys(@glyphs) |> Enum.concat(["github"]) |> Enum.sort()

  @doc "Every name `icon/1` accepts."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc """
  One icon from the set, by name.

  `size` is the rendered width and height in pixels (the SPA's default of
  15). `open` rotates a chevron a quarter turn, for a disclosure that is
  open. Anything else in `rest` lands on the `<svg>`.
  """
  attr :name, :string, required: true, values: @names
  attr :size, :integer, default: 15
  attr :class, :any, default: nil
  attr :open, :boolean, default: false, doc: "chevron only: pointing down rather than right"
  attr :rest, :global

  def icon(%{name: "github"} = assigns) do
    assigns = assign(assigns, :body, @github)

    ~H"""
    <svg
      width={@size}
      height={@size}
      viewBox="0 0 16 16"
      fill="currentColor"
      class={@class}
      aria-hidden="true"
      focusable="false"
      {@rest}
    >
      {Phoenix.HTML.raw(@body)}
    </svg>
    """
  end

  def icon(assigns) do
    assigns =
      assigns
      |> assign(:body, Map.fetch!(@glyphs, assigns.name))
      |> assign(:style, chevron_style(assigns))

    ~H"""
    <svg
      width={@size}
      height={@size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.75"
      stroke-linecap="round"
      stroke-linejoin="round"
      class={@class}
      style={@style}
      aria-hidden="true"
      focusable="false"
      {@rest}
    >
      {Phoenix.HTML.raw(@body)}
    </svg>
    """
  end

  defp chevron_style(%{name: "chevron", open: true}),
    do: "transition: transform 120ms ease; transform: rotate(90deg)"

  defp chevron_style(%{name: "chevron"}), do: "transition: transform 120ms ease"
  defp chevron_style(_), do: nil
end
