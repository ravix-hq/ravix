defmodule Ravix.Accounts.InferenceTest do
  use Ravix.DataCase, async: true
  use Mimic

  alias Ravix.Accounts
  alias Ravix.Accounts.{Inference, User}
  alias Ravix.Fountain.{Client, FakeTransport}
  alias Ravix.Repo

  @sets "/api/account/inference-credential-sets"

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

  defp put(set_id, provider, response \\ nil) do
    {%{method: "PUT", path: "#{@sets}/#{set_id}/credentials/#{provider}"},
     response || {200, [], %{data: %{provider: provider, set: true}}}}
  end

  defp house_default,
    do: %{id: "house", name: "ravix:house", is_default: true, providers: []}

  @chatgpt "/api/account/chatgpt-subscriptions"

  defp me_enabled(enabled?),
    do:
      {%{method: "GET", path: "/api/auth/me"},
       {200, [], %{data: %{id: "acct", chatgpt_subscriptions_enabled: enabled?}}}}

  defp attempt(id, fields) do
    Map.merge(
      %{
        id: id,
        kind: "link",
        name: nil,
        grant_id: nil,
        state: "pending",
        user_code: "ABCD-EFGH",
        verification_url: "https://auth.openai.com/codex/device",
        poll_interval: 5,
        expires_at: "2026-09-21T12:15:00Z",
        result_grant_id: nil,
        failure: nil
      },
      fields
    )
  end

  defp link(set_id, attempt_id \\ "att-1"),
    do: %Inference.Link{attempt_id: attempt_id, set_id: set_id, poll_interval: 5}

  describe "kinds/1" do
    test "both agents take a subscription or a key; only Codex's subscription is a sign-in rather than a paste" do
      assert Inference.kinds(:claude) == [:subscription, :api_key]
      assert Inference.kinds(:codex) == [:subscription, :api_key]
      assert Inference.pasted?(:claude, :subscription)
      assert Inference.pasted?(:codex, :api_key)
      refute Inference.pasted?(:codex, :subscription)
    end
  end

  describe "link_status/1" do
    test "reports Fountain's door, and a sign-in of this person's found again by name" do
      me = insert_user()

      fountain([
        me_enabled(true),
        {%{method: "GET", path: "#{@chatgpt}/attempts"},
         {200, [],
          %{
            data: [
              attempt("theirs", %{name: "ravix:somebody-else"}),
              attempt("mine", %{name: "ravix:#{me.id}", poll_interval: 3})
            ]
          }}},
        {%{method: "GET", path: @sets},
         {200, [], %{data: [house_default(), %{id: "set-me", name: "ravix:#{me.id}"}]}}}
      ])

      assert {:ok, %{enabled?: true, pending: %Inference.Link{} = link}} =
               Inference.link_status(me)

      assert %{attempt_id: "mine", set_id: "set-me", user_code: "ABCD-EFGH", poll_interval: 3} =
               link

      assert link.trusted?
    end

    test "a reconnect is found by the grant it is for, and a Fountain that cannot be asked is a closed door" do
      me = insert_user(agent: :codex, credential_kind: :subscription, credential_set_id: "set-me")

      fountain([
        {%{method: "GET", path: "/api/auth/me"}, {404, [], %{error: "not_found"}}},
        {%{method: "GET", path: "#{@chatgpt}/attempts"},
         {200, [], %{data: [attempt("re", %{kind: "reconnect", grant_id: "g-me"})]}}},
        {%{method: "GET", path: @chatgpt},
         {200, [], %{data: [%{id: "g-me", name: "ravix:#{me.id}", status: "disconnected"}]}}}
      ])

      assert {:ok,
              %{enabled?: false, pending: %Inference.Link{attempt_id: "re", set_id: "set-me"}}} =
               Inference.link_status(me)
    end

    test "nothing open is nothing, and a Fountain from before sign-ins is nothing open too" do
      me = insert_user()

      fountain([
        me_enabled(true),
        {%{method: "GET", path: "#{@chatgpt}/attempts"}, {404, [], %{error: "not_found"}}}
      ])

      assert {:ok, %{enabled?: true, pending: nil}} = Inference.link_status(me)
    end
  end

  describe "begin_link/1" do
    test "makes the person's set, then starts a sign-in named like it; nothing about them changes yet" do
      me = insert_user()

      client =
        fountain([
          {%{method: "GET", path: @sets}, {200, [], %{data: [house_default()]}}},
          {%{method: "POST", path: @sets, body: %{name: "ravix:#{me.id}"}},
           {201, [], %{data: %{id: "set-me"}}}},
          {%{method: "GET", path: @chatgpt}, {200, [], %{data: []}}},
          {%{method: "POST", path: "#{@chatgpt}/attempts", body: %{name: "ravix:#{me.id}"}},
           {201, [], %{data: attempt("att-1", %{name: "ravix:#{me.id}"})}}}
        ])

      assert {:ok, %Inference.Link{} = link} = Inference.begin_link(me)

      assert %{
               attempt_id: "att-1",
               set_id: "set-me",
               user_code: "ABCD-EFGH",
               verification_url: "https://auth.openai.com/codex/device",
               trusted?: true,
               poll_interval: 5
             } = link

      assert %User{agent: nil, credential_set_id: nil} = Repo.get!(User, me.id)
      assert [{"GET", _}, {"POST", _}, {"GET", _}, {"POST", _}] = requests(client)
    end

    test "somebody who already has a subscription here reconnects it rather than linking a second" do
      me = insert_user(agent: :codex, credential_kind: :subscription, credential_set_id: "set-me")

      client =
        fountain([
          {%{method: "GET", path: @chatgpt},
           {200, [], %{data: [%{id: "g-me", name: "ravix:#{me.id}", status: "disconnected"}]}}},
          {%{method: "POST", path: "#{@chatgpt}/attempts", body: %{grant_id: "g-me"}},
           {201, [], %{data: attempt("att-2", %{kind: "reconnect", grant_id: "g-me"})}}}
        ])

      assert {:ok, %Inference.Link{attempt_id: "att-2", set_id: "set-me"}} =
               Inference.begin_link(me)

      refute {"GET", @sets} in requests(client)
    end

    test "a page Fountain did not vouch for is shown as text, not followed" do
      me = insert_user(credential_set_id: "set-me")

      fountain([
        {%{method: "GET", path: @chatgpt}, {200, [], %{data: []}}},
        {%{method: "POST", path: "#{@chatgpt}/attempts"},
         {201, [],
          %{data: attempt("att-3", %{verification_url: "http://auth.openai.com.evil.example/x"})}}}
      ])

      assert {:ok, %Inference.Link{trusted?: false, verification_url: "http://" <> _}} =
               Inference.begin_link(me)
    end

    test "each of Fountain's refusals is said in words that say what to do" do
      me = insert_user(credential_set_id: "set-me")
      grants = {%{method: "GET", path: @chatgpt}, {200, [], %{data: []}}}
      start = %{method: "POST", path: "#{@chatgpt}/attempts"}

      refusals = [
        {{404, [], %{error: "chatgpt_subscriptions_not_enabled"}}, "not switched on"},
        {{409, [], %{error: "chatgpt_grant_limit_reached", count: 5, limit: 5}},
         "as many ChatGPT subscriptions"},
        {{409, [], %{error: "chatgpt_link_attempt_pending", attempt_id: "x"}}, "already open"},
        {{409, [], %{error: "chatgpt_link_attempts_exceeded"}},
         "Too many ChatGPT sign-ins are open"},
        {{429, [{"retry-after", "600"}], %{error: "chatgpt_link_attempts_rate_limited"}},
         "last hour"},
        {{502, [], %{error: "chatgpt_auth_unreachable"}}, "could not be reached"}
      ]

      for {response, words} <- refusals do
        fountain([grants, {start, response}])
        assert {:error, {:unavailable, message}} = Inference.begin_link(me)
        assert message =~ words
      end

      # A Fountain from before subscriptions has no list to read either.
      fountain([
        {%{method: "GET", path: @chatgpt}, {404, [], %{error: "not_found"}}},
        {start, {404, [], %{error: "not_found"}}}
      ])

      assert {:error, {:unavailable, message}} = Inference.begin_link(me)
      assert message =~ "not switched on"

      fountain([grants, {start, {500, [], %{error: "down"}}}])
      assert {:error, %Ravix.Fountain.Error{status: 500}} = Inference.begin_link(me)
    end
  end

  describe "poll_link/2" do
    test "pending is pending" do
      me = insert_user()

      fountain([
        {%{method: "GET", path: "#{@chatgpt}/attempts/att-1"},
         {200, [], %{data: attempt("att-1", %{})}}}
      ])

      assert {:ok, :pending} = Inference.poll_link(me, link("set-me"))
      assert %User{agent: nil} = Repo.get!(User, me.id)
    end

    test "approved: the grant is named on the set, which is the switch, and the choice is remembered" do
      me = insert_user()

      client =
        fountain([
          {%{method: "GET", path: "#{@chatgpt}/attempts/att-1"},
           {200, [],
            %{
              data:
                attempt("att-1", %{state: "completed", user_code: nil, result_grant_id: "g-1"})
            }}},
          {%{method: "PATCH", path: "#{@sets}/set-me", body: %{chatgpt_grant_id: "g-1"}},
           {200, [],
            %{
              data: %{
                id: "set-me",
                chatgpt_grant: %{id: "g-1", name: "ravix:x", status: "active"}
              }
            }}}
        ])

      assert {:ok,
              %User{agent: :codex, credential_kind: :subscription, credential_set_id: "set-me"}} =
               Inference.poll_link(me, link("set-me"))

      assert Inference.runtime(Repo.get!(User, me.id)) == "codex"
      assert [{"GET", _}, {"PATCH", _}] = requests(client)
    end

    test "approved by somebody who had a key for Codex: the key goes, or it would sit there unused" do
      me = insert_user(agent: :codex, credential_kind: :api_key, credential_set_id: "s")

      fountain([
        {%{method: "GET", path: "#{@chatgpt}/attempts/att-1"},
         {200, [], %{data: attempt("att-1", %{state: "completed", result_grant_id: "g-1"})}}},
        {%{method: "PATCH", path: "#{@sets}/s", body: %{chatgpt_grant_id: "g-1"}},
         {200, [], %{data: %{id: "s"}}}},
        {%{method: "DELETE", path: "#{@sets}/s/credentials/openai_api_key"}, {204, [], nil}}
      ])

      assert {:ok, %User{credential_kind: :subscription}} = Inference.poll_link(me, link("s"))
    end

    test "a reconnect names what is named already and deletes nothing" do
      me = insert_user(agent: :codex, credential_kind: :subscription, credential_set_id: "s")

      client =
        fountain([
          {%{method: "GET", path: "#{@chatgpt}/attempts/att-1"},
           {200, [], %{data: attempt("att-1", %{state: "completed", result_grant_id: "g-1"})}}},
          {%{method: "PATCH", path: "#{@sets}/s"}, {200, [], %{data: %{id: "s"}}}}
        ])

      assert {:ok, %User{}} = Inference.poll_link(me, link("s"))
      assert [{"GET", _}, {"PATCH", _}] = requests(client)
    end

    test "a sign-in that ended badly says how, in our words, and changes nothing" do
      me = insert_user()
      read = %{method: "GET", path: "#{@chatgpt}/attempts/att-1"}

      endings = [
        {%{
           state: "failed",
           failure: %{reason: "account_already_linked", grant_id: "g-9", grant: "ravix:other"}
         }, "already connected to somebody else"},
        {%{state: "failed", failure: %{reason: "invalid_sign_in"}}, "refused the code"},
        {%{state: "failed", failure: %{reason: "exchange_failed"}}, "did not complete"},
        {%{state: "failed", failure: %{reason: "internal_error"}}, "Fountain's side"},
        {%{state: "expired"}, "fifteen minutes"},
        {%{state: "cancelled"}, "cancelled"}
      ]

      for {fields, words} <- endings do
        fountain([{read, {200, [], %{data: attempt("att-1", fields)}}}])

        assert {:error, {:unprocessable, "link_failed", message}} =
                 Inference.poll_link(me, link("s"))

        assert message =~ words
        refute message =~ "ravix:other"
      end

      assert %User{agent: nil, credential_set_id: nil} = Repo.get!(User, me.id)
    end

    test "a subscription Fountain will not name, and a set that has gone, are said as that" do
      me = insert_user()
      done = {200, [], %{data: attempt("att-1", %{state: "completed", result_grant_id: "g-1"})}}
      read = %{method: "GET", path: "#{@chatgpt}/attempts/att-1"}
      name = %{method: "PATCH", path: "#{@sets}/s"}

      fountain([{read, done}, {name, {422, [], %{error: "validation_failed"}}}])
      assert {:error, {:unprocessable, "link_failed", _}} = Inference.poll_link(me, link("s"))

      fountain([{read, done}, {name, {404, [], %{error: "not_found"}}}])
      assert {:error, {:unavailable, message}} = Inference.poll_link(me, link("s"))
      assert message =~ "v0.17"

      fountain([{read, done}, {name, {500, [], %{error: "down"}}}])
      assert {:error, %Ravix.Fountain.Error{status: 500}} = Inference.poll_link(me, link("s"))
      assert %User{agent: nil} = Repo.get!(User, me.id)
    end
  end

  describe "cancel_link/2" do
    test "ends the sign-in; one that ended on its own already is left as it is" do
      me = insert_user()
      path = "#{@chatgpt}/attempts/att-1"

      fountain([
        {%{method: "DELETE", path: path},
         {200, [], %{data: attempt("att-1", %{state: "cancelled"})}}}
      ])

      assert :ok = Inference.cancel_link(me, link("s"))

      fountain([
        {%{method: "DELETE", path: path}, {409, [], %{error: "chatgpt_link_attempt_not_pending"}}}
      ])

      assert :ok = Inference.cancel_link(me, link("s"))

      fountain([{%{method: "DELETE", path: path}, {500, [], %{error: "down"}}}])
      assert {:error, %Ravix.Fountain.Error{status: 500}} = Inference.cancel_link(me, link("s"))
    end
  end

  describe "connect/2 for the first time" do
    test "makes the person's set, writes the token into it, and remembers only the ids" do
      me = insert_user()

      client =
        fountain([
          {%{method: "GET", path: @sets}, {200, [], %{data: [house_default()]}}},
          {%{method: "POST", path: @sets, body: %{name: "ravix:#{me.id}"}},
           {201, [], %{data: %{id: "set-me", name: "ravix:#{me.id}", providers: []}}}},
          put("set-me", "claude_code_oauth_token")
        ])

      assert {:ok, %User{} = connected} =
               Inference.connect(me, %{
                 agent: :claude,
                 kind: :subscription,
                 value: "  sk-ant-oat01-abc  "
               })

      assert %User{agent: :claude, credential_kind: :subscription, credential_set_id: "set-me"} =
               connected

      assert Inference.connected?(connected)
      assert Inference.runtime(connected) == "claude"

      # Trimmed, and sent nowhere but Fountain.
      assert body_of(client, "PUT", "#{@sets}/set-me/credentials/claude_code_oauth_token") ==
               %{"value" => "sk-ant-oat01-abc"}

      row = Repo.get!(User, me.id)
      refute inspect(Map.from_struct(row)) =~ "sk-ant-oat01-abc"
    end

    test "an account with no default gets an empty one of Ravix's first, so nobody pays for strangers" do
      me = insert_user()

      client =
        fountain([
          {%{method: "GET", path: @sets}, {200, [], %{data: []}}},
          {%{method: "POST", path: @sets, body: %{name: "ravix:house"}},
           {201, [], %{data: house_default()}}},
          {%{method: "POST", path: @sets, body: %{name: "ravix:#{me.id}"}},
           {201, [], %{data: %{id: "set-me"}}}},
          put("set-me", "openai_api_key")
        ])

      assert {:ok, %User{agent: :codex, credential_set_id: "set-me"}} =
               Inference.connect(me, %{agent: :codex, kind: :api_key, value: "sk-openai"})

      # Order is the point: Fountain makes the first set the account's default.
      assert [{"GET", @sets}, {"POST", @sets}, {"POST", @sets}, {"PUT", _}] = requests(client)
    end

    test "somebody else reserving the default at the same moment is not a failure" do
      me = insert_user()

      fountain([
        {%{method: "GET", path: @sets}, {200, [], %{data: []}}},
        {%{method: "POST", path: @sets, body: %{name: "ravix:house"}},
         {422, [], %{error: "validation_failed", errors: %{name: ["already names a set"]}}}},
        {%{method: "POST", path: @sets, body: %{name: "ravix:#{me.id}"}},
         {201, [], %{data: %{id: "set-me"}}}},
        put("set-me", "anthropic_api_key")
      ])

      assert {:ok, %User{credential_kind: :api_key}} =
               Inference.connect(me, %{agent: :claude, kind: :api_key, value: "sk-ant-api03-x"})
    end

    test "a set left behind by an attempt that failed half way is found, not made again" do
      me = insert_user()

      client =
        fountain([
          {%{method: "GET", path: @sets},
           {200, [],
            %{data: [house_default(), %{id: "orphan", name: "ravix:#{me.id}", providers: []}]}}},
          put("orphan", "claude_code_oauth_token")
        ])

      assert {:ok, %User{credential_set_id: "orphan"}} =
               Inference.connect(me, %{agent: :claude, kind: :subscription, value: "tok"})

      refute {"POST", @sets} in requests(client)
    end
  end

  describe "connect/2 again" do
    test "reuses the set, and removes the same agent's other kind so the choice is the truth" do
      me = insert_user(agent: :claude, credential_kind: :subscription, credential_set_id: "s")

      client =
        fountain([
          put("s", "anthropic_api_key"),
          {%{method: "DELETE", path: "#{@sets}/s/credentials/claude_code_oauth_token"},
           {204, [], nil}}
        ])

      assert {:ok, %User{agent: :claude, credential_kind: :api_key, credential_set_id: "s"}} =
               Inference.connect(me, %{agent: :claude, kind: :api_key, value: "sk-ant-api03-x"})

      refute {"GET", @sets} in requests(client)
    end

    test "switching agent leaves the other agent's credential for the projects still on it" do
      me = insert_user(agent: :claude, credential_kind: :subscription, credential_set_id: "s")
      client = fountain([put("s", "openai_api_key")])

      assert {:ok, %User{agent: :codex, credential_kind: :api_key}} =
               Inference.connect(me, %{agent: :codex, kind: :api_key, value: "sk-openai"})

      assert requests(client) == [{"PUT", "#{@sets}/s/credentials/openai_api_key"}]
    end

    test "choosing a key for Codex clears the subscription from the set, or the key would go unused" do
      me = insert_user(agent: :codex, credential_kind: :subscription, credential_set_id: "s")

      client =
        fountain([
          put("s", "openai_api_key"),
          {%{method: "PATCH", path: "#{@sets}/s", body: %{chatgpt_grant_id: nil}},
           {200, [], %{data: %{id: "s", chatgpt_grant: nil}}}}
        ])

      assert {:ok, %User{agent: :codex, credential_kind: :api_key}} =
               Inference.connect(me, %{agent: :codex, kind: :api_key, value: "sk-openai"})

      assert [{"PUT", _}, {"PATCH", _}] = requests(client)
    end

    test "replacing a token with a new one of the same kind deletes nothing" do
      me = insert_user(agent: :claude, credential_kind: :subscription, credential_set_id: "s")
      client = fountain([put("s", "claude_code_oauth_token")])

      assert {:ok, _} =
               Inference.connect(me, %{agent: :claude, kind: :subscription, value: "new"})

      assert [{"PUT", _}] = requests(client)
    end
  end

  describe "connect/2 refused" do
    test "a value the provider rejects lands on the field, in our words, and changes nothing" do
      me = insert_user()

      fountain([
        {%{method: "GET", path: @sets}, {200, [], %{data: [house_default()]}}},
        {%{method: "POST", path: @sets}, {201, [], %{data: %{id: "set-me"}}}},
        put(
          "set-me",
          "claude_code_oauth_token",
          {422, [], %{error: "the provider rejected sk-ant-WRONG (HTTP 401)", reason: "invalid"}}
        )
      ])

      assert {:error, {:unprocessable, "bad_credential", message}} =
               Inference.connect(me, %{agent: :claude, kind: :subscription, value: "sk-ant-WRONG"})

      assert message =~ "Anthropic did not accept that"
      # Fountain's reply is not repeated: it answers a request that carried the value.
      refute message =~ "sk-ant-WRONG"
      assert %User{agent: nil, credential_set_id: nil} = Repo.get!(User, me.id)
    end

    test "a provider that could not be reached is said as that, not as a bad key" do
      me = insert_user(agent: :codex, credential_kind: :api_key, credential_set_id: "s")
      fountain([put("s", "openai_api_key", {504, [], %{error: "timed out", reason: "timeout"}})])

      assert {:error, {:unavailable, message}} =
               Inference.connect(me, %{agent: :codex, kind: :api_key, value: "sk-openai"})

      assert message =~ "OpenAI could not be reached"
    end

    test "a Fountain from before credential sets says what to do about it" do
      fountain([{%{method: "GET", path: @sets}, {404, [], %{error: "not_found"}}}])

      assert {:error, {:unavailable, message}} =
               Inference.connect(insert_user(), %{agent: :claude, kind: :api_key, value: "k"})

      assert message =~ "v0.17"
    end

    test "nothing pasted, something far too long, and a pairing nobody offers never reach Fountain" do
      client = fountain([])
      me = insert_user()

      assert {:error, {:unprocessable, "no_credential", _}} =
               Inference.connect(me, %{agent: :claude, kind: :api_key, value: "   "})

      assert {:error, {:unprocessable, "bad_credential", _}} =
               Inference.connect(me, %{
                 agent: :claude,
                 kind: :api_key,
                 value: String.duplicate("k", 5000)
               })

      assert {:error, {:unprocessable, "bad_credential", _}} =
               Inference.connect(me, %{agent: :codex, kind: :subscription, value: "tok"})

      assert requests(client) == []
    end

    test "a Fountain failing at any step is passed on, and the person's row is left alone" do
      me = insert_user()
      sets_ok = {%{method: "GET", path: @sets}, {200, [], %{data: []}}}

      house_ok =
        {%{method: "POST", path: @sets, body: %{name: "ravix:house"}},
         {201, [], %{data: house_default()}}}

      mine = %{method: "POST", path: @sets, body: %{name: "ravix:#{me.id}"}}
      down = {500, [], %{error: "down"}}

      scripts = [
        [{%{method: "GET", path: @sets}, down}],
        [sets_ok, {%{method: "POST", path: @sets, body: %{name: "ravix:house"}}, down}],
        [sets_ok, house_ok, {mine, down}],
        [
          sets_ok,
          house_ok,
          {mine, {201, [], %{data: %{id: "set-me"}}}},
          put("set-me", "anthropic_api_key", down)
        ]
      ]

      for script <- scripts do
        fountain(script)

        assert {:error, %Ravix.Fountain.Error{status: 500}} =
                 Inference.connect(me, %{agent: :claude, kind: :api_key, value: "k"})

        assert %User{agent: nil, credential_set_id: nil} = Repo.get!(User, me.id)
      end
    end

    test "a set Fountain answers for without an id is not one to write into" do
      me = insert_user()

      fountain([
        {%{method: "GET", path: @sets}, {200, [], %{data: [house_default()]}}},
        {%{method: "POST", path: @sets}, {201, [], %{data: %{name: "ravix:#{me.id}"}}}}
      ])

      assert {:error, {:unavailable, _}} =
               Inference.connect(me, %{agent: :claude, kind: :api_key, value: "k"})
    end

    test "a set that has gone from Fountain says so rather than blaming the key" do
      me = insert_user(agent: :codex, credential_kind: :api_key, credential_set_id: "gone")
      fountain([put("gone", "openai_api_key", {404, [], %{error: "not_found"}})])

      assert {:error, {:unavailable, _}} =
               Inference.connect(me, %{agent: :codex, kind: :api_key, value: "k"})
    end

    test "the other kind already being gone is the outcome wanted; failing to remove it is not" do
      me = insert_user(agent: :claude, credential_kind: :subscription, credential_set_id: "s")
      other = %{method: "DELETE", path: "#{@sets}/s/credentials/claude_code_oauth_token"}

      fountain([put("s", "anthropic_api_key"), {other, {404, [], %{error: "not_found"}}}])

      assert {:ok, %User{credential_kind: :api_key}} =
               Inference.connect(me, %{agent: :claude, kind: :api_key, value: "k"})

      # Left saying what it said: the token is still in the set and Claude Code
      # would still prefer it, so the row must not claim the key is what pays.
      again = insert_user(agent: :claude, credential_kind: :subscription, credential_set_id: "s2")
      other = %{other | path: "#{@sets}/s2/credentials/claude_code_oauth_token"}
      fountain([put("s2", "anthropic_api_key"), {other, {500, [], %{error: "down"}}}])

      assert {:error, %Ravix.Fountain.Error{status: 500}} =
               Inference.connect(again, %{agent: :claude, kind: :api_key, value: "k"})

      assert %User{credential_kind: :subscription} = Repo.get!(User, again.id)
    end

    test "a value that is not text, and nobody at all" do
      fountain([])

      assert {:error, {:unprocessable, "no_credential", _}} =
               Inference.connect(insert_user(), %{agent: :claude, kind: :api_key, value: nil})

      refute Inference.connected?(nil)
      assert Inference.runtime(insert_user()) == nil
    end

    test "a deployment with no Fountain has nowhere to keep one" do
      stub(Ravix.Fountain, :client, fn -> Client.new("https://fountain.test", nil) end)

      assert {:error, {:unavailable, _}} =
               Inference.connect(insert_user(), %{agent: :claude, kind: :api_key, value: "k"})
    end
  end

  describe "the walkthrough" do
    test "is for somebody who has never finished it and has nowhere to be" do
      fresh = insert_user(onboarded_at: nil)
      assert Accounts.needs_onboarding?(fresh, 0)
      # Invited into a teammate's project before ever seeing the app.
      refute Accounts.needs_onboarding?(fresh, 1)
      refute Accounts.needs_onboarding?(insert_user(), 0)
    end

    test "finishing is recorded once and asking again changes nothing" do
      fresh = insert_user(onboarded_at: nil)

      assert {:ok, %User{onboarded_at: %DateTime{} = at} = done} =
               Accounts.finish_onboarding(fresh)

      assert {:ok, %User{onboarded_at: ^at}} = Accounts.finish_onboarding(done)
      refute Accounts.needs_onboarding?(Repo.get!(User, fresh.id), 0)
    end

    test "a sign-in after it does not undo what the person set up" do
      me = insert_user(agent: :codex, credential_kind: :api_key, credential_set_id: "s")

      assert {:ok, again} =
               Accounts.upsert_user(%{
                 github_id: me.github_id,
                 login: "renamed",
                 token_enc: Ravix.Crypto.encrypt("t")
               })

      assert %User{
               login: "renamed",
               agent: :codex,
               credential_set_id: "s",
               onboarded_at: %DateTime{}
             } = again
    end

    test "the database refuses an agent the app does not know" do
      me = insert_user()

      assert_raise Postgrex.Error, ~r/users_agent/, fn ->
        Repo.query!("UPDATE ravix.users SET agent = 'gemini' WHERE id = $1", [me.id])
      end
    end
  end
end
