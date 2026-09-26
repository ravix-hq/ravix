defmodule Ravix.GitHubTest do
  use ExUnit.Case, async: true

  alias Ravix.Clock
  alias Ravix.GitHub
  alias Ravix.GitHub.{Cache, Error, Shapes}
  alias Ravix.GitHubFake, as: Fake

  setup do
    on_exit(fn -> Clock.freeze(nil) end)
    %{app: Fake.app()}
  end

  # ── the App ──────────────────────────────────────────────────────────

  describe "app_jwt/1" do
    test "signs a ten-minute RS256 JWT GitHub accepts, from the PKCS#1 key GitHub issues",
         %{app: app} do
      Clock.freeze(1_700_000_000_000)
      claims = app |> GitHub.app_jwt() |> Fake.verify_app_jwt!()
      assert claims["iss"] == app.app_id
      # `iat` backdated a minute so a clock ahead of ours still accepts it.
      assert claims["iat"] == 1_700_000_000 - 60
      assert claims["exp"] == 1_700_000_000 + 9 * 60
    end

    test "signs from a PKCS#8 key too" do
      app = Fake.app(private_key_pem: Fake.private_key_pem_pkcs8())
      assert %{"iss" => iss} = app |> GitHub.app_jwt() |> Fake.verify_app_jwt!()
      assert iss == app.app_id
    end

    test "signs from a PEM a secret store mangled" do
      escaped = Fake.private_key_pem() |> String.trim() |> String.replace("\n", "\\n")
      app = Fake.app(private_key_pem: Ravix.Config.normalize_pem(escaped))
      assert %{"iss" => _} = app |> GitHub.app_jwt() |> Fake.verify_app_jwt!()
    end
  end

  describe "installation tokens" do
    test "machine preparations mint fresh tokens while ordinary API calls reuse the cache",
         %{app: app} do
      Fake.install([Fake.token_route(app)])
      assert {:ok, "token-1"} = GitHub.installation_token(app, 1)
      assert {:ok, "token-1"} = GitHub.installation_token(app, 1)
      assert {:ok, "token-2"} = GitHub.mint_clone_token(app, 1)
      assert {:ok, "token-3"} = GitHub.mint_clone_token(app, 1)
      assert {:ok, "token-3"} = GitHub.installation_token(app, 1)
      assert Fake.request_count("access_tokens") == 3
    end

    test "a token is reused until a minute before it expires, then re-minted", %{app: app} do
      minted_at = 1_700_000_000_000
      Clock.freeze(minted_at)
      expires = DateTime.from_unix!(minted_at + 3_600_000, :millisecond) |> DateTime.to_iso8601()

      Fake.install([
        {"POST", ~r{/access_tokens$},
         fn conn ->
           Req.Test.json(conn, %{
             token: "t-#{System.unique_integer([:positive])}",
             expires_at: expires
           })
         end}
      ])

      assert {:ok, first} = GitHub.installation_token(app, 7)
      # 61 seconds left: still good.
      Clock.freeze(minted_at + 3_600_000 - 61_000)
      assert {:ok, ^first} = GitHub.installation_token(app, 7)
      # 59 seconds left: not worth handing to anyone.
      Clock.freeze(minted_at + 3_600_000 - 59_000)
      assert {:ok, second} = GitHub.installation_token(app, 7)
      assert second != first
    end

    test "each installation has its own token", %{app: app} do
      Fake.install([Fake.token_route(app)])
      assert {:ok, "token-1"} = GitHub.installation_token(app, 1)
      assert {:ok, "token-2"} = GitHub.installation_token(app, 2)
      assert {:ok, "token-1"} = GitHub.installation_token(app, 1)
    end

    test "GitHub's refusal comes back as an error", %{app: app} do
      Fake.install([{"POST", ~r{/access_tokens$}, {401, %{message: "Bad credentials"}}}])

      assert {:error, %Error{status: 401, message: "Bad credentials"}} =
               GitHub.installation_token(app, 1)
    end
  end

  # ── signing somebody in ──────────────────────────────────────────────

  describe "authorize_url/3 and install_url/2" do
    test "build the two GitHub addresses", %{app: app} do
      url = GitHub.authorize_url(app, "http://localhost:5183/api/auth/callback", "st8")
      assert String.starts_with?(url, "https://github.test/login/oauth/authorize?")
      assert url =~ "client_id=Iv1.x"
      assert url =~ "state=st8"
      assert url =~ "scope=read%3Auser"
      # `redirect_uri` must round-trip exactly; GitHub compares it literally.
      assert url =~ "redirect_uri=http%3A%2F%2Flocalhost%3A5183%2Fapi%2Fauth%2Fcallback"

      assert GitHub.install_url(app) == "https://github.test/apps/test/installations/new"

      assert GitHub.install_url(app, "s t") ==
               "https://github.test/apps/test/installations/new?state=s+t"
    end
  end

  describe "exchange_code/3" do
    test "returns the user token", %{app: app} do
      owner = self()

      Fake.install([
        {"POST", "/login/oauth/access_token",
         fn conn ->
           {:ok, raw, conn} = Plug.Conn.read_body(conn)

           send(
             owner,
             {:exchange_body, Jason.decode!(raw), Plug.Conn.get_req_header(conn, "accept")}
           )

           Req.Test.json(conn, %{access_token: "gho_abc", token_type: "bearer"})
         end}
      ])

      assert {:ok, "gho_abc"} = GitHub.exchange_code(app, "c0de", "http://localhost/cb")
      assert_received {:exchange_body, body, ["application/json"]}

      assert body == %{
               "client_id" => "Iv1.x",
               "client_secret" => "s",
               "code" => "c0de",
               "redirect_uri" => "http://localhost/cb"
             }
    end

    test "a 200 with an error body is still a failure, in GitHub's words", %{app: app} do
      Fake.install([
        {"POST", "/login/oauth/access_token",
         %{
           error: "bad_verification_code",
           error_description: "The code passed is incorrect or expired."
         }}
      ])

      assert {:error, %Error{status: 400, message: "The code passed is incorrect or expired."}} =
               GitHub.exchange_code(app, "spent", "http://localhost/cb")
    end

    test "a body without a token or a reason gets the default message", %{app: app} do
      Fake.install([{"POST", "/login/oauth/access_token", %{token_type: "bearer"}}])

      assert {:error, %Error{status: 400, message: "GitHub would not exchange that code."}} =
               GitHub.exchange_code(app, "x", "http://localhost/cb")
    end

    test "a GitHub that fails or does not answer is the same error every other call gives",
         %{app: app} do
      # The exchange used to build its own request beside `Ravix.GitHub.HTTP`
      # with a second copy of the transport error and a 400 for whatever came
      # back. Through the funnel, a 5xx keeps its status and no answer at all
      # has none, exactly as `viewer/2` reports them.
      Fake.install([{"POST", "/login/oauth/access_token", {502, %{message: "nope"}}}])

      assert {:error, %Error{status: 502, message: "nope"}} =
               GitHub.exchange_code(app, "x", "http://localhost/cb")

      Fake.install([
        {"POST", "/login/oauth/access_token",
         fn conn -> Req.Test.transport_error(conn, :timeout) end}
      ])

      assert {:error, %Error{status: nil, message: "Could not reach GitHub: " <> _}} =
               GitHub.exchange_code(app, "x", "http://localhost/cb")
    end

    test "sends no Authorization header: the client secret in the body is the credential",
         %{app: app} do
      owner = self()

      Fake.install([
        {"POST", "/login/oauth/access_token",
         fn conn ->
           send(owner, {:auth_header, Plug.Conn.get_req_header(conn, "authorization")})
           Req.Test.json(conn, %{access_token: "gho_abc"})
         end}
      ])

      assert {:ok, "gho_abc"} = GitHub.exchange_code(app, "c0de", "http://localhost/cb")
      assert_received {:auth_header, []}
    end
  end

  describe "user_by_login/2 and viewer/2" do
    test "read an account as the App, and nil for a login nobody has", %{app: app} do
      Fake.install([
        {"GET", "/users/octo%40cat",
         fn conn ->
           ["Bearer " <> jwt] = Plug.Conn.get_req_header(conn, "authorization")
           Fake.verify_app_jwt!(jwt)

           Req.Test.json(conn, %{
             id: 5,
             login: "octo@cat",
             name: nil,
             avatar_url: "https://a/5",
             extra: 1
           })
         end},
        {"GET", "/users/nobody", {404, %{message: "Not Found"}}}
      ])

      assert {:ok, %{id: 5, login: "octo@cat", name: nil, avatar_url: "https://a/5"}} =
               GitHub.user_by_login(app, "octo@cat")

      assert {:ok, nil} = GitHub.user_by_login(app, "nobody")
    end

    test "viewer reads /user with the person's token", %{app: app} do
      Fake.install([
        {"GET", "/user",
         fn conn ->
           assert ["Bearer gho_me"] = Plug.Conn.get_req_header(conn, "authorization")
           assert ["application/vnd.github+json"] = Plug.Conn.get_req_header(conn, "accept")
           assert ["2022-11-28"] = Plug.Conn.get_req_header(conn, "x-github-api-version")
           Req.Test.json(conn, %{id: 9, login: "me", name: "Me", avatar_url: nil})
         end}
      ])

      assert {:ok, %{id: 9, login: "me", name: "Me", avatar_url: nil}} =
               GitHub.viewer(app, "gho_me")
    end
  end

  # ── what this person can see ─────────────────────────────────────────

  describe "installations_for/2" do
    test "lists the installations the person's token can see", %{app: app} do
      Fake.install([
        {"GET", "/user/installations",
         %{
           installations: [
             %{id: 1, account: %{login: "ravix-hq", avatar_url: "https://a/1"}},
             %{id: 2, account: nil}
           ]
         }}
      ])

      assert {:ok,
              [
                %{id: 1, account: "ravix-hq", avatar_url: "https://a/1"},
                %{id: 2, account: "(unknown)", avatar_url: nil}
              ]} = GitHub.installations_for(app, "gho_me")
    end
  end

  describe "repositories/3" do
    test "pages through the installation and sorts by last push", %{app: app} do
      page1 = for n <- 1..100, do: raw_repo("o/r#{n}", "2026-01-01T00:00:#{pad(rem(n, 60))}Z")
      page2 = [raw_repo("o/newest", "2026-09-01T00:00:00Z"), raw_repo("o/never", nil)]

      Fake.install([
        {"GET", "/user/installations/4/repositories",
         fn conn ->
           %{"per_page" => "100", "page" => page} =
             Plug.Conn.fetch_query_params(conn).query_params

           Req.Test.json(conn, %{repositories: if(page == "1", do: page1, else: page2)})
         end}
      ])

      assert {:ok, repos} = GitHub.repositories(app, "gho_me", 4)
      assert length(repos) == 102
      assert hd(repos).full_name == "o/newest"
      assert List.last(repos).full_name == "o/never"
      assert Fake.request_count("repositories") == 2

      assert %{
               full_name: "o/newest",
               owner: "o",
               name: "newest",
               private: true,
               default_branch: "main",
               description: "d",
               pushed_at: "2026-09-01T00:00:00Z",
               language: "Elixir",
               installation_id: 4
             } = hd(repos)
    end

    test "a short first page is the only page", %{app: app} do
      Fake.install([
        {"GET", "/user/installations/4/repositories", %{repositories: [raw_repo("o/r", nil)]}}
      ])

      assert {:ok, [%{full_name: "o/r"}]} = GitHub.repositories(app, "gho_me", 4)
      assert Fake.request_count("repositories") == 1
    end
  end

  describe "repository/3" do
    test "reads one repository as the installation", %{app: app} do
      Fake.install([
        Fake.token_route(app),
        {"GET", "/repos/o/private",
         fn conn ->
           assert ["Bearer token-1"] = Plug.Conn.get_req_header(conn, "authorization")
           Req.Test.json(conn, raw_repo("o/private", nil))
         end}
      ])

      assert {:ok, %{full_name: "o/private", installation_id: 3}} =
               GitHub.repository(app, 3, "o/private")
    end
  end

  # ── the boundary ─────────────────────────────────────────────────────

  describe "the shapes the wire is turned into" do
    test "are structs, so a caller can match on which one it holds" do
      pull = Shapes.pull_ref(%{"number" => 1, "state" => "open"})
      run = Shapes.check_run(%{"name" => "ci", "status" => "queued"})

      assert match?(%Shapes.PullRef{}, pull)
      refute match?(%Shapes.CheckRun{}, pull)
      assert match?(%Shapes.CheckRun{}, run)
    end

    test "carry every field even when GitHub sent none of it" do
      # The point of `@enforce_keys` at this boundary: a payload missing
      # `html_url` produces `url: nil`, not a value with no `url` at all.
      # Reading an absent key off a bare map also answered `nil`, which is
      # how a field that was never populated looked exactly like one that
      # was populated with nothing.
      sparse = Shapes.pull_ref(%{"number" => 7})

      assert sparse.url == nil
      assert sparse.author == nil
      assert sparse.draft == false
      assert sparse.state == :open

      assert Map.keys(sparse) --
               [
                 :__struct__,
                 :number,
                 :title,
                 :author,
                 :head_ref,
                 :base_ref,
                 :draft,
                 :updated_at,
                 :state,
                 :url
               ] == []
    end

    test "refuse to be built with a field nobody declared" do
      assert_raise KeyError, fn ->
        struct!(Shapes.CheckRun, %{
          name: "ci",
          status: "queued",
          conclusion: nil,
          url: nil,
          started_at: nil,
          completed_at: nil,
          concluzion: "typo"
        })
      end
    end
  end

  # ── the three ways to start a track ──────────────────────────────────

  describe "branches/4, pulls/3, issues/3" do
    test "branches put the default first, then alphabetical", %{app: app} do
      Fake.install([
        Fake.token_route(app),
        {"GET", "/repos/o/r/branches",
         [
           %{name: "zed", commit: %{sha: "z"}},
           %{name: "main", commit: %{sha: "m"}},
           %{name: "alpha", commit: %{sha: "a"}}
         ]}
      ])

      assert {:ok,
              [
                %{name: "main", sha: "m", is_default: true},
                %{name: "alpha", sha: "a", is_default: false},
                %{name: "zed", sha: "z", is_default: false}
              ]} = GitHub.branches(app, 1, "o/r", "main")
    end

    test "pulls come back as PullRefs", %{app: app} do
      Fake.install([
        Fake.token_route(app),
        {"GET", "/repos/o/r/pulls",
         fn conn ->
           assert %{
                    "state" => "open",
                    "sort" => "updated",
                    "direction" => "desc",
                    "per_page" => "50"
                  } =
                    Plug.Conn.fetch_query_params(conn).query_params

           Req.Test.json(conn, [
             raw_pull(1, "feature", draft: true),
             raw_pull(2, "other", user: nil)
           ])
         end}
      ])

      assert {:ok, [first, second]} = GitHub.pulls(app, 1, "o/r")

      assert first == %Shapes.PullRef{
               number: 1,
               title: "PR 1",
               author: "someone",
               head_ref: "feature",
               base_ref: "main",
               draft: true,
               updated_at: "2026-09-07T00:00:00Z",
               state: :open,
               url: "https://github.test/o/r/pull/1"
             }

      assert %{number: 2, author: nil, draft: false} = second
    end

    test "issues leave out the pull requests and flatten labels", %{app: app} do
      Fake.install([
        Fake.token_route(app),
        {"GET", "/repos/o/r/issues",
         [
           %{
             number: 3,
             title: "Bug",
             user: %{login: "a"},
             labels: ["bug", %{name: "p1"}],
             updated_at: "2026-09-07T00:00:00Z"
           },
           %{
             number: 4,
             title: "PR",
             user: nil,
             labels: nil,
             updated_at: "2026-09-06T00:00:00Z",
             pull_request: %{url: "x"}
           }
         ]}
      ])

      assert {:ok,
              [
                %{
                  number: 3,
                  title: "Bug",
                  author: "a",
                  labels: ["bug", "p1"],
                  updated_at: "2026-09-07T00:00:00Z"
                }
              ]} =
               GitHub.issues(app, 1, "o/r")
    end
  end

  # ── what GitHub thinks of a branch ───────────────────────────────────

  describe "checks/5" do
    test "a merged PR survives deletion of its head branch", %{app: app} do
      Fake.install([
        Fake.token_route(app),
        {"GET", ~r{^/repos/o/r/branches/}, {404, %{message: "Not Found"}}},
        {"GET", "/repos/o/r/pulls",
         [
           %{
             number: 42,
             title: "Merged",
             user: nil,
             head: %{ref: "branch"},
             base: %{ref: "main"},
             draft: false,
             state: "closed",
             merged_at: "2026-09-06",
             updated_at: "2026-09-06",
             html_url: "https://github.test/o/r/pull/42"
           }
         ]}
      ])

      assert {:ok, report} = GitHub.checks(app, 1, "o/r", "branch")
      assert report.pushed == false
      assert report.sha == nil
      assert report.runs == []
      assert %{state: :merged, number: 42} = report.pull
      assert Fake.request_count("check-runs") == 0
    end

    test "asks for pull requests by head and reports the runs", %{app: app} do
      Fake.install([
        Fake.token_route(app),
        {"GET", "/repos/o/r/branches/feat%2Fx", %{commit: %{sha: "abc"}}},
        {"GET", "/repos/o/r/commits/abc/check-runs",
         %{
           check_runs: [
             %{
               name: "ci",
               status: "completed",
               conclusion: "success",
               html_url: "https://c/1",
               started_at: "s",
               completed_at: "c"
             },
             %{name: "lint", status: "in_progress", conclusion: nil}
           ]
         }},
        {"GET", "/repos/o/r/pulls",
         fn conn ->
           assert %{"state" => "all", "per_page" => "20", "head" => "o:feat/x"} =
                    Plug.Conn.fetch_query_params(conn).query_params

           Req.Test.json(conn, [
             raw_pull(8, "feat/x", state: "closed", updated_at: "2026-09-08T00:00:00Z"),
             raw_pull(9, "feat/x", updated_at: "2026-09-01T00:00:00Z"),
             raw_pull(10, "feat/x", updated_at: "2026-09-05T00:00:00Z"),
             raw_pull(11, "unrelated", updated_at: "2026-09-09T00:00:00Z")
           ])
         end}
      ])

      assert {:ok, report} = GitHub.checks(app, 1, "o/r", "feat/x")
      assert report.ref == "feat/x"
      assert report.sha == "abc"
      assert report.pushed == true

      assert report.runs == [
               %Shapes.CheckRun{
                 name: "ci",
                 status: "completed",
                 conclusion: "success",
                 url: "https://c/1",
                 started_at: "s",
                 completed_at: "c"
               },
               %Shapes.CheckRun{
                 name: "lint",
                 status: "in_progress",
                 conclusion: nil,
                 url: nil,
                 started_at: nil,
                 completed_at: nil
               }
             ]

      # The open one, most recently updated, beats a newer closed one.
      assert %{number: 10, state: :open} = report.pull
    end

    for {name, origin, created, expected} <- [
          {"a reused name does not inherit an older PR", nil, "2026-09-01T00:00:00Z", nil},
          {"a PR made during this track is included", nil, "2026-09-06T12:00:01Z", 27},
          {"same-second creation tolerates GitHub timestamp precision", nil,
           "2026-09-06T12:00:00Z", 27},
          {"an explicit PR origin can predate its track", 27, "2026-09-01T00:00:00Z", 27},
          {"an explicit PR origin does not select a different PR", 28, "2026-09-01T00:00:00Z",
           nil}
        ] do
      test name, %{app: app} do
        Fake.install([
          Fake.token_route(app),
          {"GET", ~r{^/repos/ravix-hq/ravix/branches/}, {404, %{message: "Not Found"}}},
          {"GET", "/repos/ravix-hq/ravix/pulls",
           [
             %{
               number: 27,
               title: "Old Antwerp",
               user: nil,
               head: %{ref: "jhgaylor/antwerp"},
               base: %{ref: "main"},
               state: "closed",
               merged_at: "2026-09-06",
               created_at: unquote(created),
               updated_at: "2026-09-07T00:00:00Z"
             }
           ]}
        ])

        track = %{created_at: ~U[2026-09-06 12:00:00.123Z], origin_number: unquote(origin)}
        assert {:ok, report} = GitHub.checks(app, 1, "ravix-hq/ravix", "jhgaylor/antwerp", track)
        assert (report.pull && report.pull.number) == unquote(expected)
      end
    end

    test "viewers share in-flight checks and cached reports, then refresh after five minutes",
         %{app: app} do
      Fake.install([
        Fake.token_route(app),
        {"GET", ~r{^/repos/o/r/branches/}, %{commit: %{sha: "abc"}}},
        {"GET", ~r{check-runs$}, %{check_runs: []}},
        {"GET", "/repos/o/r/pulls", []}
      ])

      # Warm the token so the count below is only the three reads.
      assert {:ok, _} = GitHub.installation_token(app, 1)
      Fake.requests()

      results =
        1..20
        |> Task.async_stream(fn _ -> GitHub.checks(app, 1, "o/r", "branch") end,
          max_concurrency: 20
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, %{sha: "abc"}}, &1))
      assert Fake.request_count("/repos/") == 3

      assert {:ok, _} = GitHub.checks(app, 1, "o/r", "branch")
      assert Fake.request_count("/repos/") == 0

      Clock.freeze(System.system_time(:millisecond) + 300_001)
      assert {:ok, _} = GitHub.checks(app, 1, "o/r", "branch")
      assert Fake.request_count("/repos/") == 3

      assert {:ok, _} = GitHub.checks(app, 2, "o/r", "branch")
      assert Fake.request_count("/repos/") == 3
    end

    test "a crashed read releases the people waiting on it", %{app: app} do
      Fake.install([
        Fake.token_route(app),
        {"GET", ~r{^/repos/o/r/branches/}, fn _conn -> raise "boom" end}
      ])

      assert {:ok, _} = GitHub.installation_token(app, 1)

      # A caller whose read raises leaves nothing in flight: the next caller
      # runs the read itself rather than waiting forever.
      assert catch_error(GitHub.checks(app, 1, "o/r", "crash"))
      assert catch_error(GitHub.checks(app, 1, "o/r", "crash"))
      assert Fake.request_count("/branches/") == 2
    end

    for headers <- [
          [{"x-ratelimit-remaining", "0"}, {"x-ratelimit-reset", "1600"}],
          [{"retry-after", "600"}]
        ] do
      test "rate limits stop all reads for an installation until reset: #{inspect(headers)}",
           %{app: app} do
        Clock.freeze(1_000_000)
        first = :counters.new(1, [])

        Fake.install([
          Fake.token_route(app),
          {"GET", ~r{^/repos/},
           fn conn ->
             if :counters.get(first, 1) == 0 do
               :counters.add(first, 1, 1)

               unquote(headers)
               |> Enum.reduce(conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)
               |> Plug.Conn.put_status(403)
               |> Req.Test.json(%{message: "API rate limit exceeded"})
             else
               Req.Test.json(conn, [])
             end
           end}
        ])

        assert {:error, %Error{message: message, retry_at_ms: 1_600_000}} =
                 GitHub.checks(app, 1, "o/r", "a")

        assert message =~ "rate limit"

        assert {:error, %Error{message: "API rate limit exceeded"}} =
                 GitHub.checks(app, 1, "o/r", "a")

        assert {:error, %Error{message: "API rate limit exceeded"}} =
                 GitHub.checks(app, 1, "o/r", "b")

        assert {:error, %Error{message: "API rate limit exceeded"}} =
                 GitHub.pulls(app, 1, "o/other")

        assert Fake.request_count("/repos/") == 1

        assert {:ok, []} = GitHub.pulls(app, 2, "o/r")
        assert Fake.request_count("/repos/") == 1

        Clock.freeze(1_600_001)
        assert {:ok, []} = GitHub.pulls(app, 1, "o/r")
        assert Fake.request_count("/repos/") == 1
      end
    end

    test "permission failures do not block unrelated installation reads", %{app: app} do
      first = :counters.new(1, [])

      Fake.install([
        Fake.token_route(app),
        {"GET", ~r{^/repos/},
         fn conn ->
           if :counters.get(first, 1) == 0 do
             :counters.add(first, 1, 1)
             conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{message: "Forbidden"})
           else
             Req.Test.json(conn, [])
           end
         end}
      ])

      assert {:error, %Error{status: 403, message: "Forbidden", retry_at_ms: nil}} =
               GitHub.checks(app, 1, "o/r", "a")

      assert {:ok, []} = GitHub.pulls(app, 1, "o/r")
      assert Fake.request_count("/repos/") == 2
    end

    test "a failed read is remembered, so mounted rows do not retry in a loop", %{app: app} do
      Fake.install([
        Fake.token_route(app),
        {"GET", ~r{^/repos/}, {500, %{message: "Server Error"}}}
      ])

      assert {:error, %Error{status: 500}} = GitHub.checks(app, 1, "o/r", "a")
      assert {:error, %Error{status: 500}} = GitHub.checks(app, 1, "o/r", "a")
      assert Fake.request_count("/repos/") == 1
    end
  end

  describe "checks cache invalidation" do
    test "a read already running when the key is dropped answers its waiters but caches nothing" do
      app_id = "cache-#{System.unique_integer([:positive])}"
      started = self()
      release = make_ref()

      runner =
        Task.async(fn ->
          Cache.checks(app_id, "feat", Clock.now_ms(), fn ->
            send(started, {:running, release})
            receive do: ({^release, :go} -> :ok)
            {:ok, %{pull: nil}}
          end)
        end)

      assert_receive {:running, ^release}

      # The pull request is opened while the report is still being fetched.
      Cache.drop_checks(app_id, &(&1 == "feat"))
      send(runner.pid, {release, :go})

      # The runner still answers -- it is the only answer that exists -- but
      # its pre-PR result must not outlive the drop.
      assert {:ok, %{pull: nil}} = Task.await(runner)

      assert Cache.checks(app_id, "feat", Clock.now_ms(), fn -> {:ok, %{pull: :fresh}} end) ==
               {:ok, %{pull: :fresh}}
    end

    test "an uninvalidated read is cached as before" do
      app_id = "cache-#{System.unique_integer([:positive])}"
      now = Clock.now_ms()

      assert Cache.checks(app_id, "feat", now, fn -> {:ok, %{pull: :first}} end) ==
               {:ok, %{pull: :first}}

      assert Cache.checks(app_id, "feat", now, fn -> {:ok, %{pull: :second}} end) ==
               {:ok, %{pull: :first}}
    end
  end

  describe "answers that are not JSON" do
    test "a 2xx carrying an interstitial is a tagged error, not a raise", %{app: app} do
      Fake.install([
        Fake.token_route(app),
        {"GET", ~r{/repositories},
         fn conn ->
           conn
           |> Plug.Conn.put_resp_content_type("text/html")
           |> Plug.Conn.send_resp(200, "<html>checking your browser</html>")
         end}
      ])

      # A proxy or WAF answering 200 with a page used to reach `body["token"]`
      # and `Enum.map(body, ...)` as a bare string, raising `Access` and
      # `Enumerable` errors out of the context and taking the LiveView with
      # them, past the `{:ok, _} | {:error, _}` this promises.
      assert {:error, %Error{status: 200, message: message}} =
               GitHub.repositories(app, "gho_user", 1)

      assert message =~ "not JSON"
    end
  end

  describe "issue labels" do
    test "a label in an unexpected shape is skipped rather than raising", %{app: app} do
      Fake.install([
        Fake.token_route(app),
        {"GET", ~r{/issues},
         [
           %{
             number: 4,
             title: "Bug",
             user: %{login: "dana"},
             labels: ["plain", %{name: "object"}, %{color: "f00"}, nil],
             updated_at: "2026-01-01T00:00:00Z"
           }
         ]}
      ])

      assert {:ok, [%{number: 4, labels: labels}]} = GitHub.issues(app, 1, "o/r")
      assert labels == ["plain", "object"]
    end
  end

  describe "installation token expiry" do
    test "a response with no parseable expiry is re-minted rather than reused forever", %{
      app: app
    } do
      Fake.install([
        {"POST", ~r{/access_tokens$},
         fn conn ->
           # A proxy, a GHES variant, or anything that drops the field.
           Req.Test.json(conn, %{token: "t-#{System.unique_integer([:positive])}"})
         end}
      ])

      assert {:ok, first} = GitHub.installation_token(app, 9)

      # Erlang term order sorts every atom above every integer, so an unparsed
      # expiry compared with `>` used to read as "good forever" -- and an hour
      # later every call carried a token GitHub had stopped accepting.
      assert {:ok, second} = GitHub.installation_token(app, 9)
      assert second != first
      assert Fake.request_count("access_tokens") == 2
    end
  end

  describe "open_pull/4" do
    test "opens the pull request and forgets the branch's checks report", %{app: app} do
      owner = self()

      Fake.install([
        Fake.token_route(app),
        {"GET", ~r{^/repos/o/r/branches/}, %{commit: %{sha: "abc"}}},
        {"GET", ~r{check-runs$}, %{check_runs: []}},
        {"GET", "/repos/o/r/pulls", []},
        {"POST", "/repos/o/r/pulls",
         fn conn ->
           {:ok, raw, conn} = Plug.Conn.read_body(conn)
           send(owner, {:pull_body, Jason.decode!(raw)})

           conn
           |> Plug.Conn.put_status(201)
           |> Req.Test.json(raw_pull(77, "feat", html_url: "https://github.test/o/r/pull/77"))
         end}
      ])

      assert {:ok, %{pull: nil}} = GitHub.checks(app, 1, "o/r", "feat")
      assert {:ok, %{pull: nil}} = GitHub.checks(app, 1, "o/r", "other")
      Fake.requests()

      input = %{head: "feat", base: "main", title: "T", body: "B", draft: true}

      assert {:ok, %{number: 77, url: "https://github.test/o/r/pull/77"}} =
               GitHub.open_pull(app, 1, "o/r", input)

      assert_received {:pull_body,
                       %{
                         "head" => "feat",
                         "base" => "main",
                         "title" => "T",
                         "body" => "B",
                         "draft" => true
                       }}

      # The branch with the new PR is re-read; the other branch is still cached.
      Fake.requests()
      assert {:ok, _} = GitHub.checks(app, 1, "o/r", "feat")
      assert Fake.request_count("/repos/o/r/branches/") == 1
      assert {:ok, _} = GitHub.checks(app, 1, "o/r", "other")
      assert Fake.request_count("/repos/o/r/branches/") == 0
    end
  end

  # ── errors ───────────────────────────────────────────────────────────

  describe "errors" do
    test "every call names GitHub as the missing integration without an App" do
      # The shape `Ravix.Providers` gives every missing integration, so a
      # context passes it through and `RavixWeb.Error` says which one.
      refused = {:error, {:unconfigured, :github}}
      assert refused == GitHub.installation_token(nil, 1)
      assert refused == GitHub.mint_clone_token(nil, 1)
      assert refused == GitHub.exchange_code(nil, "c", "r")
      assert refused == GitHub.user_by_login(nil, "x")
      assert refused == GitHub.viewer(nil, "t")
      assert refused == GitHub.installations_for(nil, "t")
      assert refused == GitHub.repositories(nil, "t", 1)
      assert refused == GitHub.repository(nil, 1, "o/r")
      assert refused == GitHub.branches(nil, 1, "o/r", "main")
      assert refused == GitHub.pulls(nil, 1, "o/r")
      assert refused == GitHub.issues(nil, 1, "o/r")
      assert refused == GitHub.checks(nil, 1, "o/r", "x")
      assert refused == GitHub.open_pull(nil, 1, "o/r", %{head: "h"})
    end

    test "GitHub's message and first detail are kept; a non-JSON body keeps the status", %{
      app: app
    } do
      Fake.install([
        {"GET", "/user",
         {422,
          %{
            message: "Validation Failed",
            errors: [%{message: "head invalid"}, %{message: "ignored"}]
          }}},
        {"GET", "/user/installations",
         fn conn -> Plug.Conn.send_resp(conn, 502, "<html>bad gateway</html>") end}
      ])

      assert {:error, %Error{status: 422, message: "Validation Failed head invalid"}} =
               GitHub.viewer(app, "t")

      assert {:error, %Error{status: 502, message: "GitHub said 502."}} =
               GitHub.installations_for(app, "t")
    end

    test "an unreachable GitHub is an error without a status", %{app: app} do
      Fake.install([
        {"GET", "/user", fn conn -> Req.Test.transport_error(conn, :econnrefused) end}
      ])

      assert {:error, %Error{status: nil, message: "Could not reach GitHub: " <> _}} =
               GitHub.viewer(app, "t")
    end

    test "describe/2 turns a failure into the status, code and message the web layer answers with" do
      assert {503, "github_rate_limited", message} =
               Error.describe(
                 %Error{status: 403, message: "x", retry_at_ms: 1_600_000},
                 "list repositories"
               )

      assert message =~ "1970-01-01T00:26:40.000Z"

      assert {502, "github_rejected", "GitHub would not let Ravix list repositories: Forbidden"} =
               Error.describe(%Error{status: 403, message: "Forbidden"}, "list repositories")

      assert {502, "github_rejected", _} =
               Error.describe(%Error{status: 401, message: "Bad"}, "x")

      assert {404, "github_not_found", "Not Found"} =
               Error.describe(%Error{status: 404, message: "Not Found"}, "x")

      assert {422, "github_error", "Validation Failed"} =
               Error.describe(%Error{status: 422, message: "Validation Failed"}, "x")

      assert {502, "github_error", "boom"} =
               Error.describe(%Error{status: 500, message: "boom"}, "x")

      assert {502, "github_unreachable", "Could not reach GitHub to open a pull request."} =
               Error.describe(%Error{status: nil, message: "timeout"}, "open a pull request")

      assert {502, "github_unreachable", _} = Error.describe(:no_answer, "x")
    end
  end

  # ── the shapes GitHub sends ──────────────────────────────────────────

  defp raw_repo(full_name, pushed_at) do
    [owner, name] = String.split(full_name, "/")

    %{
      full_name: full_name,
      name: name,
      owner: %{login: owner},
      private: true,
      default_branch: "main",
      description: "d",
      pushed_at: pushed_at,
      language: "Elixir"
    }
  end

  defp raw_pull(number, head, opts) do
    %{
      number: number,
      title: "PR #{number}",
      user: Keyword.get(opts, :user, %{login: "someone"}),
      head: %{ref: head},
      base: %{ref: "main"},
      draft: Keyword.get(opts, :draft, false),
      state: Keyword.get(opts, :state, "open"),
      updated_at: Keyword.get(opts, :updated_at, "2026-09-07T00:00:00Z"),
      html_url: Keyword.get(opts, :html_url, "https://github.test/o/r/pull/#{number}")
    }
  end

  # ── the rate limit, across instances ─────────────────────────────────

  describe "rate limits are the deployment's, not one instance's" do
    setup do
      installation = System.unique_integer([:positive])
      %{installation: installation, error: %Error{status: 403, message: "rate limited"}}
    end

    test "a limit met here is told to the others", ctx do
      app_id = ctx.app.app_id
      installation = ctx.installation
      Phoenix.PubSub.subscribe(Ravix.PubSub, "github:rate_limit")
      test_pid = self()
      until = Clock.now_ms() + 60_000

      # From another process, because `broadcast_from/4` excludes the sender and
      # the point is what a *sibling* receives.
      spawn(fn ->
        Cache.put_rate_limit(ctx.app.app_id, ctx.installation, until, ctx.error)
        send(test_pid, :put)
      end)

      assert_receive :put, 5_000
      assert_receive {:rate_limit, ^app_id, ^installation, ^until, error}, 5_000
      assert error == ctx.error
    end

    test "a limit met elsewhere is remembered here, without being echoed back", ctx do
      app_id = ctx.app.app_id
      installation = ctx.installation
      Phoenix.PubSub.subscribe(Ravix.PubSub, "github:rate_limit")
      until = Clock.now_ms() + 60_000

      send(Cache, {:rate_limit, ctx.app.app_id, ctx.installation, until, ctx.error})
      :ok = GenServer.call(Cache, :ping)

      assert {:ok, ^until, error} = Cache.rate_limit(ctx.app.app_id, ctx.installation)
      assert error == ctx.error

      # Re-publishing this limit is a loop. Other async cases legitimately
      # broadcast their own limits on the same deployment-wide topic.
      refute_receive {:rate_limit, ^app_id, ^installation, _, _}, 500
    end

    test "and a clearance elsewhere lifts it here", ctx do
      until = Clock.now_ms() + 60_000
      Cache.put_rate_limit_local(ctx.app.app_id, ctx.installation, until, ctx.error)
      assert {:ok, _, _} = Cache.rate_limit(ctx.app.app_id, ctx.installation)

      send(Cache, {:rate_limit_cleared, ctx.app.app_id, ctx.installation})
      :ok = GenServer.call(Cache, :ping)

      assert Cache.rate_limit(ctx.app.app_id, ctx.installation) == :error
    end
  end

  # ── supervision ──────────────────────────────────────────────────────

  describe "the cache's processes" do
    test "are both children of the application supervisor" do
      children =
        Ravix.Supervisor
        |> Supervisor.which_children()
        |> Map.new(fn {id, pid, _type, _mods} -> {id, pid} end)

      assert is_pid(children[Cache])
      assert is_pid(children[Ravix.GitHub.Cache.Checks])
    end

    test "own the tables, so neither is conjured by a caller" do
      assert :ets.info(:ravix_github_cache, :owner) == Process.whereis(Cache)

      assert :ets.info(Ravix.GitHub.Cache.Checks, :owner) ==
               Process.whereis(Ravix.GitHub.Cache.Checks)
    end
  end

  defp pad(n), do: String.pad_leading(Integer.to_string(n), 2, "0")
end
