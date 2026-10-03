defmodule Ravix.Projects.ConductorSetup do
  @moduledoc "Owner-scoped discovery of shared repository setup; never executes or copies files."

  alias Ravix.Accounts.Access
  alias Ravix.Accounts.User
  alias Ravix.GitHub
  alias Ravix.GitHub.HTTP
  alias Ravix.Projects.ConductorSetup.Parser

  @doc "Read the three supported setup files from the project's default branch."
  @spec discover(User.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def discover(%User{} = user, project_id) do
    with {:ok, project} <- Access.project_of(user, project_id),
         :ok <- repository(project),
         {:ok, app} <- app(),
         {:ok, token} <- GitHub.installation_token(app, project.installation_id),
         {:ok, files} <- files(app, token, project),
         {:ok, report} <- Parser.parse(files),
         {:ok, current} <- Access.project_of(user, project_id),
         :ok <- unchanged(project, current) do
      {:ok,
       Map.merge(report, %{
         repository: project.repo_full_name,
         branch: project.default_branch || "main"
       })}
    end
  end

  defp repository(%{repo_full_name: repo, installation_id: id})
       when is_binary(repo) and is_integer(id),
       do: :ok

  defp repository(_),
    do:
      {:error, {:unprocessable, "conductor_setup", "This project has no repository to inspect."}}

  defp app do
    case Ravix.Config.github() do
      nil -> {:error, {:unconfigured, :github}}
      app -> {:ok, app}
    end
  end

  defp unchanged(before, current) do
    if {before.repo_full_name, before.installation_id, before.default_branch} ==
         {current.repo_full_name, current.installation_id, current.default_branch},
       do: :ok,
       else:
         {:error, {:conflict, "conductor_setup", "Repository changed. Discover its setup again."}}
  end

  defp files(app, token, project) do
    Enum.reduce_while(Parser.paths(), {:ok, %{}}, fn path, {:ok, files} ->
      case file(app, token, project, path) do
        {:ok, text} -> {:cont, {:ok, Map.put(files, path, text)}}
        error -> {:halt, error}
      end
    end)
  end

  defp file(app, token, project, path) do
    query = URI.encode_query(%{ref: project.default_branch || "main"})

    repo =
      project.repo_full_name |> String.split("/") |> Enum.map_join("/", &URI.encode_www_form/1)

    case HTTP.request(app, :get, "/repos/#{repo}/contents/#{path}?#{query}",
           auth: "Bearer " <> token,
           installation_id: project.installation_id
         ) do
      {:ok, answer} -> decode_file(answer)
      {:error, %GitHub.Error{status: 404}} -> {:ok, nil}
      error -> error
    end
  end

  defp decode_file(%{"type" => "file", "encoding" => "base64", "size" => size, "content" => data})
       when is_integer(size) and size >= 0 and is_binary(data) do
    if size <= Parser.max_bytes() and byte_size(data) <= 90_000 do
      case Base.decode64(String.replace(data, "\n", "")) do
        {:ok, text} when byte_size(text) <= 65_536 -> {:ok, text}
        _ -> invalid_file()
      end
    else
      invalid_file()
    end
  end

  defp decode_file(_), do: invalid_file()

  defp invalid_file,
    do:
      {:error,
       {:unprocessable, "conductor_setup",
        "Setup files must be ordinary files of at most 64 KiB."}}
end
