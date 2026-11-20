defmodule SpriteProfiles.Sprites.Api do
  @moduledoc """
  Sprites through the REST API, with `Req` and an org token. For a server, where there is no
  logged-in CLI.

  Config (a keyword list):

    * `:token` - the org token (required). `from_env/0` reads it from `SPRITES_TOKEN`, or
      `SPRITE_TOKEN`; it is only ever sent as a bearer header, never logged or returned
    * `:base_url` - default `"https://api.sprites.dev"`
    * `:req_options` - extra `Req` options; tests pass `plug: {Req.Test, ...}`

  Status: the paths and bodies are the ones the `Cli` adapter uses through `sprite api`,
  which were run against real Sprites. Exec (`POST .../exec`) and file writes (`PUT
  .../fs/write`) are documented endpoints this adapter alone uses; they are tested against a
  stub only. Exec streams its answer, so `:on_output` sees output as it comes.
  """

  @behaviour SpriteProfiles.Sprites

  alias SpriteProfiles.Sprites.Rest

  @base_url "https://api.sprites.dev"

  @doc """
  Config from the environment: `{:ok, config, var}` naming the variable the token came
  from, or `{:error, message}`.
  """
  def from_env(env \\ System.get_env()) do
    case Enum.find(["SPRITES_TOKEN", "SPRITE_TOKEN"], &(env[&1] not in [nil, ""])) do
      nil -> {:error, "no Sprites token: set SPRITES_TOKEN to an org token."}
      var -> {:ok, [token: env[var]], var}
    end
  end

  @impl true
  def list_connectors(cfg) do
    with {:ok, json} <- request(cfg, :get, Rest.connectors_path()),
         do: {:ok, Rest.connectors(json)}
  end

  @impl true
  def create_custom_connector(cfg, body) do
    with {:ok, json} <- request(cfg, :post, Rest.custom_connector_path(), json: body),
         do: Rest.created_connector(json)
  end

  @impl true
  def test_custom_connector(cfg, id) do
    with {:ok, json} <-
           request(cfg, :post, Rest.custom_connector_test_path(), json: %{"connection_id" => id}),
         do: Rest.test_result(json)
  end

  @impl true
  def create(cfg, name, labels) do
    with {:ok, json} <-
           request(cfg, :post, Rest.sprites_path(), json: Rest.create_body(name, labels)) do
      {:ok, Rest.info(json)}
    end
  end

  @impl true
  def get(cfg, name) do
    with {:ok, json} <- request(cfg, :get, Rest.sprite_path(name)), do: {:ok, Rest.info(json)}
  end

  @impl true
  def set_labels(cfg, name, labels) do
    with {:ok, json} <- request(cfg, :put, Rest.sprite_path(name), json: Rest.labels_body(labels)) do
      {:ok, Rest.info(json)}
    end
  end

  @impl true
  def set_policy(cfg, name, policy) do
    with {:ok, _} <- request(cfg, :post, Rest.policy_path(name), json: policy), do: :ok
  end

  @impl true
  def put_service(cfg, name, svc, spec) do
    with {:ok, body} <-
           request(cfg, :put, Rest.service_path(name, svc),
             json: Rest.service_body(spec),
             decode_body: false
           ) do
      case body |> Rest.ndjson() |> Rest.ndjson_error() do
        nil -> :ok
        message -> {:error, "service '#{svc}' did not start: #{message}"}
      end
    end
  end

  @impl true
  def write_file(cfg, name, path, content, mode) do
    params = [path: path, mkdir: "true", mode: "0" <> Integer.to_string(mode, 8)]

    with {:ok, _} <-
           request(cfg, :put, Rest.sprite_path(name) <> "/fs/write",
             params: params,
             body: IO.iodata_to_binary(content),
             headers: [{"content-type", "application/octet-stream"}]
           ),
         do: :ok
  end

  @impl true
  def exec(cfg, name, argv, opts) do
    params = Enum.map(argv, &{:cmd, &1})
    timeout = Keyword.get(opts, :timeout, 120_000)

    stream = if f = opts[:on_output], do: [into: stream_exec(f)], else: []

    with {:ok, body} <-
           request(
             cfg,
             :post,
             Rest.sprite_path(name) <> "/exec",
             [params: params, decode_body: false, receive_timeout: timeout] ++ stream
           ) do
      {status, output} = Rest.exec_result(body)
      {:ok, %{status: status, output: output}}
    end
  end

  # Collects the body as it streams in, as `request/4` reads it, and passes each chunk's
  # decoded output to `on_output`; an error answer's body is only collected.
  defp stream_exec(on_output) do
    fn {:data, data}, {req, resp} ->
      resp = %{resp | body: (resp.body || "") <> data}

      resp =
        if resp.status in 200..299 do
          {output, pending} = Rest.exec_chunk(Req.Response.get_private(resp, :exec, false), data)
          if output != "", do: on_output.(output)
          Req.Response.put_private(resp, :exec, pending)
        else
          resp
        end

      {:cont, {req, resp}}
    end
  end

  @impl true
  def checkpoint(cfg, name, comment) do
    with {:ok, body} <-
           request(cfg, :post, Rest.checkpoint_path(name),
             json: %{"comment" => comment},
             decode_body: false
           ) do
      events = Rest.ndjson(body)

      case Rest.ndjson_error(events) do
        nil ->
          done = Enum.find_value(events, &(&1["type"] == "complete" && &1["data"])) || ""

          case Rest.checkpoint_id(done) do
            nil -> {:error, "the checkpoint was not confirmed"}
            id -> {:ok, id}
          end

        message ->
          {:error, "checkpoint failed: #{message}"}
      end
    end
  end

  @impl true
  def destroy(cfg, name) do
    with {:ok, _} <- request(cfg, :delete, Rest.sprite_path(name)), do: :ok
  end

  defp request(cfg, method, path, opts \\ []) do
    token = Keyword.fetch!(cfg, :token)

    req =
      Req.new(
        base_url: Keyword.get(cfg, :base_url, @base_url),
        auth: {:bearer, token},
        retry: false
      )
      |> Req.merge(Keyword.get(cfg, :req_options, []))

    case Req.request(req, [method: method, url: path] ++ opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         "the Sprites API answered #{status} to #{String.upcase(to_string(method))} #{path}: #{snippet(body)}"}

      {:error, exception} ->
        {:error, "could not reach the Sprites API: #{Exception.message(exception)}"}
    end
  end

  defp snippet(body) when is_map(body) or is_list(body),
    do: Jason.encode!(body) |> String.slice(0, 300)

  defp snippet("<" <> _), do: "(an HTML page)"
  defp snippet(body) when is_binary(body), do: body |> String.trim() |> String.slice(0, 300)
  defp snippet(_), do: ""
end
