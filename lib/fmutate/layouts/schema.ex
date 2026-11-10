defmodule FMutate.Layouts.Schema do
  @moduledoc """
  Validates decoded JSON against `priv/layout.schema.json`.

  A small JSON Schema (2020-12) interpreter covering exactly the keywords that schema uses: `type`,
  `required`, `properties`, `additionalProperties: false`, `items`, `minItems`, `const`, `enum`,
  `pattern`, `minimum`, `maximum`, `maxLength`, `oneOf` and local `$ref`s (`#/$defs/...`). Annotations
  (`default`, `description`, `format`, `title`) are ignored, as the spec allows. The schema file is read
  at compile time, so the validator and the shipped schema can't drift apart.
  """

  @schema_path Path.join([__DIR__, "..", "..", "..", "priv", "layout.schema.json"]) |> Path.expand()
  @external_resource @schema_path
  @schema @schema_path |> File.read!() |> JSON.decode!()

  @type error :: {path :: String.t(), message :: String.t()}

  @doc "The schema as decoded JSON."
  def schema, do: @schema

  @doc "`:ok`, or `{:error, errors}` with a JSON-pointer-ish path and a message per error."
  @spec validate(term()) :: :ok | {:error, [error]}
  def validate(data) do
    case check(@schema, data, "") do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp check(%{"$ref" => "#/$defs/" <> name}, data, path),
    do: check(Map.fetch!(@schema["$defs"], name), data, path)

  defp check(schema, data, path) when is_map(schema) do
    Enum.flat_map(schema, fn {keyword, arg} -> keyword(keyword, arg, schema, data, path) end)
  end

  defp keyword("type", type, _s, data, path),
    do: if(type?(type, data), do: [], else: [{path, "expected #{type}"}])

  defp keyword("const", value, _s, data, path),
    do: if(data == value, do: [], else: [{path, "must be #{inspect(value)}"}])

  defp keyword("enum", values, _s, data, path),
    do: if(data in values, do: [], else: [{path, "must be one of #{inspect(values)}"}])

  defp keyword("pattern", re, _s, data, path) when is_binary(data),
    do: if(Regex.match?(Regex.compile!(re), data), do: [], else: [{path, "must match #{re}"}])

  defp keyword("maxLength", n, _s, data, path) when is_binary(data),
    do: if(String.length(data) <= n, do: [], else: [{path, "longer than #{n}"}])

  defp keyword("minimum", n, _s, data, path) when is_number(data),
    do: if(data >= n, do: [], else: [{path, "below #{n}"}])

  defp keyword("maximum", n, _s, data, path) when is_number(data),
    do: if(data <= n, do: [], else: [{path, "above #{n}"}])

  defp keyword("minItems", n, _s, data, path) when is_list(data),
    do: if(length(data) >= n, do: [], else: [{path, "needs at least #{n} item(s)"}])

  defp keyword("required", keys, _s, data, path) when is_map(data),
    do: for(k <- keys, not Map.has_key?(data, k), do: {path, "missing #{k}"})

  defp keyword("properties", props, _s, data, path) when is_map(data) do
    Enum.flat_map(props, fn {k, sub} ->
      if Map.has_key?(data, k), do: check(sub, data[k], "#{path}/#{k}"), else: []
    end)
  end

  defp keyword("additionalProperties", false, s, data, path) when is_map(data) do
    known = Map.get(s, "properties", %{})
    for k <- Map.keys(data), not Map.has_key?(known, k), do: {"#{path}/#{k}", "not allowed"}
  end

  defp keyword("items", sub, _s, data, path) when is_list(data) do
    data |> Enum.with_index() |> Enum.flat_map(fn {item, i} -> check(sub, item, "#{path}/#{i}") end)
  end

  defp keyword("oneOf", subs, _s, data, path) do
    case Enum.count(subs, &(check(&1, data, path) == [])) do
      1 -> []
      0 -> [{path, "matches none of the allowed forms"}]
      n -> [{path, "matches #{n} forms, expected exactly one"}]
    end
  end

  defp keyword("$ref", _ref, _s, _data, _path), do: []
  defp keyword(_annotation_or_inapplicable, _arg, _s, _data, _path), do: []

  defp type?("object", d), do: is_map(d)
  defp type?("array", d), do: is_list(d)
  defp type?("string", d), do: is_binary(d)
  defp type?("integer", d), do: is_integer(d)
  defp type?("number", d), do: is_number(d)
  defp type?("boolean", d), do: is_boolean(d)
end
