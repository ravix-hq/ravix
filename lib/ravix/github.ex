defmodule Ravix.GitHub do
  @moduledoc """
  GitHub, in the two roles it plays here.

  **As the App.** A JWT signed with the App's private key buys an installation
  access token, and that token is what clones a private repository onto the
  machine and pushes the branch back. It is scoped to the repositories the
  person chose when they installed, which is the whole reason sign-in is an
  App rather than a plain OAuth app: an OAuth token is scoped to everything
  the person can reach, and a machine that can read every repository you have
  is not a machine you should let an agent loose on.

  **As the identity provider.** The same App has an OAuth client, so "sign in
  with GitHub" and "which repositories may we see" are answers from one
  registration rather than two. `GET /user/installations` with the *user's*
  token is the join: it returns exactly the installations that both the App
  has and this person can see, which is the correct answer to a question that
  is easy to get wrong in the direction of showing somebody else's repos.

  An installation token lives for an hour. That is short enough to matter
  (see `mint_clone_token/2`) and short enough to be worth it.

  Every function takes the `%Ravix.Config.GitHubApp{}` first, as
  `Ravix.Config.github/0` returns it; `nil` there means the App is not
  configured and every call answers `{:error, {:unconfigured, :github}}`,
  the shape `Ravix.Providers` gives every missing integration. Where GitHub
  is (`api_url`, `web_url`) is configurable only so the mock stack can stand
  in for both hosts and the whole app runs offline. In every real deployment
  they are the defaults and nothing sets them.
  """

  alias Ravix.Clock
  alias Ravix.Config.GitHubApp
  alias Ravix.GitHub.{Cache, ChecksReport, Error, HTTP, Shapes}

  @type app :: GitHubApp.t() | nil
  @type error :: {:error, Error.t() | {:unconfigured, :github}}
  @type installation_id :: integer()

  @typedoc "The Checks tab: what GitHub thinks of a branch. See `Ravix.GitHub.ChecksReport`."
  @type checks_report :: ChecksReport.t()

  @typedoc """
  The track a checks report is for, so a reused branch name does not attach a
  previous track's pull request. `created_at` is when the track started;
  `origin_number` is the pull request it was opened from, if any.
  """
  @type track :: %{
          required(:created_at) => DateTime.t() | String.t(),
          required(:origin_number) => integer() | nil
        }

  @typedoc "What `open_pull/4` sends."
  @type pull_input :: %{
          required(:head) => String.t(),
          required(:base) => String.t(),
          required(:title) => String.t(),
          required(:body) => String.t(),
          required(:draft) => boolean()
        }

  # ── the App ──────────────────────────────────────────────────────────

  @doc """
  A ten-minute JWT, which is the longest GitHub accepts.

  `iat` is backdated a minute on purpose: GitHub rejects a JWT whose `iat`
  is in the future by its clock, and two machines' clocks are never quite
  the same. Signed RS256 through JOSE, which takes the PKCS#1 PEM
  ("BEGIN RSA PRIVATE KEY") GitHub issues as well as PKCS#8.
  """
  @spec app_jwt(GitHubApp.t()) :: String.t()
  def app_jwt(%GitHubApp{} = app) do
    now = div(Clock.now_ms(), 1000)
    claims = %{"iat" => now - 60, "exp" => now + 9 * 60, "iss" => app.app_id}
    jwk = JOSE.JWK.from_pem(app.private_key_pem)

    {_, compact} =
      jwk |> JOSE.JWT.sign(%{"alg" => "RS256", "typ" => "JWT"}, claims) |> JOSE.JWS.compact()

    compact
  end

  @typedoc """
  Whether an installation token may come from the cache. `:fresh` mints a
  new one, which is what a clone credential needs: it is handed to a machine
  that will hold it, so it must not be a token already most of the way
  through its hour.
  """
  @type freshness :: :cached | :fresh

  @doc "A token for one installation, good for an hour, cached until it nearly is not."
  @spec installation_token(app(), installation_id(), freshness()) :: {:ok, String.t()} | error()
  def installation_token(app, installation_id, freshness \\ :cached)

  def installation_token(nil, _installation_id, _freshness),
    do: {:error, {:unconfigured, :github}}

  def installation_token(%GitHubApp{} = app, installation_id, freshness)
      when freshness in [:cached, :fresh] do
    now = Clock.now_ms()

    case if(freshness == :fresh, do: :error, else: Cache.token(app.app_id, installation_id)) do
      # `is_integer` is load-bearing: `expires_at_ms` is nil when the response
      # carried no parseable `expires_at`, and in Erlang term order every atom
      # sorts above every integer, so `nil > now` is true and the entry would
      # be honoured forever -- long past the point GitHub stopped accepting it.
      {:ok, token, expires_at_ms}
      when is_integer(expires_at_ms) and expires_at_ms > now + 60_000 ->
        {:ok, token}

      _ ->
        with {:ok, body} <-
               HTTP.request(app, :post, "/app/installations/#{installation_id}/access_tokens",
                 auth: "Bearer " <> app_jwt(app)
               ) do
          token = body["token"]
          Cache.put_token(app.app_id, installation_id, token, iso_to_ms(body["expires_at"]))
          {:ok, token}
        end
    end
  end

  @doc """
  The token that goes onto a machine so git can clone and push.

  Named separately from `installation_token/3` because the call sites mean
  different things and one of them has a deadline: this token is written
  into the project's vault, and Fountain hands the vault to the sandbox when
  a session starts. An hour later it is dead. So every path that is about to
  make the machine talk to GitHub (opening a track, sending a turn) re-mints
  first. Bypass the cache so a turn cannot inherit a token with only a minute
  left. Turns longer than an hour still need renewal.
  """
  @spec mint_clone_token(app(), installation_id()) :: {:ok, String.t()} | error()
  def mint_clone_token(app, installation_id),
    do: installation_token(app, installation_id, :fresh)

  # ── signing somebody in ──────────────────────────────────────────────

  @doc """
  Where a browser goes to sign in. `state` is ours and comes back untouched.

  A GitHub App's user token gets its repository access from the
  installation, not from scopes. `read:user` is only so that a person with
  no public email still resolves to a name in the sidebar.
  """
  @spec authorize_url(GitHubApp.t(), String.t(), String.t()) :: String.t()
  def authorize_url(%GitHubApp{} = app, redirect_uri, state) do
    query =
      URI.encode_query(
        client_id: app.client_id,
        redirect_uri: redirect_uri,
        state: state,
        scope: "read:user"
      )

    "#{app.web_url}/login/oauth/authorize?#{query}"
  end

  @doc "Where a browser goes to install the App, or to change which repos it sees."
  @spec install_url(GitHubApp.t(), String.t() | nil) :: String.t()
  def install_url(%GitHubApp{} = app, state \\ nil) do
    query = if state, do: "?" <> URI.encode_query(state: state), else: ""
    "#{app.web_url}/apps/#{app.slug}/installations/new#{query}"
  end

  @doc """
  The user's token for the code the callback brought back.

  GitHub answers 200 with an error body here, so the status is not the
  check. `bad_verification_code` is the ordinary one: a reloaded callback,
  or a code already spent.

  The one request to `web_url` rather than `api_url`, and it still goes
  through `Ravix.GitHub.HTTP.request/4`: an absolute path is sent as it is,
  the endpoint speaks plain JSON rather than the API's media type, and the
  credential is the client secret in the body, so no `:auth`. A status that
  is not 2xx, and a GitHub that does not answer, are then the same
  `%Ravix.GitHub.Error{}` every other call produces.
  """
  @spec exchange_code(app(), String.t(), String.t()) :: {:ok, String.t()} | error()
  def exchange_code(nil, _code, _redirect_uri), do: {:error, {:unconfigured, :github}}

  def exchange_code(%GitHubApp{} = app, code, redirect_uri) do
    body = %{
      client_id: app.client_id,
      client_secret: app.client_secret,
      code: code,
      redirect_uri: redirect_uri
    }

    with {:ok, answer} <-
           HTTP.request(app, :post, "#{app.web_url}/login/oauth/access_token",
             accept: "application/json",
             json: body
           ) do
      exchanged(answer)
    end
  end

  defp exchanged(%{"access_token" => token}) when is_binary(token), do: {:ok, token}

  defp exchanged(answer) do
    message =
      case answer do
        %{"error_description" => why} when is_binary(why) -> why
        %{"error" => why} when is_binary(why) -> why
        _ -> "GitHub would not exchange that code."
      end

    {:error, %Error{status: 400, message: message}}
  end

  @doc """
  One GitHub account, by login, read as the App itself. `{:ok, nil}` when
  there is no such account.

  Used to invite somebody who has never signed in here: without this, an
  invitation could only name a row we already had, and the first person you
  want to work with is by definition not one of them. Reading it as the App
  rather than as the caller means the answer does not depend on whose token
  asked, and the numeric id it returns is what the invitation is stored
  against (see `track_invites`).
  """
  @spec user_by_login(app(), String.t()) :: {:ok, Shapes.Account.t() | nil} | error()
  def user_by_login(nil, _login), do: {:error, {:unconfigured, :github}}

  def user_by_login(%GitHubApp{} = app, login) do
    case HTTP.request(app, :get, "/users/#{encode(login)}", auth: "Bearer " <> app_jwt(app)) do
      {:ok, raw} -> {:ok, Shapes.account(raw)}
      {:error, %Error{status: 404}} -> {:ok, nil}
      {:error, _} = error -> error
    end
  end

  @doc "The person a user token belongs to."
  @spec viewer(app(), String.t()) :: {:ok, Shapes.Account.t()} | error()
  def viewer(nil, _user_token), do: {:error, {:unconfigured, :github}}

  def viewer(%GitHubApp{} = app, user_token) do
    with {:ok, raw} <- HTTP.request(app, :get, "/user", user_token: user_token) do
      {:ok, Shapes.account(raw)}
    end
  end

  # ── what this person can see ─────────────────────────────────────────

  @doc """
  The installations this person can see *and* this App has.

  The intersection is the point. Asking the App for its installations would
  list every account that has ever installed ravix; asking the user's token
  for theirs lists only the ones they are a member of. The second question
  is the one the repository picker is actually asking.
  """
  @spec installations_for(app(), String.t()) :: {:ok, [Shapes.Installation.t()]} | error()
  def installations_for(nil, _user_token), do: {:error, {:unconfigured, :github}}

  def installations_for(%GitHubApp{} = app, user_token) do
    with {:ok, body} <-
           HTTP.request(app, :get, "/user/installations?per_page=100",
             user_token: user_token,
             cache_ttl: 30_000
           ) do
      {:ok, Enum.map(body["installations"] || [], &Shapes.installation/1)}
    end
  end

  @doc """
  Every repository this person's installations grant, newest activity first.

  Sorted by `pushed_at` rather than by name, because the picker is opened by
  somebody who wants the thing they were just working on and the alphabet
  has no opinion about that. Paged to a thousand: an installation with more
  repositories than that wants a search box, which the picker has. Display
  reads are cached for 30 seconds; `:fresh` bypasses the cache for access checks.
  """
  @spec repositories(app(), String.t(), installation_id(), freshness()) ::
          {:ok, [Shapes.RepoRef.t()]} | error()
  def repositories(app, user_token, installation_id, freshness \\ :cached)

  def repositories(nil, _user_token, _installation_id, _freshness),
    do: {:error, {:unconfigured, :github}}

  def repositories(%GitHubApp{} = app, user_token, installation_id, freshness)
      when freshness in [:cached, :fresh] do
    opts = if freshness == :cached, do: [cache_ttl: 30_000], else: []

    with {:ok, repos} <- repository_pages(app, user_token, installation_id, 1, [], opts) do
      {:ok, Enum.sort_by(repos, &(&1.pushed_at || ""), :desc)}
    end
  end

  defp repository_pages(_app, _token, _installation_id, page, acc, _opts) when page > 10,
    do: {:ok, acc}

  defp repository_pages(app, user_token, installation_id, page, acc, opts) do
    path = "/user/installations/#{installation_id}/repositories?per_page=100&page=#{page}"

    with {:ok, body} <- HTTP.request(app, :get, path, Keyword.put(opts, :user_token, user_token)) do
      batch = Enum.map(body["repositories"] || [], &Shapes.repo_ref(&1, installation_id))
      acc = acc ++ batch

      if length(batch) < 100,
        do: {:ok, acc},
        else: repository_pages(app, user_token, installation_id, page + 1, acc, opts)
    end
  end

  @doc "One repository, read as the installation, so it works for private ones."
  @spec repository(app(), installation_id(), String.t()) :: {:ok, Shapes.RepoRef.t()} | error()
  def repository(nil, _installation_id, _full_name), do: {:error, {:unconfigured, :github}}

  def repository(%GitHubApp{} = app, installation_id, full_name) do
    with {:ok, raw} <- as_installation(app, installation_id, :get, "/repos/#{full_name}") do
      {:ok, Shapes.repo_ref(raw, installation_id)}
    end
  end

  # ── the three ways to start a track ──────────────────────────────────

  @doc "The branches of a repository, the default one first, then by name."
  @spec branches(app(), installation_id(), String.t(), String.t()) ::
          {:ok, [Shapes.BranchRef.t()]} | error()
  def branches(nil, _installation_id, _full_name, _default_branch),
    do: {:error, {:unconfigured, :github}}

  def branches(%GitHubApp{} = app, installation_id, full_name, default_branch) do
    path = "/repos/#{full_name}/branches?per_page=100"

    with {:ok, raw} <- as_installation(app, installation_id, :get, path, cache_ttl: 60_000) do
      refs =
        raw
        |> Enum.map(&Shapes.branch_ref(&1, default_branch))
        |> Enum.sort_by(&{not &1.is_default, &1.name})

      {:ok, refs}
    end
  end

  @doc "Open pull requests, most recently updated first."
  @spec pulls(app(), installation_id(), String.t()) :: {:ok, [Shapes.PullRef.t()]} | error()
  def pulls(nil, _installation_id, _full_name), do: {:error, {:unconfigured, :github}}

  def pulls(%GitHubApp{} = app, installation_id, full_name) do
    path = "/repos/#{full_name}/pulls?state=open&sort=updated&direction=desc&per_page=50"

    with {:ok, raw} <- as_installation(app, installation_id, :get, path, cache_ttl: 60_000) do
      {:ok, Enum.map(raw, &Shapes.pull_ref/1)}
    end
  end

  @doc """
  Open issues, without the pull requests.

  GitHub's issues endpoint returns pull requests too (they are issues as far
  as the data model is concerned) and a picker with a PRs tab beside an
  Issues tab showing the same rows twice is a bug people notice immediately.
  """
  @spec issues(app(), installation_id(), String.t()) :: {:ok, [Shapes.IssueRef.t()]} | error()
  def issues(nil, _installation_id, _full_name), do: {:error, {:unconfigured, :github}}

  def issues(%GitHubApp{} = app, installation_id, full_name) do
    path = "/repos/#{full_name}/issues?state=open&sort=updated&direction=desc&per_page=50"

    with {:ok, raw} <- as_installation(app, installation_id, :get, path, cache_ttl: 60_000) do
      {:ok,
       raw |> Enum.reject(&Map.has_key?(&1, "pull_request")) |> Enum.map(&Shapes.issue_ref/1)}
    end
  end

  # ── what GitHub thinks of a branch ───────────────────────────────────

  @doc """
  The Checks tab.

  A branch that has never been pushed is the ordinary case in a new track,
  not an error, so `pushed: false` is a first-class answer and the panel
  renders "nothing pushed yet" rather than an empty list that looks broken.

  Reports are shared and cached for five minutes (see `Ravix.GitHub.Cache`).
  `track` narrows which pull request counts as this branch's; see `t:track/0`.
  """
  @spec checks(app(), installation_id(), String.t(), String.t(), track() | nil) ::
          {:ok, checks_report()} | error()
  def checks(app, installation_id, full_name, ref, track \\ nil)

  def checks(nil, _installation_id, _full_name, _ref, _track),
    do: {:error, {:unconfigured, :github}}

  def checks(%GitHubApp{} = app, installation_id, full_name, ref, track) do
    created_at_ms = if track, do: to_ms(track.created_at)
    origin_number = if track, do: track.origin_number
    key = {installation_id, full_name, ref, created_at_ms, origin_number}

    Cache.checks(app.app_id, key, Clock.now_ms(), fn ->
      read_checks(app, installation_id, full_name, ref, created_at_ms, origin_number)
    end)
  end

  defp read_checks(app, installation_id, full_name, ref, created_at_ms, origin_number) do
    with {:ok, sha} <- branch_sha(app, installation_id, full_name, ref),
         {:ok, runs} <- check_runs(app, installation_id, full_name, sha),
         {:ok, pulls} <- pulls_for_head(app, installation_id, full_name, ref) do
      {:ok,
       %ChecksReport{
         ref: ref,
         sha: sha,
         pushed: sha != nil,
         runs: Enum.map(runs, &Shapes.check_run/1),
         pull: choose_pull(pulls, ref, created_at_ms, origin_number)
       }}
    end
  end

  # Merged PRs remain useful after GitHub deletes their head branch, so a
  # missing branch is `nil`, not a failure.
  defp branch_sha(app, installation_id, full_name, ref) do
    case as_installation(
           app,
           installation_id,
           :get,
           "/repos/#{full_name}/branches/#{encode(ref)}"
         ) do
      {:ok, branch} -> {:ok, get_in(branch, ["commit", "sha"])}
      {:error, %Error{status: 404}} -> {:ok, nil}
      {:error, _} = error -> error
    end
  end

  defp check_runs(_app, _installation_id, _full_name, nil), do: {:ok, []}

  defp check_runs(app, installation_id, full_name, sha) do
    path = "/repos/#{full_name}/commits/#{sha}/check-runs?per_page=50"

    with {:ok, body} <- as_installation(app, installation_id, :get, path) do
      {:ok, body["check_runs"] || []}
    end
  end

  # `state=all`, not `state=open`. A branch whose pull request has been
  # merged is the *most* interesting case (it is the one where the work
  # landed) and asking only for open ones answered "no pull request for this
  # branch" beside two green checks that plainly came from one.
  defp pulls_for_head(app, installation_id, full_name, ref) do
    [owner | _] = String.split(full_name, "/")
    head = encode(owner <> ":" <> ref)

    as_installation(
      app,
      installation_id,
      :get,
      "/repos/#{full_name}/pulls?state=all&per_page=20&head=#{head}"
    )
  end

  # An open one if there is one, else the most recently updated, which for a
  # finished branch is the pull request that merged it. A reused branch name
  # must not attach a previous track's PR. Explicit PR tracks keep their
  # original PR even when it predates the conversation.
  defp choose_pull(pulls, ref, created_at_ms, origin_number) do
    pulls
    |> Enum.filter(&eligible_pull?(&1, ref, created_at_ms, origin_number))
    |> Enum.sort_by(&{Shapes.pull_state(&1) != :open, negate(&1["updated_at"] || "")})
    |> List.first()
    |> case do
      nil -> nil
      raw -> Shapes.pull_ref(raw)
    end
  end

  defp eligible_pull?(p, ref, created_at_ms, origin_number) do
    cond do
      get_in(p, ["head", "ref"]) != ref -> false
      is_nil(created_at_ms) -> true
      not is_nil(origin_number) -> p["number"] == origin_number
      # GitHub timestamps have second precision; ours include microseconds.
      true -> pull_created_ms(p) >= div(created_at_ms, 1000) * 1000
    end
  end

  defp pull_created_ms(%{"created_at" => iso}) when is_binary(iso), do: iso_to_ms(iso) || -1
  defp pull_created_ms(_), do: -1

  # A sort key that orders strings descending without `Enum.sort_by/3`'s
  # comparator, so it composes with the ascending half of the tuple.
  defp negate(string), do: string |> String.to_charlist() |> Enum.map(&(-&1))

  @doc """
  Open a pull request for a branch the machine has already pushed.

  Any checks report for that branch is dropped, so the panel shows the new
  pull request on its next read rather than five minutes from now.
  """
  @spec open_pull(app(), installation_id(), String.t(), pull_input()) ::
          {:ok, Shapes.PullRef.t()} | error()
  def open_pull(nil, _installation_id, _full_name, _input), do: {:error, {:unconfigured, :github}}

  def open_pull(%GitHubApp{} = app, installation_id, full_name, %{head: head} = input) do
    body = Map.take(input, [:head, :base, :title, :body, :draft])

    with {:ok, raw} <-
           as_installation(app, installation_id, :post, "/repos/#{full_name}/pulls", json: body) do
      Cache.drop_checks(app.app_id, fn
        {^installation_id, ^full_name, ^head, _, _} -> true
        _ -> false
      end)

      {:ok, Shapes.pull_ref(raw)}
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  # A request as the installation: mint (or reuse) its token first, and
  # remember any rate limit against it.
  defp as_installation(app, installation_id, method, path, opts \\ []) do
    with {:ok, token} <- installation_token(app, installation_id) do
      HTTP.request(
        app,
        method,
        path,
        Keyword.merge(opts, auth: "Bearer " <> token, installation_id: installation_id)
      )
    end
  end

  # `encodeURIComponent`: only the unreserved characters survive.
  defp encode(string), do: URI.encode(string, &URI.char_unreserved?/1)

  defp to_ms(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)
  defp to_ms(iso) when is_binary(iso), do: iso_to_ms(iso)

  defp iso_to_ms(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} ->
        DateTime.to_unix(dt, :millisecond)

      {:error, _} ->
        # `Date.parse` accepts a bare date; so do we.
        case Date.from_iso8601(iso) do
          {:ok, date} -> date |> DateTime.new!(~T[00:00:00]) |> DateTime.to_unix(:millisecond)
          {:error, _} -> nil
        end
    end
  end

  defp iso_to_ms(_), do: nil
end
