defmodule Ravix.Accounts.Inference do
  @moduledoc """
  A person's own agent subscription, and where Ravix keeps it.

  Every machine used to run on the deployment's Fountain credentials, which is
  what "the turns are on the house" on the sign-in page meant. Now each person
  brings what pays for their agent: a Claude subscription's token or an
  Anthropic key for Claude Code, an OpenAI key for Codex.

  ## Where the value goes

  Not here. Ravix is one Fountain account for everybody
  (`Ravix.Fountain`'s moduledoc), so a person's subscription cannot be that
  account's credential. Fountain's answer is an *inference credential set*: a
  named group of provider credentials on the account, which an agent is pointed
  at by id. Each person gets one, named after their Ravix id, made the first
  time they connect anything. The value is written into it and cannot be read
  back by anybody, this application included; what the row keeps is the set's
  id, which agent they chose, and whether it was a subscription or a key.

  ## Who pays

  The project's owner, for everything that happens in it.
  `Ravix.Projects.Machine` builds a project's agent pointing at its *owner's*
  set, so a teammate's turns in that project spend the owner's plan, and a
  teammate needs no subscription of their own to be useful. That is also the
  only arrangement Codex allows: Fountain binds a Codex machine to one
  credential for the machine's whole life, and a project is one machine.

  ## Replacing a credential ends open conversations

  Fountain binds a conversation to the *revision* of the set it started on and
  refuses the next prompt (`inference_source_changed`) once that set has been
  written to, rather than quietly spending a different credential than the one
  the conversation began with. The revision covers the whole set. So any
  `connect/2` after the first ends that person's open tracks, in every project
  they own, and the page says so before they press the button. It is also why
  this module writes as little as it can: switching between a subscription and
  a key for the same agent removes the other one (Claude Code prefers the
  token when it finds both, so leaving it would make the choice a lie), and
  switching *agent* removes nothing, because projects built on the other agent
  are still running on what is there.

  ## Codex on a ChatGPT subscription

  A ChatGPT subscription is not a value anybody can paste. The person signs
  in to ChatGPT with a one-time code, Fountain keeps the tokens and renews
  them, and what the account ends up holding is a named *grant* that a
  credential set names by id. So `connect/2` has no clause for it; the three
  calls a page drives instead are `begin_link/1` (start the sign-in, get the
  code), `poll_link/2` (has ChatGPT approved it yet, and when it has, name
  the grant on the person's set and remember the choice) and `cancel_link/2`.
  `link_status/1` is what a page reads on arrival: whether this Fountain
  lets anybody link at all, and whether this person already has a sign-in
  open, so that a reload shows the same code rather than starting another.

  The grant is named `ravix:<user id>` like the set, one per person; a second
  sign-in by somebody who already has one *reconnects* that grant rather than
  making another, which is also what a person whose subscription has stopped
  serving (`chatgpt_grant_unusable` on a launch) is told to do. Fountain caps
  how many grants one account may hold, and Ravix is one account for
  everybody, so the ceiling is a deployment-wide count of people who can run
  Codex this way (`CHATGPT_GRANT_CEILING` on the Fountain).

  Once a set names a grant, Codex on that set runs on the subscription and on
  nothing else: Fountain refuses a run whose subscription is disconnected,
  expired or spent rather than falling back to a key. Choosing an API key for
  Codex therefore *clears* the grant from the set, or the key would sit there
  unused while the choice on the page said otherwise --- the same rule as
  Claude Code's two kinds, in the other direction.
  """

  alias Ravix.Accounts
  alias Ravix.Accounts.User
  alias Ravix.Analytics
  alias Ravix.Fountain
  alias Ravix.Fountain.Error

  defmodule Link do
    @moduledoc """
    A ChatGPT sign-in that is open: what a page shows and what it polls with.

    `user_code` and `verification_url` are for the person who started it and
    nobody else. `trusted?` says the URL is an `https` page on
    `auth.openai.com`, which is the only kind a page should turn into a link:
    a person should not be sent to type a code anywhere Fountain did not
    name. `set_id` is the set the grant will be named on when the sign-in
    completes, found once here so the poll does not go looking again.
    """

    @type t :: %__MODULE__{
            attempt_id: String.t(),
            set_id: String.t(),
            user_code: String.t() | nil,
            verification_url: String.t() | nil,
            trusted?: boolean(),
            poll_interval: pos_integer(),
            expires_at: String.t() | nil
          }

    @enforce_keys [:attempt_id, :set_id]
    defstruct [
      :attempt_id,
      :set_id,
      :user_code,
      :verification_url,
      :expires_at,
      trusted?: false,
      poll_interval: 5
    ]
  end

  @typedoc "What `connect/2` takes, as atoms the page has already narrowed."
  @type attrs :: %{agent: User.agent(), kind: User.credential_kind(), value: String.t()}

  @typedoc "What `link_status/1` answers: may anybody link here, and is a sign-in of this person's open."
  @type link_status :: %{enabled?: boolean(), pending: Link.t() | nil}

  @type reason ::
          {:unprocessable, String.t(), String.t()}
          | {:unavailable, String.t()}
          | Error.t()
          | Ecto.Changeset.t()

  # Which of Fountain's four slots each pasted choice is written to. Codex on
  # a subscription is not in here: that is a grant the set names, not a slot,
  # and it is reached through `begin_link/1` rather than `connect/2`.
  @providers %{
    {:claude, :subscription} => :claude_code_oauth_token,
    {:claude, :api_key} => :anthropic_api_key,
    {:codex, :api_key} => :openai_api_key
  }

  @kinds %{claude: [:subscription, :api_key], codex: [:subscription, :api_key]}

  # The account's default set, when Ravix has to make one. Deliberately empty.
  @house_set "ravix:house"

  @no_sets "This Fountain is too old to hold a credential per person (it needs v0.17 or newer). " <>
             "Ask whoever runs this Ravix deployment to upgrade it."

  @doc "The ways `agent` can be paid for, the preferred one first."
  @spec kinds(User.agent()) :: [User.credential_kind()]
  def kinds(agent), do: Map.fetch!(@kinds, agent)

  @doc "Whether `agent` paid for by `kind` is a value to paste (`connect/2`) or a sign-in (`begin_link/1`)."
  @spec pasted?(User.agent(), User.credential_kind()) :: boolean()
  def pasted?(agent, kind), do: is_map_key(@providers, {agent, kind})

  @doc "Whether this person has connected something for an agent to run on."
  @spec connected?(User.t() | nil) :: boolean()
  def connected?(%User{credential_set_id: id, agent: agent}),
    do: is_binary(id) and not is_nil(agent)

  def connected?(nil), do: false

  @doc """
  The Fountain runtime a project of this person's is built with, or nil for
  somebody who has not chosen, which leaves it to the catalog's default.
  """
  @spec runtime(User.t()) :: String.t() | nil
  def runtime(%User{agent: nil}), do: nil
  def runtime(%User{agent: agent}), do: Atom.to_string(agent)

  @doc """
  Store `value` as what pays for `agent`, and make `agent` this person's choice.

  Fountain asks the provider whether the value works before keeping it, so a
  mistyped token is refused here, on the field, and not by the first turn of
  the first track. Nothing about the person changes unless every step did.
  """
  @spec connect(User.t(), attrs()) :: {:ok, User.t()} | {:error, reason()}
  def connect(%User{} = user, %{agent: agent, kind: kind, value: value}) do
    with {:ok, provider} <- provider(agent, kind),
         {:ok, value} <- present(value),
         {:ok, client} <- fountain(),
         {:ok, set_id} <- ensure_set(client, user),
         :ok <- write(client, set_id, provider, value),
         :ok <- drop_sibling(client, set_id, user, agent, kind),
         {:ok, user} <-
           Accounts.save_setup(user, %{
             agent: agent,
             credential_kind: kind,
             credential_set_id: set_id
           }) do
      Analytics.track(user, :agent_connected, %{
        "ravix.agent" => Atom.to_string(agent),
        "ravix.paid_by" => Atom.to_string(kind)
      })

      {:ok, user}
    end
  end

  defp provider(agent, kind) do
    case @providers do
      %{{^agent, ^kind} => provider} ->
        {:ok, provider}

      _ ->
        {:error,
         {:unprocessable, "bad_credential",
          "There is nothing to paste for that: a ChatGPT subscription is connected by signing in."}}
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:unprocessable, "no_credential", "Paste the token or key first."}}
      # A generous bound: the longest of these is a few hundred bytes, and
      # nothing that is not one of them should travel to Fountain at all.
      trimmed when byte_size(trimmed) > 4096 -> too_long()
      trimmed -> {:ok, trimmed}
    end
  end

  defp present(_value),
    do: {:error, {:unprocessable, "no_credential", "Paste the token or key first."}}

  defp too_long,
    do: {:error, {:unprocessable, "bad_credential", "That is too long to be a token or a key."}}

  defp fountain do
    client = Fountain.client()

    if Fountain.Client.configured?(client),
      do: {:ok, client},
      else:
        {:error,
         {:unavailable,
          "This Ravix deployment has no Fountain account configured, so there is nowhere to keep a credential."}}
  end

  # ── the set ───────────────────────────────────────────────────────────

  defp ensure_set(_client, %User{credential_set_id: id}) when is_binary(id), do: {:ok, id}

  # Read before writing, for two reasons.
  #
  # The set may already exist: an earlier attempt made it and then failed
  # before the row was written, and the name is unique, so making it again
  # would refuse that person forever.
  #
  # And the account may have no default yet. Fountain makes the *first* set an
  # account ever creates its default, which is what every agent with no set of
  # its own runs on --- so on a fresh deployment the first person to connect
  # would find themselves paying for everybody who had not. An empty set of
  # Ravix's own takes that place first. Fountain lists the default first, so
  # this holds however long the list gets.
  defp ensure_set(client, %User{} = user) do
    case Fountain.credential_sets(client) do
      {:ok, sets} -> find_or_create(client, sets, set_name(user))
      {:error, %Error{status: 404}} -> {:error, {:unavailable, @no_sets}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_or_create(client, sets, name) do
    case Enum.find(sets, &(is_map(&1) and &1["name"] == name)) do
      %{"id" => id} when is_binary(id) -> {:ok, id}
      _ -> with :ok <- reserve_default(client, sets), do: create_set(client, name)
    end
  end

  defp reserve_default(client, sets) do
    if Enum.any?(sets, &(is_map(&1) and &1["is_default"] == true)) do
      :ok
    else
      case Fountain.create_credential_set(client, @house_set) do
        {:ok, _set} -> :ok
        # Somebody else connecting at the same moment made it first.
        {:error, %Error{status: 422}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp create_set(client, name) do
    case Fountain.create_credential_set(client, name) do
      {:ok, %{"id" => id}} when is_binary(id) -> {:ok, id}
      {:ok, _unrecognised} -> {:error, {:unavailable, @no_sets}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The Ravix id, not the login: a login is renameable and reusable, and a set
  # found by name must be found for the same person every time.
  defp set_name(%User{id: id}), do: "ravix:" <> id

  # ── the value ─────────────────────────────────────────────────────────

  # Fountain's own sentence is not repeated to the person. It is fixed prose
  # today, but it is a reply to a request whose body was a credential, and an
  # API that starts echoing what it was sent is not something this page should
  # find out about by rendering it.
  defp write(client, set_id, provider, value) do
    case Fountain.put_credential(client, set_id, provider, value) do
      :ok ->
        :ok

      {:error, %Error{status: 422}} ->
        {:error,
         {:unprocessable, "bad_credential",
          "#{provider_name(provider)} did not accept that. Check it was copied whole, and that it has not been revoked."}}

      {:error, %Error{status: status}} when status in [502, 504] ->
        {:error,
         {:unavailable,
          "#{provider_name(provider)} could not be reached to check that. Try again in a moment."}}

      {:error, %Error{status: 404}} ->
        {:error, {:unavailable, @no_sets}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Same agent, other kind: remove it, or Claude Code goes on preferring a
  # token the person has just said they are not using, and Codex goes on
  # running on a subscription the person has just replaced with a key. Only
  # when there was one --- a delete bumps the set's revision like any other
  # write --- and a set that has already lost it is the outcome wanted.
  defp drop_sibling(
         client,
         set_id,
         %User{agent: :codex, credential_kind: :subscription},
         :codex,
         :api_key
       ),
       do: with({:ok, _set} <- Fountain.name_chatgpt_subscription(client, set_id, nil), do: :ok)

  defp drop_sibling(client, set_id, %User{agent: agent, credential_kind: old}, agent, kind)
       when not is_nil(old) and old != kind do
    case Fountain.delete_credential(client, set_id, Map.fetch!(@providers, {agent, old})) do
      :ok -> :ok
      {:error, %Error{status: 404}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp drop_sibling(_client, _set_id, _user, _agent, _kind), do: :ok

  # ── a ChatGPT sign-in ─────────────────────────────────────────────────

  @doc """
  What the page reads before offering to connect ChatGPT.

  `enabled?` is Fountain's own answer (`chatgpt_subscriptions_enabled` on
  `/api/auth/me`), false for a Fountain too old to be asked. `pending` is a
  sign-in this person started and has not finished, found again by name in
  the account's open attempts, so that coming back to the page shows the
  same code rather than starting a second sign-in for the same subscription.
  """
  @spec link_status(User.t()) :: {:ok, link_status()} | {:error, reason()}
  def link_status(%User{} = user) do
    with {:ok, client} <- fountain() do
      {:ok, %{enabled?: linking_enabled?(client), pending: pending_link(client, user)}}
    end
  end

  defp linking_enabled?(client) do
    case Fountain.me(client) do
      {:ok, %{"chatgpt_subscriptions_enabled" => true}} -> true
      _ -> false
    end
  end

  defp pending_link(client, user) do
    with {:ok, attempts} <- Fountain.pending_chatgpt_links(client),
         %{} = attempt <- Enum.find(attempts, &mine?(&1, client, user)),
         {:ok, set_id} <- ensure_set(client, user) do
      link_of(attempt, set_id)
    else
      _ -> nil
    end
  end

  # A new link names the subscription it will make; a reconnect names the
  # grant, which has to be looked up to see whose it is. The lookup is per
  # attempt, but there are at most three open on the account.
  defp mine?(%{"name" => name}, _client, user) when is_binary(name), do: name == set_name(user)

  defp mine?(%{"grant_id" => grant_id}, client, user) when is_binary(grant_id) do
    case own_grant(client, user) do
      {:ok, %{"id" => ^grant_id}} -> true
      _ -> false
    end
  end

  defp mine?(_attempt, _client, _user), do: false

  @doc """
  Start a ChatGPT sign-in for this person: the code to type and where.

  Their set is made first if they have none, so there is somewhere to name
  the grant when the sign-in completes. A grant of theirs that exists already
  --- from an earlier link, connected or not --- is reconnected rather than
  duplicated, which keeps them at one subscription and is also the repair for
  a subscription Fountain has stopped honouring.

  Nothing about the person changes here; that waits for `poll_link/2`.
  """
  @spec begin_link(User.t()) :: {:ok, Link.t()} | {:error, reason()}
  def begin_link(%User{} = user) do
    with {:ok, client} <- fountain(),
         {:ok, set_id} <- ensure_set(client, user),
         {:ok, target} <- link_target(client, user),
         {:ok, attempt} <- start_link(client, target) do
      {:ok, link_of(attempt, set_id)}
    end
  end

  defp link_target(client, user) do
    case own_grant(client, user) do
      {:ok, %{"id" => id}} when is_binary(id) -> {:ok, %{grant_id: id}}
      {:ok, nil} -> {:ok, %{name: set_name(user)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # This person's grant, by the name Ravix gives it, or nil. A Fountain that
  # has no such route is one nobody can link on, which `start_link/2` says.
  defp own_grant(client, user) do
    name = set_name(user)

    case Fountain.chatgpt_subscriptions(client) do
      {:ok, grants} -> {:ok, Enum.find(grants, &(is_map(&1) and &1["name"] == name))}
      {:error, %Error{status: 404}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @not_enabled "Linking a ChatGPT subscription is not switched on for this Ravix deployment's Fountain account. " <>
                 "Ask whoever runs it; an OpenAI API key works meanwhile."

  # Fountain's refusals, in words that say what to do. Anything not listed
  # is passed on as it came.
  @link_refusals [
    {{404, nil}, @not_enabled},
    {{403, nil}, @not_enabled},
    {{409, "chatgpt_grant_limit_reached"},
     "This Ravix deployment's Fountain account already holds as many ChatGPT subscriptions as it may. " <>
       "Ask whoever runs it to raise the limit; an OpenAI API key works meanwhile."},
    {{409, "chatgpt_link_attempt_pending"},
     "A sign-in for your subscription is already open. Reload the page to see its code."},
    {{409, nil},
     "Too many ChatGPT sign-ins are open on this Ravix deployment at once. Try again in a few minutes."},
    {{429, nil},
     "Too many ChatGPT sign-ins were started on this Ravix deployment in the last hour. Try again later."},
    {{502, nil},
     "ChatGPT's sign-in service could not be reached to start one. Try again in a moment."},
    {{503, nil},
     "ChatGPT's sign-in service could not be reached to start one. Try again in a moment."},
    {{504, nil},
     "ChatGPT's sign-in service could not be reached to start one. Try again in a moment."}
  ]

  defp start_link(client, target) do
    case Fountain.start_chatgpt_link(client, target) do
      {:ok, %{"id" => id} = attempt} when is_binary(id) ->
        {:ok, attempt}

      {:ok, _unrecognised} ->
        {:error, {:unavailable, @not_enabled}}

      {:error, %Error{status: status, code: code} = error} ->
        {:error, link_refusal(status, code, error)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # By status and code first, then by status alone.
  defp link_refusal(status, code, error) do
    case List.keyfind(@link_refusals, {status, code}, 0) ||
           List.keyfind(@link_refusals, {status, nil}, 0) do
      {_key, message} -> {:unavailable, message}
      nil -> error
    end
  end

  @doc """
  Has ChatGPT approved the sign-in yet?

  `{:ok, :pending}` says to ask again after `link.poll_interval` seconds.
  Once the sign-in completes, the grant is named on the person's set ---
  which is the whole of what makes Codex run on it, and what ends any Codex
  conversation already running on that set --- their key for Codex is
  removed if they had one, and the choice is remembered. A sign-in that
  failed, expired or was cancelled is a refusal in words, with nothing
  changed.
  """
  @spec poll_link(User.t(), Link.t()) :: {:ok, :pending} | {:ok, User.t()} | {:error, reason()}
  def poll_link(%User{} = user, %Link{attempt_id: attempt_id, set_id: set_id}) do
    with {:ok, client} <- fountain(),
         {:ok, attempt} <- Fountain.chatgpt_link(client, attempt_id) do
      case attempt do
        %{"state" => "pending"} ->
          {:ok, :pending}

        %{"state" => "completed", "result_grant_id" => grant_id} when is_binary(grant_id) ->
          finish_link(client, user, set_id, grant_id)

        %{"state" => "failed"} = attempt ->
          {:error, link_failure(attempt["failure"])}

        %{"state" => "expired"} ->
          refused("The code was not used within fifteen minutes. Start again.")

        %{"state" => "cancelled"} ->
          refused("The sign-in was cancelled. Start again when you are ready.")

        _ ->
          refused("The sign-in ended without a subscription. Start again.")
      end
    end
  end

  defp finish_link(client, user, set_id, grant_id) do
    with {:ok, _set} <- name_grant(client, set_id, grant_id),
         :ok <- drop_sibling(client, set_id, user, :codex, :subscription),
         {:ok, user} <-
           Accounts.save_setup(user, %{
             agent: :codex,
             credential_kind: :subscription,
             credential_set_id: set_id
           }) do
      Analytics.track(user, :agent_connected, %{
        "ravix.agent" => "codex",
        "ravix.paid_by" => "subscription"
      })

      {:ok, user}
    end
  end

  # The set names the grant already when this is a reconnect, and Fountain
  # says naming what is named changes nothing, so it is done every time
  # rather than read first.
  defp name_grant(client, set_id, grant_id) do
    case Fountain.name_chatgpt_subscription(client, set_id, grant_id) do
      {:ok, set} ->
        {:ok, set}

      {:error, %Error{status: 422}} ->
        refused(
          "ChatGPT approved the sign-in, but the subscription cannot be used here yet. Try connecting again."
        )

      {:error, %Error{status: 404}} ->
        {:error, {:unavailable, @no_sets}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Fountain's reason, in our words. The grant another person's subscription
  # holds is not named: it is `ravix:<their id>`, which says who.
  defp link_failure(%{"reason" => "account_already_linked"}),
    do:
      {:unprocessable, "link_failed",
       "That ChatGPT account is already connected to somebody else on this Ravix. " <>
         "Sign in to ChatGPT as a different account and start again."}

  defp link_failure(%{"reason" => "invalid_sign_in"}),
    do:
      {:unprocessable, "link_failed",
       "ChatGPT refused the code. Device sign-in has to be allowed in that ChatGPT account's security settings."}

  defp link_failure(%{"reason" => "grant_limit_reached"}),
    do:
      {:unprocessable, "link_failed",
       "This Ravix deployment's Fountain account already holds as many ChatGPT subscriptions as it may. " <>
         "Ask whoever runs it to raise the limit."}

  defp link_failure(%{"reason" => reason})
       when reason in ~w(authorization_failed exchange_failed),
       do: {:unprocessable, "link_failed", "ChatGPT did not complete the sign-in. Start again."}

  defp link_failure(_failure),
    do:
      {:unprocessable, "link_failed",
       "The sign-in could not finish on Fountain's side. Start again."}

  defp refused(message), do: {:error, {:unprocessable, "link_failed", message}}

  @doc "End an open sign-in. A code approved afterwards stores nothing. One that already ended is left as it is."
  @spec cancel_link(User.t(), Link.t()) :: :ok | {:error, reason()}
  def cancel_link(%User{}, %Link{attempt_id: attempt_id}) do
    with {:ok, client} <- fountain() do
      case Fountain.cancel_chatgpt_link(client, attempt_id) do
        {:ok, _attempt} -> :ok
        {:error, %Error{status: status}} when status in [404, 409] -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp link_of(attempt, set_id) do
    url = attempt["verification_url"]

    %Link{
      attempt_id: attempt["id"],
      set_id: set_id,
      user_code: attempt["user_code"],
      verification_url: url,
      trusted?: trusted_url?(url),
      poll_interval: interval(attempt["poll_interval"]),
      expires_at: attempt["expires_at"]
    }
  end

  # Fountain's console shows the link only when it is an `https` page on
  # `auth.openai.com`, and so does this: a person is not to be sent to type a
  # code on a page nobody vouched for.
  defp trusted_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: "auth.openai.com"} -> true
      _ -> false
    end
  end

  defp trusted_url?(_url), do: false

  # Never faster than a second, whatever the reply said, and five when it
  # said nothing: this is how often a page asks Fountain.
  defp interval(seconds) when is_integer(seconds) and seconds >= 1, do: seconds
  defp interval(_seconds), do: 5

  defp provider_name(:openai_api_key), do: "OpenAI"
  defp provider_name(_anthropic), do: "Anthropic"
end
