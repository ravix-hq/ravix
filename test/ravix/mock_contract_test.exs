defmodule Ravix.MockContractTest do
  use ExUnit.Case, async: true

  alias Ravix.{Ids, Spec}

  @moduledoc """
  `shared/contract.ts` is a copy, and this is what keeps it honest.

  The mock runs under bun and cannot ask Elixir where a worktree lives, so
  four values are written out for it a second time. A second copy nobody
  checks is how the mock ends up agreeing with a version of ravix that no
  longer exists, which is worse than no mock: it fails in development for a
  reason production does not have. So the copy is read back here and held to
  the modules that own it.
  """

  @contract Path.expand("../../shared/contract.ts", __DIR__)
  @external_resource @contract

  setup_all do
    %{source: File.read!(@contract)}
  end

  test "the mock's paths are the ones the app mints", %{source: source} do
    assert string_const(source, "WORKSPACE_ROOT") == Ids.workspace_root()
    assert string_const(source, "WORK_ROOT") == Ids.work_root()
    assert string_const(source, "RECEIPT_PATH") == Spec.receipt_path()
  end

  test "the mock parses a channel id with the app's own pattern", %{source: source} do
    assert regex_const(source, "CHANNEL_PATTERN") == Regex.source(Ids.channel_pattern())
  end

  test "nothing has crept back into the shared directory" do
    assert Path.wildcard(Path.expand("../../shared/*", __DIR__)) == [@contract],
           "shared/ is the mock's copy of four values and nothing else; " <>
             "anything the app needs belongs in lib/."
  end

  defp string_const(source, name) do
    [_, value] = Regex.run(~r/export const #{name} = "([^"]*)"/, source)
    value
  end

  defp regex_const(source, name) do
    [_, value] = Regex.run(~r|export const #{name} = /(.*)/;|, source)
    value
  end
end
