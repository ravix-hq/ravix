defmodule RavixWeb.AuthHTML do
  @moduledoc """
  The one page `RavixWeb.AuthController` renders rather than redirects to.

  Every other route in that controller answers with a redirect, because they
  are URLs a browser follows on its way somewhere. An invite link is different:
  it used to be followed straight through into a membership, and the whole
  point of #16 is that arriving somewhere and joining something are now two
  steps with a person's decision between them.

  A plain form, posting to the same path. Not a LiveView, though the rest of
  the app is one: the claim has to be a POST for `protect_from_forgery` to
  cover it, and a form works whether or not a socket ever connects. It shares
  the `landing-*` classes with the sign-in card, the only other page a
  signed-out browser is shown, so it does not look like a different product.
  """
  use RavixWeb, :html

  @doc """
  Ask before joining.

  `target` is `Ravix.People.link_target/1`'s description of what the link
  opens; `token` goes back in the form action, since the link is the credential
  and the server holds only its hash.
  """
  attr :target, :map, required: true
  attr :token, :string, required: true

  def confirm(assigns) do
    ~H"""
    <div class="landing">
      <header class="landing-nav">
        <strong>Ravix</strong>
      </header>

      <main class="invite">
        <h1 id="invite-title">
          {if @target.kind == :track, do: "Join a track", else: "Join a project"}
        </h1>

        <p class="landing-intro">
          <%= if @target.kind == :track do %>
            <strong>{@target.track}</strong>, a track on <strong>{@target.project}</strong>.
          <% else %>
            <strong>{@target.project}</strong>, and every track on it.
          <% end %>
        </p>

        <p :if={@target.invited_by} class="landing-note">
          Invited by <strong>@{@target.invited_by}</strong>.
        </p>

        <div class="landing-actions">
          <form action={"/j/#{@token}"} method="post">
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <button class="landing-button landing-primary" type="submit">
              {if @target.kind == :track, do: "Join this track", else: "Join this project"}
            </button>
          </form>
          <a href="/">Not now</a>
        </div>

        <p class="landing-note">
          Joining shows your GitHub name and avatar to everyone else on it.
        </p>
      </main>
    </div>
    """
  end
end
