defmodule Ravix.Tracks.Transcript.Commands do
  @moduledoc """
  The slash commands an agent says it takes.

  An ACP agent advertises them with a `session/update` whose `sessionUpdate`
  is `available_commands_update`, and says it again whenever the list
  changes; the newest one is the list. `Managoat.ACP.Blocks` drops these,
  rightly, since they are nothing the agent said or did, so the composer's
  `/` menu reads them from the same event lines the transcript is built from.

  What comes back is bounded before it reaches a page: a runtime that
  advertises a thousand commands, a name with a space in it or a paragraph
  of description is the agent's business, not the menu's. A name that is not
  a plain word is dropped rather than repaired, because the name is what the
  person's message will say.
  """

  alias Managoat.ACP.Protocol
  alias Ravix.Tracks.Transcript.Event

  @max_commands 50
  @max_description 160
  @max_hint 80
  @name ~r/\A[A-Za-z0-9][A-Za-z0-9_:.\-]{0,63}\z/

  defmodule Command do
    @moduledoc "One command: its name without the slash, and what it says it does."

    @enforce_keys [:name]
    defstruct @enforce_keys ++ [description: nil, hint: nil]

    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t() | nil,
            hint: String.t() | nil
          }
  end

  @doc """
  The newest command list among `events`, oldest first, or `nil` when none of
  them carried one -- which is different from an agent that said it has none.
  """
  @spec latest([Event.t()]) :: [Command.t()] | nil
  def latest(events) do
    Enum.reduce(events, nil, fn event, found -> from_event(event) || found end)
  end

  @doc "The command list one event carries, or `nil` when it carries none."
  @spec from_event(Event.t()) :: [Command.t()] | nil
  def from_event(%Event{kind: :output, stream: :acp, data: data}) when is_binary(data) do
    data
    |> String.split("\n")
    |> Enum.reduce(nil, fn line, found -> from_line(line) || found end)
  end

  def from_event(_event), do: nil

  defp from_line(line) do
    # Cheap before JSON: nearly every line is a token of text.
    if String.contains?(line, "available_commands_update") do
      case Protocol.classify_line(line) do
        {:notification, "session/update", %{"update" => %{} = update}} -> from_update(update)
        _ -> nil
      end
    end
  end

  defp from_update(%{"sessionUpdate" => "available_commands_update"} = update) do
    update
    |> Map.get("availableCommands")
    |> List.wrap()
    |> Enum.flat_map(&command/1)
    |> Enum.uniq_by(& &1.name)
    |> Enum.take(@max_commands)
  end

  defp from_update(_update), do: nil

  defp command(%{"name" => name} = raw) when is_binary(name) do
    name = String.trim_leading(name, "/")

    if Regex.match?(@name, name) do
      [
        %Command{
          name: name,
          description: text(raw["description"], @max_description),
          hint: text(hint(raw["input"]), @max_hint)
        }
      ]
    else
      []
    end
  end

  defp command(_raw), do: []

  defp hint(%{"hint" => hint}), do: hint
  defp hint(_input), do: nil

  defp text(value, limit) when is_binary(value) do
    case value |> String.replace(~r/\s+/, " ") |> String.trim() do
      "" -> nil
      short -> String.slice(short, 0, limit)
    end
  end

  defp text(_value, _limit), do: nil
end
