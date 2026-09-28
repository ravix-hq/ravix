defmodule Ravix.WorkspaceGitHubFixture do
  @moduledoc """
  GitHub and Fountain as a workspace's connection and admission meet them
  (ADR 0009 phase 4b), in the shapes they really answer with.

  `github/1` installs `Ravix.GitHubFake` routes for a map of installations:
  `GET /app/installations/:id` read as the App (404 once `gone: true`, a
  `suspended_at` once `suspended: true`), installation tokens named after
  their installation (`inst-<id>`), and `GET /installation/repositories`,
  which answers for whichever installation's token asked, and
  `GET /repos/:owner/:repo` likewise. Call it again to change GitHub under
  a test.

  `users` maps an OAuth `code` to the installation ids its person can see:
  the code exchanges for a token (`user-<code>`), and `GET
  /user/installations` with that token lists exactly those. A code not in
  the map is GitHub's `bad_verification_code`. `provisioning/1` scripts the Fountain calls one project admission
  makes.
  """

  alias Ravix.Fountain.FakeTransport
  alias Ravix.GitHubFake, as: GH

  @catalog %{"runtimes" => ["codex"], "models" => %{"codex" => ["openai/test-model"]}}

  @doc "A repository as GitHub's REST API returns it."
  @spec repo(integer(), String.t(), keyword()) :: map()
  def repo(id, full_name, opts \\ []) do
    [owner, name] = String.split(full_name, "/")

    %{
      "id" => id,
      "node_id" => "R_#{id}",
      "name" => name,
      "full_name" => full_name,
      "private" => Keyword.get(opts, :private, true),
      "owner" => %{"login" => owner, "id" => 1000 + id, "type" => "Organization"},
      "html_url" => "https://github.com/#{full_name}",
      "description" => nil,
      "default_branch" => Keyword.get(opts, :default_branch, "main"),
      "pushed_at" => Keyword.get(opts, :pushed_at, "2026-09-01T00:00:00Z"),
      "language" => "Elixir"
    }
  end

  @doc """
  Route GitHub for `installations`: `%{id => %{account: login, repos: [repo],
  suspended: bool, gone: bool}}`. Returns the App.
  """
  @spec github(%{integer() => map()}, %{String.t() => [integer()]}) ::
          Ravix.Config.GitHubApp.t()
  def github(installations, users \\ %{}) do
    app = Process.get({__MODULE__, :app}) || GH.app()
    Process.put({__MODULE__, :app}, app)

    GH.install([
      {"POST", ~r{^/app/installations/\d+/access_tokens$}, &token(&1, installations)},
      {"GET", ~r{^/app/installations/\d+$}, &installation(&1, installations)},
      {"GET", "/installation/repositories", &repositories(&1, installations)},
      {"GET", ~r{^/repos/[^/]+/[^/]+$}, &one_repo(&1, installations)},
      {"POST", "/login/oauth/access_token", &exchange(&1, users)},
      {"GET", "/user/installations", &user_installations(&1, installations, users)}
    ])

    app
  end

  defp token(conn, installations) do
    [_, id] = Regex.run(~r{/app/installations/(\d+)/}, conn.request_path)

    case Map.get(installations, String.to_integer(id)) do
      %{gone: true} ->
        not_found(conn)

      _ ->
        expires = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
        Req.Test.json(conn, %{"token" => "inst-#{id}", "expires_at" => expires})
    end
  end

  defp installation(conn, installations) do
    id = conn.request_path |> String.split("/") |> List.last() |> String.to_integer()

    case Map.get(installations, id) do
      %{gone: true} -> not_found(conn)
      nil -> not_found(conn)
      inst -> Req.Test.json(conn, installation_body(id, inst))
    end
  end

  defp installation_body(id, inst) do
    %{
      "id" => id,
      "account" => %{"login" => inst.account, "id" => id + 50, "type" => "Organization"},
      "app_id" => 1,
      "target_type" => "Organization",
      "repository_selection" => "selected",
      "permissions" => %{"contents" => "write", "metadata" => "read"},
      "suspended_at" => if(inst[:suspended], do: "2026-09-27T12:00:00Z"),
      "suspended_by" => nil
    }
  end

  defp repositories(conn, installations) do
    conn = Plug.Conn.fetch_query_params(conn)

    page = String.to_integer(conn.query_params["page"] || "1")

    repos =
      case Process.get({__MODULE__, :failing_page}) do
        ^page -> :fail
        _ -> conn |> repos_for(installations) |> Enum.slice((page - 1) * 100, 100)
      end

    case repos do
      :fail ->
        conn |> Plug.Conn.put_status(502) |> Req.Test.json(%{"message" => "Bad Gateway"})

      repos ->
        Req.Test.json(conn, %{"total_count" => length(repos), "repositories" => repos})
    end
  end

  @doc "Make `GET /installation/repositories` fail on `page` (nil: never) for this test."
  @spec fail_page(pos_integer() | nil) :: :ok
  def fail_page(page) do
    Process.put({__MODULE__, :failing_page}, page)
    :ok
  end

  defp one_repo(conn, installations) do
    "/repos/" <> full_name = conn.request_path
    wanted = String.downcase(full_name)

    case Enum.find(repos_for(conn, installations), &(String.downcase(&1["full_name"]) == wanted)) do
      nil -> not_found(conn)
      repo -> Req.Test.json(conn, repo)
    end
  end

  # GitHub answers 200 with an error body for a code it will not exchange.
  defp exchange(conn, users) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    code = Jason.decode!(raw)["code"]

    if Map.has_key?(users, code),
      do: Req.Test.json(conn, %{"access_token" => "user-#{code}", "token_type" => "bearer"}),
      else:
        Req.Test.json(conn, %{
          "error" => "bad_verification_code",
          "error_description" => "The code passed is incorrect or expired."
        })
  end

  defp user_installations(conn, installations, users) do
    ["Bearer user-" <> code] = Plug.Conn.get_req_header(conn, "authorization")

    listed =
      for id <- Map.get(users, code, []) do
        account = get_in(installations, [id, :account]) || "someone"

        %{
          "id" => id,
          "account" => %{"login" => account, "id" => id + 50, "avatar_url" => nil},
          "app_id" => 1,
          "target_type" => "Organization"
        }
      end

    Req.Test.json(conn, %{"total_count" => length(listed), "installations" => listed})
  end

  defp repos_for(conn, installations) do
    ["Bearer inst-" <> id] = Plug.Conn.get_req_header(conn, "authorization")
    installations |> Map.get(String.to_integer(id), %{}) |> Map.get(:repos, [])
  end

  defp not_found(conn),
    do: conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})

  @doc """
  Fountain, scripted for `admissions` project admissions (and for the last
  `unwound` of them to be taken back). Stubs `Ravix.Fountain.client/0`; the caller
  must `use Mimic`.

  `on_agent:` runs just before Fountain answers the agent's creation: the
  moment between admission's checks and its insert, for a test to race.
  """
  @spec provisioning(non_neg_integer(), non_neg_integer(), keyword()) ::
          Ravix.Fountain.Client.t()
  def provisioning(admissions \\ 1, unwound \\ 0, opts \\ []) do
    on_agent = Keyword.get(opts, :on_agent, fn -> :ok end)

    one = fn n ->
      [
        {%{method: "GET", path: "/api/catalog"}, {200, [], %{data: @catalog}}},
        {%{method: "GET", path: "/api/account/inference-credential-sets"},
         {200, [], %{data: [%{id: "set-me", providers: ["anthropic_api_key", "openai_api_key"]}]}}},
        {%{method: "POST", path: "/api/environments"}, {201, [], %{data: %{id: "env-#{n}"}}}},
        {%{method: "POST", path: "/api/vaults"}, {201, [], %{data: %{id: "vault-#{n}"}}}},
        {%{method: "POST", path: "/api/vaults/vault-#{n}/secrets"},
         {201, [], %{data: %{key: "GITHUB_TOKEN"}}}},
        {%{method: "POST", path: "/api/agents"},
         fn _call ->
           on_agent.()
           {201, [], %{data: %{id: "agent-#{n}"}}}
         end}
      ]
    end

    undo = fn n ->
      [
        {%{method: "DELETE", path: "/api/agents/agent-#{n}"}, {204, [], ""}},
        {%{method: "DELETE", path: "/api/vaults/vault-#{n}"}, {204, [], ""}},
        {%{method: "DELETE", path: "/api/environments/env-#{n}"}, {204, [], ""}}
      ]
    end

    script =
      Enum.flat_map(1..admissions//1, one) ++
        Enum.flat_map((admissions - unwound + 1)..admissions//1, undo)

    client = FakeTransport.client(script)
    Mimic.stub(Ravix.Fountain, :client, fn -> client end)
    client
  end
end
