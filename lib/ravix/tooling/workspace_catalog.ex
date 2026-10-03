defmodule Ravix.Tooling.WorkspaceCatalog do
  @moduledoc "Workspace administration schemas with explicit read/write consent."

  def names, do: Enum.map(tools(), & &1.name)

  def tools do
    [
      read(
        "list_workspaces",
        "List your live workspace memberships. Metadata remains readable when workspace access is disabled.",
        %{},
        [],
        true
      ),
      read(
        "get_workspace",
        "Read workspace metadata and your role; membership does not grant project access while workspace access is disabled.",
        workspace(),
        ~w(workspace_id)
      ),
      write(
        "create_workspace",
        "Create a team workspace and become its owner. Requires workspace access enabled.",
        %{"name" => string(60)},
        ~w(name)
      ),
      write(
        "update_workspace",
        "Rename a workspace as an owner or admin.",
        Map.put(workspace(), "name", string(60)),
        ~w(workspace_id name)
      ),
      write(
        "select_workspace",
        "Save your current workspace for the browser sidebar.",
        workspace(),
        ~w(workspace_id)
      ),
      read(
        "list_workspace_members",
        "List workspace members and roles.",
        workspace(),
        ~w(workspace_id),
        true
      ),
      read(
        "list_workspace_invitations",
        "List pending GitHub-login invitations. No invitation secrets are returned.",
        workspace(),
        ~w(workspace_id),
        true
      ),
      write(
        "invite_workspace_member",
        "Invite a GitHub login, or immediately admit an existing user. Owners/admins; only owners may grant admin/owner. No invite links exist.",
        Map.merge(workspace(), %{"login" => string(39), "role" => role()}),
        ~w(workspace_id login)
      ),
      write(
        "revoke_workspace_invitation",
        "Withdraw a pending invitation. Only owners may withdraw protected invitations.",
        Map.put(workspace(), "login", string(39)),
        ~w(workspace_id login)
      ),
      write(
        "set_workspace_member_role",
        "Change a member role as an owner; the last owner is protected.",
        Map.merge(workspace(), %{"user_id" => string(), "role" => role()}),
        ~w(workspace_id user_id role)
      ),
      write(
        "remove_workspace_member",
        "Remove a member as owner/admin; only owners remove owners, never the last owner. Revocation also works while workspace access is disabled.",
        Map.put(workspace(), "user_id", string()),
        ~w(workspace_id user_id)
      ),
      write(
        "leave_workspace",
        "Leave a workspace, except your personal workspace or as its last owner. Also works while workspace access is disabled.",
        workspace(),
        ~w(workspace_id)
      ),
      read(
        "list_workspace_connections",
        "List GitHub installation connections and their standing from the cache.",
        workspace(),
        ~w(workspace_id),
        true
      ),
      read(
        "list_workspace_repositories",
        "Read the cached repository catalog with canonical project IDs. Does not refresh GitHub.",
        workspace(),
        ~w(workspace_id),
        true
      ),
      write(
        "refresh_workspace_repositories",
        "Refresh GitHub connections/catalog as any member. Failures preserve cached rows; returns at most 100 entries per report with truncation indicators.",
        workspace(),
        ~w(workspace_id)
      ),
      read(
        "list_available_workspace_installations",
        "As owner, list GitHub installations your own sign-in token can see and this workspace has not connected. Token values stay server-side.",
        workspace(),
        ~w(workspace_id),
        true
      ),
      write(
        "add_workspace_installation",
        "As owner, bind an installation proven accessible by your sign-in token and refresh the catalog. Knowing an ID alone grants nothing.",
        Map.put(workspace(), "installation_id", %{"type" => "integer", "minimum" => 1}),
        ~w(workspace_id installation_id)
      ),
      write(
        "add_workspace_repository",
        "Admit a catalog repository as a project as owner/admin, spending the project payer's subscription; members may retrieve an existing canonical project.",
        Map.put(workspace(), "full_name", string()),
        ~w(workspace_id full_name)
      ),
      link(
        "get_workspace_connect_url",
        "Return the authenticated browser entry URL for GitHub installation setup. Open as the same user; the existing route mints session-bound, single-use state. No headless OAuth completion."
      ),
      link(
        "get_workspace_configure_url",
        "Return GitHub's configure page as owner/admin. Returning connects nothing; refresh afterward."
      ),
      read(
        "list_workspace_sections",
        "List your personal sidebar sections in this workspace.",
        workspace(),
        ~w(workspace_id),
        true
      ),
      read(
        "list_workspace_placements",
        "List your accessible projects placed in personal sections; stale inaccessible placements are omitted.",
        workspace(),
        ~w(workspace_id),
        true
      ),
      write(
        "create_workspace_section",
        "Create your personal sidebar section; changes no membership or project ownership.",
        Map.put(workspace(), "name", string(80)),
        ~w(workspace_id name)
      ),
      write(
        "update_workspace_section",
        "Rename or collapse your personal section in this workspace.",
        Map.merge(section(), %{"name" => string(80), "collapsed" => %{"type" => "boolean"}}),
        ~w(workspace_id section_id)
      ),
      write(
        "delete_workspace_section",
        "Delete your personal section; its projects return to the unsectioned sidebar.",
        section(),
        ~w(workspace_id section_id)
      ),
      write(
        "move_workspace_placement",
        "Place an accessible project in your personal section in its sidebar workspace. Empty section_id removes its placement; does not move project ownership.",
        Map.merge(workspace(), %{
          "project_id" => string(),
          "section_id" => %{"type" => "string", "maxLength" => 200}
        }),
        ~w(workspace_id project_id section_id)
      )
    ]
  end

  defp read(name, description, properties, required, paged \\ false) do
    properties = if paged, do: Map.merge(properties, pagination()), else: properties
    tool(name, description, "workspaces:read", properties, required, true)
  end

  defp write(name, description, properties, required),
    do:
      tool(
        name,
        description,
        "workspaces:write",
        Map.put(properties, "request_id", string(100)),
        required ++ ~w(request_id),
        false
      )

  defp link(name, description),
    do: tool(name, description, "workspaces:write", workspace(), ~w(workspace_id), true)

  defp tool(name, description, scope, properties, required, read_only) do
    %{
      name: name,
      description: description,
      scope: scope,
      inputSchema: %{
        "type" => "object",
        "properties" => properties,
        "required" => required,
        "additionalProperties" => false
      },
      annotations: %{
        readOnlyHint: read_only,
        destructiveHint:
          name in ~w(remove_workspace_member leave_workspace revoke_workspace_invitation delete_workspace_section set_workspace_member_role),
        openWorldHint: true
      }
    }
  end

  defp workspace, do: %{"workspace_id" => string()}
  defp section, do: Map.put(workspace(), "section_id", string())
  defp string(max \\ 200), do: %{"type" => "string", "minLength" => 1, "maxLength" => max}
  defp role, do: %{"type" => "string", "enum" => ~w(owner admin member)}

  defp pagination,
    do: %{
      "after" => string(),
      "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
    }
end
