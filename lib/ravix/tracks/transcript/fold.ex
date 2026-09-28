defmodule Ravix.Tracks.Transcript.Fold do
  @moduledoc "Internal indexed block accumulator. Materialized only when a batch is complete."
  alias Ravix.Tracks.Transcript.Block

  defstruct order: [], blocks: %{}, tools: %{}, plan: nil, next: 0

  @type t :: %__MODULE__{
          order: [integer()],
          blocks: map(),
          tools: map(),
          plan: integer() | nil,
          next: non_neg_integer()
        }

  def push(acc, block) do
    key = acc.next

    tools =
      if match?(%Block.Tool{}, block), do: Map.put(acc.tools, block.id, key), else: acc.tools

    %{
      acc
      | order: [key | acc.order],
        blocks: Map.put(acc.blocks, key, block),
        tools: tools,
        next: key + 1
    }
  end

  def text(%{order: [key | rest]} = acc, module, body, ts) do
    case Map.fetch(acc.blocks, key) do
      :error ->
        text(%{acc | order: rest}, module, body, ts)

      {:ok, %^module{} = last} ->
        put(acc, key, %{last | body: [body | last.body], ended_at: ts || last.ended_at})

      _ ->
        push(acc, struct!(module, body: [body], started_at: ts, ended_at: ts))
    end
  end

  def text(acc, module, body, ts),
    do: push(acc, struct!(module, body: [body], started_at: ts, ended_at: ts))

  def result(acc, id, fun) do
    case Map.fetch(acc.tools, id) do
      {:ok, key} -> put(acc, key, fun.(Map.fetch!(acc.blocks, key)))
      :error -> acc
    end
  end

  def plan(acc, plan) do
    # Tombstones avoid walking the order for each replacement. Only the latest
    # plan remains in blocks, and materialization skips the removed positions.
    acc = %{acc | blocks: Map.delete(acc.blocks, acc.plan), plan: nil}
    if plan, do: %{push(acc, plan) | plan: acc.next}, else: acc
  end

  def blocks(acc) do
    Enum.reduce(acc.order, [], fn key, blocks ->
      case Map.fetch(acc.blocks, key) do
        {:ok, %module{body: chunks} = block} when module in [Block.Text, Block.Thinking] ->
          [%{block | body: chunks |> Enum.reverse() |> IO.iodata_to_binary()} | blocks]

        {:ok, block} ->
          [block | blocks]

        :error ->
          blocks
      end
    end)
  end

  defp put(acc, key, block), do: %{acc | blocks: Map.put(acc.blocks, key, block)}
end
