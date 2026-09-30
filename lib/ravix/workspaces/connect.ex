defmodule Ravix.Workspaces.Connect do
  @moduledoc """
  Connecting a GitHub App installation to a workspace (ADR 0009, phase 4b).

  A workspace owner or admin presses "Connect GitHub": `begin/3` parks a
  round trip and returns GitHub's install/configure page, carrying a state
  that names the workspace. GitHub sends the browser back to the App's
  setup URL (`/api/auth/callback`) with the `installation_id` the person
  installed or configured, and `finish/4` binds it to that workspace.

  The completed flow is the authority (owner decision 4): no personal
  GitHub token is read or kept. What makes the callback trustworthy is the
  state, which is

    * **bound to its workspace, person and session.** Only a hash of the
      nonce together with those three is stored, so a state finishes only
      for the workspace written in it, by the person who began it, in the
      browser session that began it;
    * **single-use.** The row is deleted by the statement that finds it, so
      a replayed callback finds nothing;
    * **short-lived.** Fifteen minutes, as the sign-in state is.

  The state proves who began the flow; it does not prove the installation
  is theirs, because the `installation_id` arrives in the query string and
  any id of this App's installations would pass a lookup as the App. So the
  callback must also carry the user-to-server `code` GitHub sends to the
  setup URL when the App has "Request user authorization (OAuth) during
  installation" on. It is exchanged, the returning person's own
  `GET /user/installations` is read with it, and the installation is bound
  only if it is in that list. The token is then dropped: nothing personal
  is stored. A callback without a `code` is refused.

  The caller must still hold `:connect_repos` in the workspace when the
  callback lands. One installation may be connected to several workspaces,
  each by its own round trip. Binding it refreshes that workspace's catalog
  (`Ravix.Workspaces.Repositories`).

  An owner may also add, in one click, an installation GitHub already says
  they can see (`available/2`, `add/3`, RAV-69): the same proof, read with
  the token they signed in with instead of a round trip's `code`.
  """

  alias Ravix.Accounts.{Access, Auth, User}
  alias Ravix.Crypto
  alias Ravix.Workspaces.{Installation, Repositories, Store}

  @max_age_s 15 * 60
  @prefix "ws."

  @type reason ::
          :not_found
          | :stale
          | {:forbidden, String.t()}
          | {:unprocessable, String.t(), String.t()}
          | {:unconfigured, :github}
          | Ravix.GitHub.Error.t()

  @doc """
  Begin connecting GitHub to a workspace: where to send the browser.
  Owners and admins, behind `RAVIX_WORKSPACE_ACCESS`; `session_hash` is the
  caller's browser session, which the callback must present again.
  """
  @spec begin(User.t(), String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, reason()}
  def begin(%User{} = user, workspace_id, session_hash) when is_binary(session_hash) do
    with {:ok, app} <- Ravix.Providers.github(),
         {:ok, %{workspace: workspace}} <-
           Access.workspace_grant(user, workspace_id, :connect_repos) do
      nonce = Crypto.random_token(18)
      key = key(nonce, workspace.id, user.id, session_hash)
      :ok = Store.put_connect_state(key, workspace.id, user.id, @max_age_s)
      {:ok, Ravix.GitHub.install_url(app, @prefix <> workspace.id <> "." <> nonce)}
    end
  end

  def begin(%User{}, _workspace_id, _session_hash), do: {:error, :not_found}

  @doc "Whether a callback's `state` is a connect round trip's rather than sign-in's."
  @spec state?(term()) :: boolean()
  def state?(@prefix <> _rest), do: true
  def state?(_state), do: false

  @doc """
  The workspace a connect `state` names, unverified but well-formed (a
  UUID): where to send the browser back. Nil for anything else.
  """
  @spec workspace_of(term()) :: String.t() | nil
  def workspace_of(state) do
    # `Ecto.UUID.cast/1` also takes any 16-byte binary as a raw UUID, so
    # only the 36-character text form is let through.
    with {:ok, workspace_id, _nonce} <- parse(state),
         36 <- byte_size(workspace_id),
         {:ok, uuid} <- Ecto.UUID.cast(workspace_id) do
      uuid
    else
      _ -> nil
    end
  end

  @doc """
  Finish a connect round trip: bind `installation_id` to the workspace the
  state names, once GitHub's `code` proves the returning person can see
  that installation. The state is spent first, whatever happens after, so
  it cannot be tried twice. Answers the workspace id.

  `:stale` for a state that is unknown, spent, expired, or minted for
  another workspace, person or session; not found when the caller no
  longer manages the workspace; `no_authorization` without a `code`;
  `not_your_installation` when the installation is not among the returning
  person's own.
  """
  @spec finish(User.t(), String.t() | nil, term(), term(), term()) ::
          {:ok, String.t()} | {:error, reason()}
  def finish(%User{} = user, session_hash, state, installation_id, code)
      when is_binary(session_hash) do
    with {:ok, workspace_id, nonce} <- parse(state) |> stale(),
         %{} = row <-
           Store.take_connect_state(key(nonce, workspace_id, user.id, session_hash), @max_age_s) ||
             {:error, :stale},
         {:ok, %{workspace: workspace}} <-
           Access.workspace_grant(user, row.workspace_id, :connect_repos),
         {:ok, installation_id} <- installation_id(installation_id),
         {:ok, code} <- code(code),
         {:ok, app} <- Ravix.Providers.github(),
         {:ok, found} <- theirs(app, code, installation_id) do
      {:ok, _binding} =
        Store.bind_installation(workspace.id, installation_id, found.account, user.id)

      # The catalog is best-effort here: the connection stands, and the
      # workspace page offers a refresh when GitHub was not answering.
      _ = Repositories.refresh_unchecked(workspace.id)
      Ravix.Hub.publish_workspace(workspace.id, :members)
      {:ok, workspace.id}
    end
  end

  def finish(%User{}, _session_hash, _state, _installation_id, _code), do: {:error, :stale}

  # ── Add to workspace (RAV-69) ──────────────────────────────────────────

  @doc """
  What "Add to workspace" offers: the installations of the Ravix App the
  caller can see on GitHub themselves, read with their own sign-in token,
  that the workspace does not use yet. A connection that was revoked or
  suspended is offered again; a live one is not.

  Owners only (`:add_installations`). Nothing is connected by reading this,
  and an installation the caller cannot see is never offered: this is the
  explicit half of RAV-69, beside the automatic
  `Ravix.Workspaces.Store.attach_backing_installations/2`.
  """
  @spec available(User.t(), String.t()) ::
          {:ok, [Ravix.GitHub.Shapes.Installation.t()]} | {:error, reason()}
  def available(%User{} = user, workspace_id) do
    with {:ok, %{workspace: workspace}} <-
           Access.workspace_grant(user, workspace_id, :add_installations),
         {:ok, app} <- Ravix.Providers.github(),
         {:ok, visible} <- visible(app, user, :cached) do
      live =
        for installation <- Store.installations(workspace.id),
            Installation.status(installation) == :active,
            into: MapSet.new(),
            do: installation.installation_id

      {:ok, Enum.reject(visible, &MapSet.member?(live, &1.id))}
    end
  end

  @doc """
  Where "Configure on GitHub" goes: the App's page on GitHub, which lists
  the accounts it is installed on and changes which repositories each
  lets it read. Owners and admins (`:connect_repos`). No state rides on
  it, so coming back connects nothing; Refresh reads the change.
  """
  @spec configure_url(User.t(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  def configure_url(%User{} = user, workspace_id) do
    with {:ok, _access} <- Access.workspace_grant(user, workspace_id, :connect_repos),
         {:ok, app} <- Ravix.Providers.github() do
      {:ok, Ravix.GitHub.install_url(app)}
    end
  end

  @doc """
  Connect one of the caller's own installations to a workspace, in one
  click: no round trip to GitHub's install page. Owners only; the
  installation must be among the ones GitHub says the caller can see, read
  again, uncached, with their own token at the moment they press it. A
  personal account is connected only this way, never automatically.

  Refreshes the workspace's catalog and tells its open pages, as `finish/5`
  does. Answers the connection.
  """
  @spec add(User.t(), String.t(), term()) :: {:ok, Installation.t()} | {:error, reason()}
  def add(%User{} = user, workspace_id, installation_id) do
    with {:ok, %{workspace: workspace}} <-
           Access.workspace_grant(user, workspace_id, :add_installations),
         {:ok, installation_id} <- installation_id(installation_id),
         {:ok, app} <- Ravix.Providers.github(),
         {:ok, visible} <- visible(app, user, :fresh),
         {:ok, found} <- among(visible, installation_id) do
      {:ok, binding} =
        Store.bind_installation(workspace.id, installation_id, found.account, user.id)

      _ = Repositories.refresh_unchecked(workspace.id)
      Ravix.Hub.publish_workspace(workspace.id, :members)
      {:ok, binding}
    end
  end

  defp visible(app, user, freshness) do
    case Ravix.Accounts.user_token(user) do
      {:ok, token} ->
        Ravix.GitHub.installations_for(app, token, freshness)

      {:error, _no_token} ->
        {:error,
         {:unprocessable, "no_github_token",
          "Sign in with GitHub again so Ravix can see your GitHub accounts."}}
    end
  end

  defp among(visible, installation_id) do
    case Enum.find(visible, &(&1.id == installation_id)) do
      nil ->
        {:error,
         {:unprocessable, "not_your_installation",
          "That GitHub installation is not one you can see, so it cannot be added here."}}

      found ->
        {:ok, found}
    end
  end

  # The returning person's own installations, read with the token their
  # `code` buys and then forgotten: the ownership proof, not a credential.
  defp theirs(app, code, installation_id) do
    with {:ok, token} <-
           Ravix.GitHub.exchange_code(app, code, Auth.callback_url()),
         {:ok, installations} <- Ravix.GitHub.installations_for(app, token) do
      case Enum.find(installations, &(&1.id == installation_id)) do
        nil ->
          {:error,
           {:unprocessable, "not_your_installation",
            "That GitHub installation is not one you can see, so it cannot be connected here."}}

        found ->
          {:ok, found}
      end
    end
  end

  defp code(code) when is_binary(code) and code != "", do: {:ok, code}

  defp code(_code),
    do:
      {:error,
       {:unprocessable, "no_authorization",
        "GitHub did not confirm who installed the App. Connect GitHub again."}}

  defp parse(@prefix <> rest) do
    case String.split(rest, ".", parts: 2) do
      [workspace_id, nonce] when workspace_id != "" and nonce != "" -> {:ok, workspace_id, nonce}
      _ -> :error
    end
  end

  defp parse(_state), do: :error

  defp stale(:error), do: {:error, :stale}
  defp stale(ok), do: ok

  defp installation_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp installation_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> installation_id(nil)
    end
  end

  defp installation_id(_id),
    do:
      {:error,
       {:unprocessable, "no_installation", "GitHub did not say which installation to connect."}}

  defp key(nonce, workspace_id, user_id, session_hash),
    do: Crypto.sha256(Enum.join([nonce, workspace_id, user_id, session_hash], "\n"))
end
