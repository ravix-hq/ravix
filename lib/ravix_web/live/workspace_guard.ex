defmodule RavixWeb.Live.WorkspaceGuard do
  @moduledoc """
  Keep a page's workspace answer true for as long as the page is open
  (ADR 0009, phase 3).

  `hold/2` is for a LiveView that shows something *because* the viewer is a
  member of a workspace. It reads `Ravix.Accounts.Access.workspace_access/2`
  once at mount, and afterwards re-establishes it the way `TrackLive` does a
  track, with one difference in strictness:

    * **URL patches, events and async results read the membership again,
      every time.** All three are rare, and each is a case the ADR names: a
      patch renders new state for the URL, and work started while somebody
      was a member must not render once they are not, even when its answer
      beats the removal notice to the page.
    * **Messages trust the held answer** (`RavixWeb.Live.Guard`) until the
      workspace's hub notice arrives, which re-reads it at once. Should the
      notice be lost, the held answer expires on its own after
      `RavixWeb.Live.Guard.ttl_ms/0` and the next message re-reads.

  A page whose viewer is no longer a member is unsubscribed and sent home;
  the event, message or result that found out is dropped. The session's
  own hooks (`RavixWeb.Live.Hooks`) run before these, so an ended session
  is still the sign-in page's business.

  `RavixWeb.WorkspacePeopleLive`, the workspace page the sidebar's
  switcher opens (phase 4a), is the first page to hold one.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, redirect: 2]

  alias Phoenix.LiveView.Socket
  alias Ravix.Accounts.Access
  alias Ravix.Hub
  alias RavixWeb.Live.Guard

  @doc """
  Admit the page's viewer to `workspace_id` and keep that answer current.

  Assigns `:workspace_access` (`%{workspace: ..., role: ...}`) and the held
  `:workspace_guard`. Not found for anybody who is not a live member, as
  the door answers. Call once, from `mount/3`, after the session hooks.

  For a page mounted at the router: it hooks `handle_params/3`, which
  LiveView only allows there. Nested and isolated pages have no URL to
  patch, and none holds a workspace.

  `notify: true` passes the hub notice on to the page once the membership
  has been re-read and still admits it, for a page that shows the
  workspace's people and redraws them when they change.
  """
  @spec hold(Socket.t(), String.t(), notify: boolean()) ::
          {:ok, Socket.t()} | {:error, :not_found}
  def hold(%Socket{} = socket, workspace_id, opts \\ []) do
    with {:ok, access} <- Access.workspace_access(socket.assigns.current_user, workspace_id) do
      if connected?(socket), do: Hub.subscribe_workspace(access.workspace.id)

      {:ok,
       socket
       |> assign(
         workspace_access: access,
         workspace_guard: renew(socket),
         workspace_notify: Keyword.get(opts, :notify, false)
       )
       |> attach_hook(:workspace_params, :handle_params, fn _, _, s -> recheck(s) end)
       |> attach_hook(:workspace_event, :handle_event, fn _, _, s -> recheck(s) end)
       |> attach_hook(:workspace_message, :handle_info, &message/2)
       |> attach_hook(:workspace_async, :handle_async, fn _, _, s -> recheck(s) end)}
    end
  end

  # The notice is this hook's, and stops here unless the page asked for it
  # and is still admitted.
  defp message({:workspace_hub, id, :members}, socket) do
    case id == socket.assigns.workspace_access.workspace.id && recheck(socket) do
      {:cont, socket} -> {if(socket.assigns.workspace_notify, do: :cont, else: :halt), socket}
      {:halt, socket} -> {:halt, socket}
      false -> {:halt, socket}
    end
  end

  defp message(_message, socket) do
    if Guard.holds?(socket.assigns.workspace_guard), do: {:cont, socket}, else: recheck(socket)
  end

  defp recheck(socket) do
    %{workspace: workspace} = socket.assigns.workspace_access

    case Access.workspace_access(socket.assigns.current_user, workspace.id) do
      {:ok, access} ->
        {:cont, assign(socket, workspace_access: access, workspace_guard: renew(socket))}

      {:error, :not_found} ->
        Hub.unsubscribe_workspace(workspace.id)
        {:halt, redirect(socket, to: "/")}
    end
  end

  # The workspace answer runs out no later than the session behind it does.
  defp renew(socket) do
    expires_at =
      case socket.assigns[:session_guard] do
        %Guard{expires_at: %DateTime{} = at} -> at
        _ -> nil
      end

    Guard.new(socket.assigns[:session_hash], expires_at)
  end
end
