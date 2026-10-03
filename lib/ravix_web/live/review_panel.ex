defmodule RavixWeb.Live.ReviewPanel do
  @moduledoc "Diff review interaction and rendering, kept separate from transcript comments."
  use RavixWeb, :html
  import Phoenix.LiveView, only: [start_async: 3]
  alias Ravix.{Accounts, Reviews}
  alias Ravix.Reviews.Anchor
  alias Ravix.Tracks.Diff
  alias RavixWeb.Error

  def new, do: %{discussions: [], anchor: nil, body: "", error: nil, busy?: false, selected: nil}

  def refresh(socket) do
    case Reviews.list(socket.assigns.current_user, socket.assigns.track_id) do
      {:ok, discussions} -> update(socket, discussions: discussions)
      {:error, reason} -> update(socket, discussions: [], error: Error.from(reason).message)
    end
  end

  def event(event, params, socket), do: scoped(socket, &dispatch(event, params, &1))

  defp scoped(socket, fun) do
    with user when not is_nil(user) <- Accounts.session_user(socket.assigns.session_hash),
         {:ok, _} <- Ravix.Accounts.Access.track_access(user, socket.assigns.track_id) do
      fun.(socket)
    else
      nil -> Phoenix.LiveView.redirect(socket, to: "/login")
      _ -> Phoenix.LiveView.redirect(socket, to: "/")
    end
  end

  defp dispatch("review-anchor", params, socket) do
    case current_diff(socket.assigns.panel) do
      %Diff{} = diff ->
        case Anchor.locate(diff, params) do
          {:ok, anchor} ->
            update(socket, anchor: Map.put(anchor, :revision, params["revision"]), error: nil)

          {:error, reason} ->
            update(socket, error: Error.from(reason).message)
        end

      _ ->
        update(socket, error: "Refresh changes before choosing an anchor.")
    end
  end

  defp dispatch("review-draft", %{"body" => body}, socket), do: update(socket, body: body)
  defp dispatch("review-cancel", _, socket), do: update(socket, anchor: nil, body: "", error: nil)

  defp dispatch("review-post", %{"body" => body}, socket) do
    state = socket.assigns.review

    if state.anchor && !state.busy? do
      %{current_user: user, track_id: id, session_hash: hash} = socket.assigns
      anchor = Map.new(state.anchor, fn {key, value} -> {Atom.to_string(key), value} end)

      socket
      |> update(body: body, busy?: true, error: nil)
      |> start_async({:review_post, id}, fn ->
        Reviews.open(user, id, anchor, body, session_hash: hash)
      end)
    else
      socket
    end
  end

  defp dispatch("review-reply", %{"discussion_id" => id, "body" => body}, socket),
    do:
      mutation(
        socket,
        Reviews.reply(socket.assigns.current_user, socket.assigns.track_id, id, body)
      )

  defp dispatch("review-resolve", %{"id" => id, "resolved" => resolved}, socket)
       when resolved in ["true", "false"],
       do:
         mutation(
           socket,
           Reviews.resolve(
             socket.assigns.current_user,
             socket.assigns.track_id,
             id,
             resolved == "true"
           )
         )

  defp dispatch("review-jump", %{"id" => id}, socket) do
    socket = refresh(socket)

    case Enum.find(socket.assigns.review.discussions, &(&1.id == id)) do
      nil ->
        update(socket, error: Error.from(:not_found, noun: "discussion").message)

      discussion ->
        socket
        |> assign(diff_path: discussion.path, diff_show_large: true, narrow_view: "files")
        |> update(selected: id)
    end
  end

  defp dispatch(_, _, socket), do: socket

  def completed(id, response, socket), do: scoped(socket, &finish(id, response, &1))

  defp finish(id, response, socket) do
    if id == socket.assigns.track_id do
      socket = update(socket, busy?: false)

      case response do
        {:ok, {:ok, discussion}} ->
          socket |> update(anchor: nil, body: "", selected: discussion.id) |> refresh()

        {:ok, {:error, reason}} ->
          update(socket, error: Error.from(reason).message)

        {:exit, _} ->
          update(socket, error: "Could not save the discussion. Your draft is retained.")
      end
    else
      socket
    end
  end

  def current_diff(%{data: %Diff{} = diff}), do: diff
  def current_diff(%{cache: %{changes: %{data: %Diff{} = diff}}}), do: diff
  def current_diff(_), do: nil

  defp mutation(socket, {:ok, _}), do: socket |> update(error: nil) |> refresh()
  defp mutation(socket, {:error, reason}), do: update(socket, error: Error.from(reason).message)

  defp update(socket, attrs),
    do: assign(socket, review: Map.merge(socket.assigns.review, Map.new(attrs)))

  attr :state, :map, required: true
  attr :panel, :any, required: true

  def panel(assigns) do
    diff = if assigns.panel.tab == :changes, do: current_diff(assigns.panel)

    assigns =
      assign(assigns,
        revision: if(diff, do: Anchor.revision(diff)),
        open: Enum.count(assigns.state.discussions, &(!&1.resolved))
      )

    ~H"""
    <section id="diff-review" class="review-panel" aria-label="Diff review discussions">
      <h3>Review discussions <span class="chip">{@open} open</span></h3>
      <p :if={@state.discussions == []}>
        Choose a file or an old/new line in Changes to start a discussion.
      </p>
      <nav aria-label="Review summary" class="review-summary">
        <a
          :for={discussion <- @state.discussions}
          href={"#review-discussion-#{discussion.id}"}
          phx-click="review-jump"
          phx-value-id={discussion.id}
        >
          {discussion.path}{position(discussion)} · {if discussion.resolved,
            do: "Resolved",
            else: "Open"}
        </a>
      </nav>
      <p :if={@state.error} role="alert">{@state.error}</p>
      <form
        :if={@state.anchor}
        id="review-post-form"
        phx-submit="review-post"
        phx-change="review-draft"
      >
        <p>Discuss {@state.anchor.path}{position(@state.anchor)}</p>
        <label for="review-body">Review comment</label>
        <textarea id="review-body" name="body" maxlength="10000" required disabled={@state.busy?}>{@state.body}</textarea>
        <button type="submit" disabled={@state.busy?}>Add discussion</button>
        <button type="button" phx-click="review-cancel" disabled={@state.busy?}>Cancel</button>
      </form>
      <article
        :for={discussion <- @state.discussions}
        id={"review-discussion-#{discussion.id}"}
        class="review-discussion"
        tabindex="-1"
        data-selected={to_string(@state.selected == discussion.id)}
        data-outdated={if @revision, do: to_string(discussion.revision != @revision), else: "unknown"}
      >
        <h4>{discussion.path}{position(discussion)}</h4>
        <p>
          {if discussion.resolved, do: "Resolved", else: "Open"} ·
          <%= cond do %>
            <% is_nil(@revision) -> %>
              Revision not checked — open Changes to compare.
            <% discussion.revision != @revision -> %>
              Outdated — retained at its original revision.
            <% true -> %>
              Current diff
          <% end %>
        </p>
        <details>
          <summary>Revision {String.slice(discussion.revision, 0, 12)}</summary><code>{discussion.revision}</code>
        </details>
        <pre :if={discussion.excerpt != nil}>{discussion.excerpt}</pre>
        <div :for={message <- discussion.messages} id={"review-message-#{message.id}"}>
          <strong>{message.author.login}</strong><p class="review-text">{message.body}</p>
        </div>
        <form id={"review-reply-#{discussion.id}"} phx-submit="review-reply">
          <input type="hidden" name="discussion_id" value={discussion.id} />
          <label for={"review-reply-body-#{discussion.id}"}>Reply</label>
          <textarea id={"review-reply-body-#{discussion.id}"} name="body" maxlength="10000" required />
          <button type="submit">Reply</button>
        </form>
        <button
          type="button"
          phx-click="review-resolve"
          phx-value-id={discussion.id}
          phx-value-resolved={to_string(!discussion.resolved)}
        >
          {if discussion.resolved, do: "Reopen", else: "Resolve"}
        </button>
      </article>
    </section>
    """
  end

  attr :revision, :string, required: true
  attr :path, :string, required: true
  attr :side, :string, required: true
  attr :line, :integer, default: nil

  def anchor_button(assigns) do
    ~H"""
    <button
      type="button"
      class={if @side == "file", do: "review-file-button", else: "diff-number review-line-button"}
      phx-click="review-anchor"
      phx-value-revision={@revision}
      phx-value-path={@path}
      phx-value-side={@side}
      phx-value-line={@line}
      aria-label={if @line, do: "Discuss #{@side} line #{@line}", else: "Discuss file"}
      data-tip={if @line, do: "Discuss #{@side} line #{@line}", else: "Discuss file"}
    >
      {if @line, do: @line, else: "Discuss file"}
    </button>
    """
  end

  defp position(%{line: nil}), do: " (file)"
  defp position(anchor), do: " (#{anchor.side} #{anchor.line})"
end
