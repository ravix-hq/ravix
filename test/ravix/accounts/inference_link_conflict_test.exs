defmodule Ravix.Accounts.InferenceLinkConflictTest do
  @moduledoc """
  The one ChatGPT refusal that has to read the account before it can say
  anything: `account_already_linked`.

  Ravix is one Fountain account for everybody, so the grant holding the ChatGPT
  account is usually this deployment's own --- often the person's own, from a
  login they have forgotten. These tests are about telling those apart from
  Fountain's real refusal shape, offering only the repair the person may have,
  and never touching another Ravix login's subscription.
  """
  use Ravix.DataCase, async: true
  use Mimic

  alias Ravix.Accounts.Inference
  alias Ravix.Accounts.Inference.Conflict
  alias Ravix.Accounts.User
  alias Ravix.Fountain.FakeTransport
  alias Ravix.Repo

  @sets "/api/account/inference-credential-sets"
  @chatgpt "/api/account/chatgpt-subscriptions"

  defp fountain(expectations) do
    client = FakeTransport.client(expectations)
    stub(Ravix.Fountain, :client, fn -> client end)
    client
  end

  defp requests(client), do: client |> FakeTransport.calls() |> Enum.map(&{&1.method, &1.path})

  defp body_of(client, method, path) do
    client
    |> FakeTransport.calls()
    |> Enum.find(&(&1.method == method and &1.path == path))
    |> Map.get(:body)
  end

  defp link(set_id), do: %Inference.Link{attempt_id: "att-1", set_id: set_id, poll_interval: 5}

  # Fountain's refusal on the attempt, flat: `failure_reason` beside
  # `conflict_grant_id`, which is what a current deployment answers.
  defp refused_flat(grant_id) do
    {%{method: "GET", path: "#{@chatgpt}/attempts/att-1"},
     {200, [],
      %{
        data: %{
          id: "att-1",
          state: "failed",
          failure_reason: "account_already_linked",
          conflict_grant_id: grant_id
        }
      }}}
  end

  # The same refusal nested under `failure`, as an older one answers.
  defp refused_nested(grant_id) do
    {%{method: "GET", path: "#{@chatgpt}/attempts/att-1"},
     {200, [],
      %{
        data: %{
          id: "att-1",
          state: "failed",
          failure: %{reason: "account_already_linked", conflict_grant_id: grant_id}
        }
      }}}
  end

  defp grants(list), do: {%{method: "GET", path: @chatgpt}, {200, [], %{data: list}}}
  defp sets(list), do: {%{method: "GET", path: @sets}, {200, [], %{data: list}}}

  defp attempt(id, fields),
    do:
      Map.merge(
        %{
          id: id,
          state: "pending",
          user_code: "WXYZ-1234",
          verification_url: "https://auth.openai.com/codex/device",
          poll_interval: 5,
          expires_at: "2026-09-28T12:15:00Z"
        },
        fields
      )

  describe "poll_link/2 with a ChatGPT account already linked here" do
    test "the person's own grant, by name, is offered as a reconnect" do
      me = insert_user(credential_set_id: "set-me")

      fountain([
        refused_flat("g-mine"),
        grants([%{id: "g-mine", name: "ravix:#{me.id}", status: "disconnected"}]),
        sets([%{id: "set-me", name: "ravix:#{me.id}", chatgpt_grant_id: nil}])
      ])

      assert {:error, {:link_conflict, conflict}} = Inference.poll_link(me, link("set-me"))

      assert %Conflict{resolution: :reconnect, grant_id: "g-mine", message: message} = conflict
      assert message =~ "under your own earlier sign-in"
      assert message =~ "Reconnect it"
      assert %User{agent: nil} = Repo.get!(User, me.id)
    end

    test "the person's own grant, named something else, is still theirs: their set names it" do
      me = insert_user(credential_set_id: "set-me")

      fountain([
        refused_nested("g-old"),
        grants([%{id: "g-old", name: "codex-laptop", status: "active"}]),
        sets([%{id: "set-me", name: "ravix:#{me.id}", chatgpt_grant_id: "g-old"}])
      ])

      assert {:error, {:link_conflict, %Conflict{resolution: :reconnect, grant_id: "g-old"}}} =
               Inference.poll_link(me, link("set-me"))
    end

    test "a disconnected grant nothing names and nobody is named on is offered for removal" do
      me = insert_user(credential_set_id: "set-me")

      fountain([
        refused_flat("g-stray"),
        grants([
          %{id: "g-stray", name: nil, status: "disconnected"},
          %{id: "g-mine", name: "ravix:#{me.id}", status: "active"}
        ]),
        sets([%{id: "set-me", name: "ravix:#{me.id}", chatgpt_grant_id: "g-mine"}])
      ])

      assert {:error, {:link_conflict, conflict}} = Inference.poll_link(me, link("set-me"))
      assert %Conflict{resolution: :remove, grant_id: "g-stray", message: message} = conflict
      assert message =~ "old connection that nothing is using"
      assert message =~ "Remove it and sign in again"
    end

    test "another Ravix login's grant says so, and never says whose" do
      me = insert_user(credential_set_id: "set-me")
      them = insert_user(credential_set_id: "set-them")

      fountain([
        refused_flat("g-theirs"),
        grants([%{id: "g-theirs", name: "ravix:#{them.id}", status: "active"}]),
        sets([%{id: "set-them", name: "ravix:#{them.id}", chatgpt_grant_id: "g-theirs"}])
      ])

      assert {:error, {:link_conflict, conflict}} = Inference.poll_link(me, link("set-me"))
      assert %Conflict{resolution: :elsewhere, grant_id: nil, message: message} = conflict
      assert message =~ "already connected to a different Ravix login"
      assert message =~ "ask whoever runs this Ravix to move it"
      refute message =~ them.id
      refute message =~ "ravix:"
      refute message =~ "g-theirs"
    end

    test "another login's grant is still theirs when disconnected and named by no set" do
      me = insert_user(credential_set_id: "set-me")
      them = insert_user()

      fountain([
        refused_flat("g-theirs"),
        grants([%{id: "g-theirs", name: "ravix:#{them.id}", status: "disconnected"}]),
        sets([%{id: "set-me", name: "ravix:#{me.id}", chatgpt_grant_id: nil}])
      ])

      assert {:error, {:link_conflict, %Conflict{resolution: :elsewhere, grant_id: nil}}} =
               Inference.poll_link(me, link("set-me"))
    end

    test "a grant some other set is spending, and an unnamed live one, are not removable" do
      me = insert_user(credential_set_id: "set-me")

      for grant <- [
            %{id: "g-x", name: "shared", status: "disconnected"},
            %{id: "g-x", name: nil, status: "active"}
          ] do
        naming =
          if grant.status == "disconnected",
            do: [%{id: "set-other", name: "team", chatgpt_grant_id: "g-x"}],
            else: [%{id: "set-me", name: "ravix:#{me.id}", chatgpt_grant_id: nil}]

        fountain([refused_flat("g-x"), grants([grant]), sets(naming)])

        assert {:error, {:link_conflict, %Conflict{resolution: :elsewhere}}} =
                 Inference.poll_link(me, link("set-me"))
      end
    end

    test "a refusal Fountain would not pin to a grant claims nothing about whose it is" do
      me = insert_user(credential_set_id: "set-me")
      read = %{method: "GET", path: "#{@chatgpt}/attempts/att-1"}

      # No conflict grant id at all: nothing is read, because there is nothing
      # to look up.
      client =
        fountain([
          {read,
           {200, [],
            %{data: %{id: "att-1", state: "failed", failure_reason: "account_already_linked"}}}}
        ])

      assert {:error, {:link_conflict, conflict}} = Inference.poll_link(me, link("set-me"))
      assert %Conflict{resolution: :unknown, grant_id: nil, message: message} = conflict
      assert message =~ "can only be connected once"
      refute message =~ "different Ravix login"
      assert requests(client) == [{"GET", "#{@chatgpt}/attempts/att-1"}]

      # An id the account does not list.
      fountain([refused_flat("g-gone"), grants([]), sets([])])

      assert {:error, {:link_conflict, %Conflict{resolution: :unknown}}} =
               Inference.poll_link(me, link("set-me"))

      # A Fountain that will not describe its own account is not guessed at.
      fountain([
        refused_flat("g-x"),
        {%{method: "GET", path: @chatgpt}, {500, [], %{error: "down"}}}
      ])

      assert {:error, {:link_conflict, %Conflict{resolution: :unknown}}} =
               Inference.poll_link(me, link("set-me"))

      fountain([
        refused_flat("g-x"),
        grants([%{id: "g-x", name: nil, status: "disconnected"}]),
        {%{method: "GET", path: @sets}, {500, [], %{error: "down"}}}
      ])

      assert {:error, {:link_conflict, %Conflict{resolution: :unknown}}} =
               Inference.poll_link(me, link("set-me"))
    end

    test "a Fountain with no subscriptions route at all is read as holding none" do
      me = insert_user(credential_set_id: "set-me")

      fountain([
        refused_flat("g-x"),
        {%{method: "GET", path: @chatgpt}, {404, [], %{error: "not_found"}}},
        {%{method: "GET", path: @sets}, {404, [], %{error: "not_found"}}}
      ])

      assert {:error, {:link_conflict, %Conflict{resolution: :unknown}}} =
               Inference.poll_link(me, link("set-me"))
    end
  end

  describe "resolve_conflict/2" do
    test "reconnecting starts an attempt against that grant and hands back a fresh code" do
      me = insert_user(credential_set_id: "set-me")

      client =
        fountain([
          grants([%{id: "g-mine", name: "ravix:#{me.id}", status: "disconnected"}]),
          sets([%{id: "set-me", name: "ravix:#{me.id}", chatgpt_grant_id: nil}]),
          {%{method: "POST", path: "#{@chatgpt}/attempts", body: %{grant_id: "g-mine"}},
           {201, [], %{data: attempt("att-2", %{})}}}
        ])

      conflict = %Conflict{resolution: :reconnect, grant_id: "g-mine", message: "m"}

      assert {:ok, %Inference.Link{attempt_id: "att-2", set_id: "set-me", user_code: "WXYZ-1234"}} =
               Inference.resolve_conflict(me, conflict)

      refute {"DELETE", "#{@chatgpt}/g-mine"} in requests(client)
    end

    test "removing deletes the stray grant and then starts an ordinary sign-in" do
      me = insert_user(credential_set_id: "set-me")
      stray = [%{id: "g-stray", name: nil, status: "disconnected"}]

      client =
        fountain([
          grants(stray),
          sets([%{id: "set-me", name: "ravix:#{me.id}", chatgpt_grant_id: nil}]),
          {%{method: "DELETE", path: "#{@chatgpt}/g-stray"}, {204, [], nil}},
          grants([]),
          {%{method: "POST", path: "#{@chatgpt}/attempts", body: %{name: "ravix:#{me.id}"}},
           {201, [], %{data: attempt("att-3", %{})}}}
        ])

      conflict = %Conflict{resolution: :remove, grant_id: "g-stray", message: "m"}

      assert {:ok, %Inference.Link{attempt_id: "att-3", set_id: "set-me"}} =
               Inference.resolve_conflict(me, conflict)

      assert {"DELETE", "#{@chatgpt}/g-stray"} in requests(client)
    end

    test "a grant already gone is the outcome wanted, and the sign-in still starts" do
      me = insert_user(credential_set_id: "set-me")

      fountain([
        grants([%{id: "g-stray", name: nil, status: "disconnected"}]),
        sets([]),
        {%{method: "DELETE", path: "#{@chatgpt}/g-stray"}, {404, [], %{error: "not_found"}}},
        grants([]),
        {%{method: "POST", path: "#{@chatgpt}/attempts"},
         {201, [], %{data: attempt("att-4", %{})}}}
      ])

      assert {:ok, %Inference.Link{attempt_id: "att-4"}} =
               Inference.resolve_conflict(me, %Conflict{
                 resolution: :remove,
                 grant_id: "g-stray",
                 message: "m"
               })
    end

    test "a conflict that has become somebody else's is refused, and nothing is touched" do
      me = insert_user(credential_set_id: "set-me")
      them = insert_user()

      client =
        fountain([
          grants([%{id: "g-x", name: "ravix:#{them.id}", status: "disconnected"}]),
          sets([])
        ])

      # The page's copy said it was nobody's. It is not, any more.
      assert {:error, {:unprocessable, "link_failed", message}} =
               Inference.resolve_conflict(me, %Conflict{
                 resolution: :remove,
                 grant_id: "g-x",
                 message: "stale"
               })

      assert message =~ "already connected to a different Ravix login"
      refute message =~ them.id
      assert requests(client) == [{"GET", @chatgpt}, {"GET", @sets}]
    end

    test "a stale reconnect is refused rather than reconnecting a stranger's subscription" do
      me = insert_user(credential_set_id: "set-me")
      them = insert_user()

      client =
        fountain([
          grants([%{id: "g-x", name: "ravix:#{them.id}", status: "active"}]),
          sets([%{id: "set-them", name: "ravix:#{them.id}", chatgpt_grant_id: "g-x"}])
        ])

      assert {:error, {:unprocessable, "link_failed", _message}} =
               Inference.resolve_conflict(me, %Conflict{
                 resolution: :reconnect,
                 grant_id: "g-x",
                 message: "stale"
               })

      refute {"POST", "#{@chatgpt}/attempts"} in requests(client)
    end

    test "a refusal with no repair has nothing to do and asks Fountain nothing" do
      me = insert_user(credential_set_id: "set-me")
      reject(&Ravix.Fountain.client/0)

      for resolution <- [:elsewhere, :unknown] do
        conflict = %Conflict{resolution: resolution, message: "nothing doing"}

        assert {:error, {:unprocessable, "link_failed", "nothing doing"}} =
                 Inference.resolve_conflict(me, conflict)
      end

      # A resolution that acts on a grant, with no grant, is the same refusal.
      assert {:error, {:unprocessable, "link_failed", "m"}} =
               Inference.resolve_conflict(me, %Conflict{resolution: :remove, message: "m"})
    end

    test "somebody with no set yet gets one before the sign-in starts" do
      me = insert_user()

      client =
        fountain([
          {%{method: "GET", path: @sets}, {200, [], %{data: [%{id: "house", is_default: true}]}}},
          {%{method: "POST", path: @sets, body: %{name: "ravix:#{me.id}"}},
           {201, [], %{data: %{id: "set-new", name: "ravix:#{me.id}"}}}},
          grants([%{id: "g-stray", name: nil, status: "disconnected"}]),
          sets([]),
          {%{method: "DELETE", path: "#{@chatgpt}/g-stray"}, {204, [], nil}},
          grants([]),
          {%{method: "POST", path: "#{@chatgpt}/attempts"},
           {201, [], %{data: attempt("att-5", %{})}}}
        ])

      assert {:ok, %Inference.Link{set_id: "set-new"}} =
               Inference.resolve_conflict(me, %Conflict{
                 resolution: :remove,
                 grant_id: "g-stray",
                 message: "m"
               })

      assert body_of(client, "POST", @sets) == %{"name" => "ravix:#{me.id}"}
    end
  end
end
