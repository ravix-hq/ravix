defmodule Ravix.Tracks.Attribution do
  @moduledoc """
  Who work on a track is attributed to (ADR 0009 phase 4c).

  The Ravix GitHub App is the author of what Ravix pushes and opens: it is a
  machine that did it, and there are no per-user GitHub tokens to borrow a
  person's name with. The person is credited instead:

    * **Commits** carry a `Co-authored-by:` trailer naming the person who
      started the thread (`threads.started_by`; a track's default thread is
      started by the track's creator). The agent is told so with every
      prompt it is delivered on that thread (`delivery_block/2`), because it
      is the agent that writes the commit message.
    * **Pull requests** Ravix opens name the track starter in their body
      (`pr_body/2`).

  GitHub credits a co-author by the noreply address it keeps for every
  account, `<id>+<login>@users.noreply.github.com`, so no email address is
  read or stored. Behind `RAVIX_WORKSPACE_ACCESS`, as the rest of phase 4
  is: with the switch off, prompts and pull request bodies are as before.
  """

  alias Ravix.Accounts.User
  alias Ravix.Tracks.Track

  @start "[ravix commit attribution]"
  @stop "[/ravix commit attribution]"

  @doc "The `Co-authored-by:` trailer crediting `user`."
  @spec trailer(User.t()) :: String.t()
  def trailer(%User{} = user), do: "Co-authored-by: #{display(user)} <#{noreply(user)}>"

  @doc "GitHub's noreply address for an account: `<id>+<login>@users.noreply.github.com`."
  @spec noreply(User.t()) :: String.t()
  def noreply(%User{github_id: id, login: login}), do: "#{id}+#{login}@users.noreply.github.com"

  # A name is free text on GitHub, and it goes into a one-line trailer and
  # into an instruction delivered with every collaborator's prompt. So no
  # control or format character (`\p{C}`: newlines, tabs, zero-width and
  # bidi marks), no Unicode line or paragraph separator, and no angle
  # bracket (the address's delimiters) survives, and it is capped.
  @name_max 100

  defp display(%User{name: name, login: login}) do
    clean =
      name
      |> to_string()
      |> String.replace(~r/[\p{C}\x{2028}\x{2029}<>]/u, " ")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.slice(0, @name_max)
      |> String.trim()

    if clean == "", do: login, else: clean
  end

  @doc """
  The instruction delivered ahead of each prompt on a thread `starter`
  started: end every commit with the trailer, and name them in any pull
  request the agent opens.
  """
  @spec commit_block(User.t()) :: String.t()
  def commit_block(%User{} = starter) do
    """
    #{@start}
    This thread was started by @#{starter.login}. End the message of every commit you make for it with this trailer, on its own line after a blank line:
    #{trailer(starter)}
    If you open a pull request, say in its body that the track was started by @#{starter.login}.
    #{@stop}
    """
    |> String.trim()
  end

  @doc """
  The attribution block for delivering a prompt on `thread_id` of `track`,
  or `""` when there is nobody to credit or the switch is off.

  Called by the prompt queue after it re-admitted the prompt's sender to
  this exact thread (`Ravix.PromptQueue.Server`).
  """
  @spec delivery_block(Track.t(), String.t() | nil) :: String.t()
  def delivery_block(%Track{} = track, thread_id) do
    with true <- Ravix.Config.workspace_access?(),
         starter_id when is_binary(starter_id) <-
           Ravix.Tracks.Store.starter_id(track.id, thread_id),
         # ownership: the thread's own starter, after `Access.thread_access/3`
         # admitted the prompt's sender to this thread; read to credit them.
         %User{} = starter <- Ravix.Accounts.Store.get_user(starter_id) do
      commit_block(starter)
    else
      _ -> ""
    end
  end

  @doc """
  A pull request body naming the track's starter, `starter`, after `body`.
  Unchanged when there is nobody to name or the switch is off.
  """
  @spec pr_body(String.t(), User.t() | nil) :: String.t()
  def pr_body(body, %User{login: login}) when is_binary(login) do
    if Ravix.Config.workspace_access?(),
      do: String.trim_trailing(body) <> "\n\nTrack started by @#{login} in Ravix.",
      else: body
  end

  def pr_body(body, _starter), do: body
end
