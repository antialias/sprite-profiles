defmodule SpriteProfiles.Sprites.Rest do
  @moduledoc """
  The Sprites REST API's shapes, shared by both adapters: request paths and bodies, and the
  parsing of what comes back. Pure.

  Some of this is not in the published API reference and was observed instead: `POST
  /v1/sprites` and `PUT /v1/sprites/{name}` both take `labels` (the update replaces the whole
  list and needs no `url_settings`); `POST /policy/network` answers with an empty body; the
  HTTP exec endpoint answers with frames, each a stream byte (1 stdout, 2 stderr, 3 exit,
  followed by the exit status byte) and its data.
  """

  @doc "The org's connectors, from `GET /v1/oauth/connections`."
  def connectors_path, do: "/v1/oauth/connections"

  def sprites_path, do: "/v1/sprites"
  def sprite_path(name), do: "/v1/sprites/#{URI.encode(name)}"
  def policy_path(name), do: sprite_path(name) <> "/policy/network"
  def service_path(name, svc), do: sprite_path(name) <> "/services/#{URI.encode(svc)}"
  def checkpoint_path(name), do: sprite_path(name) <> "/checkpoint"

  def create_body(name, labels), do: %{"name" => name, "labels" => labels}
  def labels_body(labels), do: %{"labels" => labels}

  @doc "A service as `PUT .../services/{svc}` takes it."
  def service_body(spec) do
    %{
      "cmd" => spec.cmd,
      "args" => spec.args,
      "needs" => Map.get(spec, :needs, []),
      "http_port" => spec.http_port
    }
    |> then(fn body -> if spec[:dir], do: Map.put(body, "dir", spec.dir), else: body end)
    |> then(fn body ->
      if spec[:env] in [nil, %{}], do: body, else: Map.put(body, "env", spec.env)
    end)
  end

  @doc "Where a custom API connector is created, or updated in place by name."
  def custom_connector_path, do: "/v1/oauth/connections/custom_api"

  @doc "Where a stored custom API connector's credential is tested."
  def custom_connector_test_path, do: "/v1/oauth/connections/custom_api/test"

  @doc """
  Normalizes the connector list to `t:SpriteProfiles.Sprites.connector/0`. A connector's
  name comes back as `provider_account_name`; a custom API connector's base URL sits in
  `provider_info`.
  """
  def connectors(%{"connections" => list}) when is_list(list), do: Enum.map(list, &connector/1)
  def connectors(_), do: []

  @doc "One connector, as `connectors/1` normalizes it."
  def connector(c) do
    policy = c["access_policy"] || %{}
    info = if is_map(c["provider_info"]), do: c["provider_info"], else: %{}

    %{
      id: c["id"],
      provider: c["provider"],
      name: c["provider_account_name"],
      allow_all: policy["allow_all"] == true,
      sprite_labels: policy["sprite_labels"] || [],
      name_prefix: blank_nil(policy["name_prefix"]),
      allowed_endpoints: policy["allowed_endpoints"] || [],
      blocked_endpoints: policy["blocked_endpoints"] || [],
      base_url: blank_nil(info["base_api_url"] || info["base_url"])
    }
  end

  @doc "The connector in a create answer (`{\"connection\": {...}}`)."
  def created_connector(%{"connection" => %{} = c}), do: {:ok, connector(c)}
  def created_connector(_), do: {:error, "the Sprites API did not return the connector"}

  @doc "The outcome in a test answer (`{\"result\": {\"status\": ..., \"message\": ...}}`)."
  def test_result(%{"result" => %{} = r}),
    do: {:ok, %{status: to_string(r["status"]), message: r["message"]}}

  def test_result(_), do: {:error, "the Sprites API did not return a test result"}

  defp blank_nil(""), do: nil
  defp blank_nil(v), do: v

  @doc "A Sprite resource reduced to what the launcher uses."
  def info(%{"name" => name} = json) do
    %{name: name, labels: json["labels"] || [], url: json["url"]}
  end

  @doc """
  Decodes the HTTP exec response body. Returns `{status, output}`, with stdout and stderr
  interleaved as they came. Frames carry no length, so the stream bytes (1, 2, 3) are read
  as markers wherever they appear; command output does not normally hold those control
  characters. A body with no exit frame gives status 255.
  """
  def exec_result(body) when is_binary(body) do
    {status, output, _} = exec_scan(body, [], nil)
    {status || 255, output}
  end

  @doc """
  Decodes one chunk of the HTTP exec body as it streams in, for live output. `pending` is
  `false` at the start, and then what the last call returned: `true` when that chunk ended
  with the exit marker, whose status byte is the first of this one. Returns `{output,
  pending}`; `exec_result/1` on the whole body still gives the status and full output.
  """
  def exec_chunk(pending, chunk) when is_binary(chunk) do
    bin = if pending, do: <<3, chunk::binary>>, else: chunk
    {_, output, dangling} = exec_scan(bin, [], nil)
    {output, dangling}
  end

  defp exec_scan(<<3, code, rest::binary>>, out, _), do: exec_scan(rest, out, code)
  defp exec_scan(<<3>>, out, status), do: {status, finish(out), true}

  defp exec_scan(<<s, rest::binary>>, out, status) when s in [1, 2],
    do: exec_scan(rest, out, status)

  defp exec_scan(<<>>, out, status), do: {status, finish(out), false}

  defp exec_scan(bin, out, status) do
    # Take the run of ordinary bytes up to the next marker in one step.
    case :binary.match(bin, [<<1>>, <<2>>, <<3>>]) do
      :nomatch ->
        exec_scan(<<>>, [bin | out], status)

      {pos, _} ->
        exec_scan(
          binary_part(bin, pos, byte_size(bin) - pos),
          [binary_part(bin, 0, pos) | out],
          status
        )
    end
  end

  defp finish(out), do: out |> Enum.reverse() |> IO.iodata_to_binary()

  @doc "Splits an NDJSON body into decoded events, skipping lines that are not JSON."
  def ndjson(body) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{} = event} -> [event]
        _ -> []
      end
    end)
  end

  @doc "The first error event's message in an NDJSON stream, or nil."
  def ndjson_error(events) do
    Enum.find_value(events, fn
      %{"type" => "error"} = e -> e["data"] || e["error"] || "error"
      _ -> nil
    end)
  end

  @doc ~S'The checkpoint id in text such as "Checkpoint v3 created", or nil.'
  def checkpoint_id(text) do
    case Regex.run(~r/Checkpoint (v\d+) created/, text) do
      [_, id] -> id
      _ -> nil
    end
  end
end
