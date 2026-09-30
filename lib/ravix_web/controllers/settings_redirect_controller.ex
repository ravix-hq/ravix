defmodule RavixWeb.SettingsRedirectController do
  @moduledoc """
  The old settings addresses, and the bare ones, sent to where their
  settings live now (RAV-72): a section of the settings frame
  (`RavixWeb.Live.Settings`).

    * `/w/:workspace` and `/w/:workspace/settings` go to its Members, which
      is what `/w/:workspace` was, query and all (`?github=connected`);
    * `/settings/connections` and `/settings` go to Connected apps;
    * `/p/:project/settings` goes to the project's first section.

  Nothing is looked up here: the page each lands on admits the viewer or
  does not, exactly as it would for a link straight to it. `?settings=true`
  on a project is a LiveView patch, not a route, and is answered in
  `RavixWeb.WorkspaceLive`.
  """
  use RavixWeb, :controller

  alias RavixWeb.Live.Settings

  def workspace(conn, %{"workspace" => id}),
    do: to(conn, Settings.section_path(:workspace, id, "members"))

  def personal(conn, _params),
    do: to(conn, Settings.section_path(:personal, nil, Settings.first(:personal)))

  def project(conn, %{"project" => id}),
    do: to(conn, Settings.section_path(:project, id, Settings.first(:project)))

  defp to(conn, path) do
    query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
    redirect(conn, to: path <> query)
  end
end
