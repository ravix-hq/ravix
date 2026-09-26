defmodule Ravix.Tooling.CatalogTest do
  use Ravix.DataCase, async: true
  import Ravix.ToolingFixture
  alias Ravix.Tooling
  alias Ravix.Tooling.{Catalog, OAuth}
  alias RavixWeb.Tooling.MCP

  test "every published tool accepts its schema's optional fields and boundary values" do
    user = insert_user()
    {p, _, _} = principal(user)
    {:ok, %{tools: tools}} = MCP.call(p, %{"id" => 1, "method" => "tools/list"})
    OAuth.disconnect(user, p.grant.id)

    for tool <- tools do
      schema = tool.inputSchema
      assert schema == Catalog.find(tool.name).inputSchema

      for args <- samples(schema) do
        # A revoked grant stops effects after argument validation. A schema rejection
        # here means tools/list advertised input that tools/call does not accept.
        assert {:error, :unauthenticated} = Tooling.call(p, tool.name, args)
      end

      for {field, _} <- schema["properties"] do
        args = Map.put(hd(samples(schema)), field, nil)

        assert {:error, {:unprocessable, "invalid_arguments", _}} =
                 Tooling.call(p, tool.name, args)
      end

      args = hd(samples(schema))

      for key <- schema["required"] do
        assert {:error, {:unprocessable, "invalid_arguments", _}} =
                 Tooling.call(p, tool.name, Map.delete(args, key))
      end

      assert {:error, {:unprocessable, "invalid_arguments", _}} =
               Tooling.call(p, tool.name, Map.put(args, "unknown_field", true))
    end
  end

  test "the published catalog requires every scope, including both assignment scopes" do
    for scope <- OAuth.scopes() do
      p = %{grant: %{scopes: [scope]}}
      {:ok, %{tools: tools}} = MCP.call(p, %{"id" => 1, "method" => "tools/list"})

      expected =
        Catalog.tools()
        |> Enum.filter(&(&1.scope == scope and &1.name != "assign_items"))
        |> Enum.map(& &1.name)

      assert Enum.map(tools, & &1.name) == expected
    end

    {:ok, %{tools: tools}} =
      MCP.call(%{grant: %{scopes: ["plans:write", "tracks:write"]}}, %{
        "id" => 1,
        "method" => "tools/list"
      })

    assert Enum.any?(tools, &(&1.name == "assign_items"))
  end

  defp samples(%{"type" => "object", "properties" => properties} = schema) do
    full = Map.new(properties, fn {key, value} -> {key, hd(samples(value))} end)
    minimal = Map.take(full, schema["required"])

    [minimal, full] ++
      Enum.flat_map(properties, fn {key, value} ->
        Enum.map(samples(value), &Map.put(full, key, &1))
      end)
  end

  defp samples(%{"type" => "object"}), do: [%{}, %{"any" => [1, nil, true]}]
  defp samples(%{"enum" => values}), do: values

  defp samples(%{"type" => "string"} = schema) do
    min = Map.get(schema, "minLength", 0)
    max = Map.get(schema, "maxLength", 201)
    [String.duplicate("a", min), String.duplicate("é", max)]
  end

  defp samples(%{"type" => "integer"} = schema),
    do: [Map.get(schema, "minimum", -1), Map.get(schema, "maximum", 9_007_199_254_740_992)]

  defp samples(%{"type" => "boolean"}), do: [true, false]

  defp samples(%{"type" => "array", "items" => item} = schema),
    do:
      [[], List.duplicate(hd(samples(item)), Map.get(schema, "maxItems", 100))] ++
        Enum.map(samples(item), &[&1])
end
