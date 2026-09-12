defmodule Ravix.AnalyticsTest do
  @moduledoc """
  What Ravix actually sends PostHog (ADR 0004).

  `config/test.exs` runs the SDK in `test_mode`, which keeps captured events in
  memory and traces them back to the test that captured them through
  `NimbleOwnership` --- so these read back real events rather than asserting that
  a function was called, and they stay `async: true`.

  The privacy assertions here are the point of the file. Server-side capture
  makes it easy to send anything a context happens to be holding, and what must
  not travel --- a prompt body, a file path, a diff, a credential --- is the sort
  of thing that arrives in a property map by accident, one call site at a time.
  """
  use Ravix.DataCase, async: true

  alias Ravix.Analytics

  setup do
    user = insert_user(login: "octocat")
    %{user: user}
  end

  defp captured(event) do
    Enum.find(PostHog.Test.all_captured(), &match?(%{event: ^event}, &1))
  end

  describe "track/3" do
    test "captures the event against the user's id, not their login", %{user: user} do
      assert Analytics.track(user, :track_opened) == :ok

      assert %{distinct_id: distinct_id} = captured("track opened")

      assert distinct_id == user.id,
             "distinct_id must be the Ravix user id: a login is renameable, and a " <>
               "freed login can be taken by somebody else"
    end

    test "sets the GitHub login as a person property, and never an email", %{user: user} do
      Analytics.track(user, :signed_in)

      assert %{properties: properties} = captured("signed in")
      assert properties[:"$set"]["ravix.login"] == "octocat"
      assert properties[:"$set_once"]["ravix.created_at"]

      refute Enum.any?(Map.keys(properties[:"$set"]), &(to_string(&1) =~ "email"))
      refute inspect(properties) =~ "@"
    end

    test "passes the caller's own properties through", %{user: user} do
      Analytics.track(user, :prompt_sent, %{"ravix.prompt_length" => 42, "ravix.images" => 2})

      assert %{properties: properties} = captured("prompt sent")
      assert properties["ravix.prompt_length"] == 42
      assert properties["ravix.images"] == 2
    end

    test "a nil user captures nothing at all" do
      # An anonymous event would create a person in PostHog for nobody.
      assert Analytics.track(nil, :signed_in) == :ok
      refute captured("signed in")
    end

    test "an unknown event name raises rather than going quiet", %{user: user} do
      # The one thing in this module that raises. A typo must not become a funnel
      # step that silently never fires, and the only place that would ever be
      # noticed is the test of whoever introduced it.
      assert_raise KeyError, fn -> Analytics.track(user, :prompt_snet) end
    end

    test "a failure talking to PostHog is swallowed, not raised", %{user: user} do
      # The complementary case, and the reason the two are separated in `track/3`:
      # analytics that can break the request it is measuring is worse than no
      # analytics. A non-binary api_key makes the SDK's own call raise.
      previous = Application.get_env(:posthog, :api_key)

      try do
        Application.put_env(:posthog, :api_key, :not_a_string_at_all)
        assert Analytics.track(user, :signed_in) == :ok
      after
        Application.put_env(:posthog, :api_key, previous)
      end
    end
  end

  describe "what must never travel" do
    test "a credential handed in as a property is dropped", %{user: user} do
      sprites = %Ravix.Config.Sprites{token: "spr_live_secret", base_url: "https://x"}

      Analytics.track(user, :preview_started, %{
        "ravix.sprites" => sprites,
        "token" => "spr_live_secret",
        "ravix.track_id" => "trk_1"
      })

      assert %{properties: properties} = captured("preview started")
      assert properties["ravix.track_id"] == "trk_1"
      refute Map.has_key?(properties, "ravix.sprites")
      refute Map.has_key?(properties, "token")
      refute inspect(properties) =~ "spr_live_secret"
    end

    test "a struct or map property cannot get out", %{user: user} do
      Analytics.track(user, :track_closed, %{"a" => %{nested: 1}, "b" => [1, 2], "c" => self()})

      assert %{properties: properties} = captured("track closed")
      for key <- ~w(a b c), do: refute(Map.has_key?(properties, key))
    end
  end

  describe "repo/2 — the one place repository names are sent" do
    test "sends the repository full name and the branch" do
      track = %Ravix.Tracks.Track{branch: "octocat/fix-the-thing"}
      project = %Ravix.Projects.Project{repo_full_name: "octocat/private-repo"}

      assert Analytics.repo(track, project) == %{
               "ravix.repo" => "octocat/private-repo",
               "ravix.branch" => "octocat/fix-the-thing"
             }
    end

    test "omits what is absent rather than sending nil" do
      assert Analytics.repo(nil, nil) == %{}
      assert Analytics.repo(%Ravix.Tracks.Track{branch: nil}, %Ravix.Projects.Project{}) == %{}
    end
  end

  describe "waited_ms/1" do
    test "measures from a timestamp to now" do
      from = DateTime.add(DateTime.utc_now(), -3, :second)
      assert %{"ravix.waited_ms" => waited} = Analytics.waited_ms(from)
      assert waited >= 3_000 and waited < 60_000
    end

    test "is empty for a missing timestamp" do
      assert Analytics.waited_ms(nil) == %{}
    end
  end
end
