defmodule Ravix.Accounts.InferenceMoveTest do
  @moduledoc """
  The operator hand-over: a ChatGPT subscription linked under one Ravix login
  and needed on another.

  Neither person can do it --- the holder can only disconnect, and the other
  cannot link the same ChatGPT account while it is held --- so this is the one
  place in `Ravix.Accounts.Inference` that acts on somebody else's grant, and
  the only caller a deployment's own allowlist gates.

  Not async: who is an operator is application environment, which is global.
  """
  use Ravix.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Ravix.Accounts.{Inference, User}
  alias Ravix.Fountain.FakeTransport
  alias Ravix.Repo

  @sets "/api/account/inference-credential-sets"
  @chatgpt "/api/account/chatgpt-subscriptions"

  setup do
    previous = Application.fetch_env(:ravix, :admin_github_ids)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ravix, :admin_github_ids, value)
        :error -> Application.delete_env(:ravix, :admin_github_ids)
      end
    end)

    admin = insert_user(github_id: "90001")
    Application.put_env(:ravix, :admin_github_ids, ["90001"])
    %{admin: admin}
  end

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

  defp grants(list), do: {%{method: "GET", path: @chatgpt}, {200, [], %{data: list}}}
  defp sets(list), do: {%{method: "GET", path: @sets}, {200, [], %{data: list}}}

  # The suite runs at `:warning`, and the audit line is an `info`: the record
  # of an operator action is not a problem report. So the level is lifted for
  # as long as it takes to read one.
  defp capture_audit(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    capture_log(fun)
  end

  test "an operator moves the grant, the sets follow it, and both rows tell the truth", ctx do
    from =
      insert_user(agent: :codex, credential_kind: :subscription, credential_set_id: "set-from")

    to = insert_user(credential_set_id: "set-to")

    client =
      fountain([
        grants([
          %{id: "g-1", name: "ravix:#{from.id}", status: "active"},
          %{id: "g-old", name: "ravix:#{to.id}", status: "disconnected"}
        ]),
        sets([
          %{id: "set-from", name: "ravix:#{from.id}", chatgpt_grant_id: "g-1"},
          %{id: "set-to", name: "ravix:#{to.id}", chatgpt_grant_id: "g-old"}
        ]),
        {%{method: "PATCH", path: "#{@sets}/set-from", body: %{chatgpt_grant_id: nil}},
         {200, [], %{data: %{id: "set-from"}}}},
        {%{method: "PATCH", path: "#{@chatgpt}/g-old"},
         {200, [], %{data: %{id: "g-old", status: "disconnected"}}}},
        {%{method: "PATCH", path: "#{@chatgpt}/g-1", body: %{name: "ravix:#{to.id}"}},
         {200, [], %{data: %{id: "g-1", name: "ravix:#{to.id}", status: "active"}}}},
        {%{method: "PATCH", path: "#{@sets}/set-to", body: %{chatgpt_grant_id: "g-1"}},
         {200, [], %{data: %{id: "set-to"}}}}
      ])

    log =
      capture_audit(fn ->
        assert {:ok, %User{id: moved_id, agent: :codex, credential_kind: :subscription}} =
                 Inference.move_subscription(ctx.admin, from.id, to.id)

        assert moved_id == to.id
      end)

    # The grant the target already had is parked under a name nothing looks
    # up, not deleted: it is somebody's linked subscription, however stale.
    assert %{"name" => parked} = body_of(client, "PATCH", "#{@chatgpt}/g-old")
    assert String.starts_with?(parked, "ravix:#{to.id}:replaced-")

    # The source stops claiming a subscription pays for Codex; its set is what
    # actually stopped, and the row follows.
    assert %User{agent: :codex, credential_kind: nil} = Repo.get!(User, from.id)
    assert %User{credential_set_id: "set-to"} = Repo.get!(User, to.id)

    # An operator action nobody can ask about afterwards is not one to have.
    assert log =~ "chatgpt subscription moved"
    assert log =~ "grant=g-1"
    assert log =~ "from_user=#{from.id}"
    assert log =~ "to_user=#{to.id}"
    assert log =~ "by_user=#{ctx.admin.id}"
  end

  test "a target with no set of their own gets one, and nothing else changes shape", ctx do
    from =
      insert_user(agent: :codex, credential_kind: :subscription, credential_set_id: "set-from")

    to = insert_user()

    client =
      fountain([
        {%{method: "GET", path: @sets}, {200, [], %{data: [%{id: "house", is_default: true}]}}},
        {%{method: "POST", path: @sets, body: %{name: "ravix:#{to.id}"}},
         {201, [], %{data: %{id: "set-new", name: "ravix:#{to.id}"}}}},
        grants([%{id: "g-1", name: "ravix:#{from.id}", status: "active"}]),
        sets([%{id: "set-from", name: "ravix:#{from.id}", chatgpt_grant_id: "g-1"}]),
        {%{method: "PATCH", path: "#{@sets}/set-from", body: %{chatgpt_grant_id: nil}},
         {200, [], %{data: %{id: "set-from"}}}},
        {%{method: "PATCH", path: "#{@chatgpt}/g-1", body: %{name: "ravix:#{to.id}"}},
         {200, [], %{data: %{id: "g-1"}}}},
        {%{method: "PATCH", path: "#{@sets}/set-new", body: %{chatgpt_grant_id: "g-1"}},
         {200, [], %{data: %{id: "set-new"}}}}
      ])

    capture_audit(fn ->
      assert {:ok, %User{credential_set_id: "set-new", agent: :codex}} =
               Inference.move_subscription(ctx.admin, from.id, to.id)
    end)

    # Nothing held the target's name, so nothing was parked.
    assert Enum.count(requests(client), &(elem(&1, 0) == "PATCH")) == 3
  end

  test "anybody who is not an operator is refused, and Fountain is never asked", ctx do
    from = insert_user(credential_set_id: "set-from")
    to = insert_user(credential_set_id: "set-to")
    reject(&Ravix.Fountain.client/0)

    for actor <- [from, to, insert_user()] do
      assert {:error, {:forbidden, message}} =
               Inference.move_subscription(actor, from.id, to.id)

      assert message =~ "Only an operator of this Ravix"
    end

    # Named by a login rather than a GitHub id is not named at all: a login is
    # renameable, and a freed one can be taken by somebody else.
    Application.put_env(:ravix, :admin_github_ids, [ctx.admin.login])
    assert {:error, {:forbidden, _}} = Inference.move_subscription(ctx.admin, from.id, to.id)

    Application.put_env(:ravix, :admin_github_ids, [])
    assert {:error, {:forbidden, _}} = Inference.move_subscription(ctx.admin, from.id, to.id)
  end

  test "moving to the same person, or to or from somebody unknown, is refused", ctx do
    from = insert_user(credential_set_id: "set-from")
    reject(&Ravix.Fountain.client/0)

    assert {:error, {:unprocessable, "same_person", message}} =
             Inference.move_subscription(ctx.admin, from.id, from.id)

    assert message =~ "already this person's"

    assert {:error, :not_found} = Inference.move_subscription(ctx.admin, from.id, "nobody")
    assert {:error, :not_found} = Inference.move_subscription(ctx.admin, "nobody", from.id)
  end

  test "a person with no subscription on this Ravix has none to move", ctx do
    from = insert_user()
    to = insert_user(credential_set_id: "set-to")

    fountain([grants([%{id: "g-else", name: "ravix:someone", status: "active"}])])

    assert {:error, {:unprocessable, "no_subscription", message}} =
             Inference.move_subscription(ctx.admin, from.id, to.id)

    assert message =~ "no ChatGPT subscription on this Ravix to move"
    assert %User{credential_set_id: "set-to", agent: nil} = Repo.get!(User, to.id)
  end

  test "a rename the machine service will not do stops the move and says so", ctx do
    from =
      insert_user(agent: :codex, credential_kind: :subscription, credential_set_id: "set-from")

    to = insert_user(credential_set_id: "set-to")

    fountain([
      grants([%{id: "g-1", name: "ravix:#{from.id}", status: "active"}]),
      sets([%{id: "set-from", name: "ravix:#{from.id}", chatgpt_grant_id: "g-1"}]),
      {%{method: "PATCH", path: "#{@sets}/set-from"}, {200, [], %{data: %{id: "set-from"}}}},
      {%{method: "PATCH", path: "#{@chatgpt}/g-1"}, {422, [], %{error: "validation_failed"}}}
    ])

    assert {:error, {:unprocessable, "no_subscription", message}} =
             Inference.move_subscription(ctx.admin, from.id, to.id)

    assert message =~ "could not be renamed"
    # Nothing was written here, so the rows still say what they said.
    assert %User{credential_kind: :subscription} = Repo.get!(User, from.id)
    assert %User{agent: nil} = Repo.get!(User, to.id)
  end

  test "a set the machine service will not point is said as the half-move it is", ctx do
    from =
      insert_user(agent: :codex, credential_kind: :subscription, credential_set_id: "set-from")

    to = insert_user(credential_set_id: "set-to")

    fountain([
      grants([%{id: "g-1", name: "ravix:#{from.id}", status: "active"}]),
      sets([%{id: "set-from", name: "ravix:#{from.id}", chatgpt_grant_id: "g-1"}]),
      {%{method: "PATCH", path: "#{@sets}/set-from"}, {200, [], %{data: %{id: "set-from"}}}},
      {%{method: "PATCH", path: "#{@chatgpt}/g-1"}, {200, [], %{data: %{id: "g-1"}}}},
      {%{method: "PATCH", path: "#{@sets}/set-to"}, {404, [], %{error: "not_found"}}}
    ])

    assert {:error, {:unprocessable, "no_subscription", message}} =
             Inference.move_subscription(ctx.admin, from.id, to.id)

    assert message =~ "now carries that person's name"
    assert message =~ "Run the move again"
  end

  test "named by id from a place with no signed-in person, and refused if nobody has it", ctx do
    from =
      insert_user(agent: :codex, credential_kind: :subscription, credential_set_id: "set-from")

    to = insert_user(credential_set_id: "set-to")

    fountain([
      grants([%{id: "g-1", name: "ravix:#{from.id}", status: "active"}]),
      sets([%{id: "set-from", name: "ravix:#{from.id}", chatgpt_grant_id: "g-1"}]),
      {%{method: "PATCH", path: "#{@sets}/set-from"}, {200, [], %{data: %{id: "set-from"}}}},
      {%{method: "PATCH", path: "#{@chatgpt}/g-1"}, {200, [], %{data: %{id: "g-1"}}}},
      {%{method: "PATCH", path: "#{@sets}/set-to"}, {200, [], %{data: %{id: "set-to"}}}}
    ])

    capture_audit(fn ->
      assert {:ok, %User{agent: :codex}} =
               Inference.move_subscription_as(ctx.admin.id, from.id, to.id)
    end)

    # An id nobody has is refused like anybody else who is not an operator: a
    # move has to be made in somebody's name.
    assert {:error, {:forbidden, message}} =
             Inference.move_subscription_as("ghost", from.id, to.id)

    assert message =~ "nobody to move a ChatGPT subscription as"
  end

  test "a machine service that cannot be read at all is passed on as it came", ctx do
    from = insert_user(credential_set_id: "set-from")
    to = insert_user(credential_set_id: "set-to")

    fountain([{%{method: "GET", path: @chatgpt}, {500, [], %{error: "down"}}}])

    assert {:error, %Ravix.Fountain.Error{status: 500}} =
             Inference.move_subscription(ctx.admin, from.id, to.id)
  end
end
