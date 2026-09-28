# MIX_ENV=test mix run --no-start bench/transcript.exs [--baseline] [--golden]
# Fixtures reconstruct captured ACP shapes; no private logs or provider latency.
alias Ravix.Tracks.{AgentFailure, Transcript}
alias Ravix.TranscriptFixture, as: Fixture

baseline? = "--baseline" in System.argv()

module =
  if baseline? do
    {source, 0} =
      System.cmd("git", [
        "show",
        "b3c25c78956916e72fdc6f97a3c7b41e0bbc88f3:lib/ravix/tracks/transcript.ex"
      ])

    source =
      source
      |> String.replace("defmodule Ravix.Tracks.Transcript do", "defmodule BaselineTranscript do")
      |> String.replace("defp empty_acc, do: Turn.empty_fold()", "defp empty_acc, do: []")

    Code.compile_string(source)
    BaselineTranscript
  else
    Transcript
  end

if "--golden" in System.argv() do
  true = baseline?

  expected =
    Map.new(Fixture.corpus(), fn {name, events} ->
      {name, events |> module.page("codex") |> Fixture.public()}
    end)

  File.write!(
    "test/fixtures/acp/transcript-golden.json",
    Jason.encode!(expected, pretty: true) <> "\n"
  )
else
  # Warm modules before measuring. Medians reduce scheduler/GC noise.
  module.page(Fixture.sample(200), "codex")

  for count <- [200, 1_000, 2_000, 4_000] do
    events = Fixture.sample(count)

    measure = fn label, fun ->
      samples =
        for _ <- 1..3 do
          :erlang.garbage_collect()
          {:reductions, before} = Process.info(self(), :reductions)
          {us, _} = :timer.tc(fun)
          {:reductions, after_count} = Process.info(self(), :reductions)
          {us, after_count - before}
        end

      {us, reductions} = samples |> Enum.sort() |> Enum.at(1)
      IO.puts("#{count}\t#{label}\t#{Float.round(us / 1000, 2)} ms\t#{reductions} reductions")
    end

    measure.("build", fn ->
      if baseline?, do: module.page(events, "codex"), else: Transcript.page(events, "codex", %{})
    end)

    page = module.page(events, "codex")
    measure.("images", fn -> Transcript.with_images(page, []) end)

    measure.("legacy failure rescan", fn ->
      Enum.each(page.turns, fn turn ->
        blocks = module.blocks_for_turn(Enum.reverse(turn.events), "codex")
        AgentFailure.detect(turn.events, "codex", blocks)
      end)
    end)
  end
end
