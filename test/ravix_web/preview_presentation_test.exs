defmodule RavixWeb.PreviewPresentationTest do
  use ExUnit.Case, async: true
  alias RavixWeb.PreviewPresentation, as: Presentation

  test "actual supervisor events and plain app logs render as readable text" do
    events = [
      ~s({"type":"started","timestamp":1790455143365}),
      Jason.encode!(%{type: "stdout", data: "app booting\n", timestamp: 1_790_455_143_632}),
      ~s({"type":"complete","log_files":{"combined":"/service.log"}}),
      ~s({"message":"not ready","stream":"stderr"}),
      ~s({"message":"<script>unsafe</script>"}),
      ~s({"type":"unknown","data":42}),
      "partial {",
      "2026-09-26T20:39:11.640Z [stdout] app listening"
    ]

    assert Presentation.logs(Enum.join(events, "\n")) ==
             "Service started.\n[stdout] app booting\nService startup request completed.\n" <>
               "[stderr] not ready\n<script>unsafe</script>\n" <>
               ~s({"type":"unknown","data":42}) <>
               "\npartial {\n2026-09-26T20:39:11.640Z [stdout] app listening"

    assert Presentation.logs(nil) == ""
  end

  test "log tails are bounded and do not split UTF-8 characters" do
    text = String.duplicate("€", 20_000)
    result = Presentation.logs(text)
    assert String.valid?(result)
    assert byte_size(result) <= 32_000
    assert String.ends_with?(text, result)
  end

  test "startup copy names the configured readiness path" do
    assert Presentation.loading_label(nil) == "Starting the process…"
    assert Presentation.loading_label(%{readiness_path: "/health"}) =~ "answer on /health."
  end
end
