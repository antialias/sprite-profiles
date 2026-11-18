defmodule SpriteProfiles.Sprites.Cli do
  @moduledoc """
  Sprites through the installed, logged-in `sprite` CLI.

  REST calls go through `sprite api`, which adds the CLI's own credentials, so this module
  never sees a token. Commands run with `sprite exec`, files go up with `sprite file push -p`
  (without `-p` the CLI reports a missing directory that exists), checkpoints with `sprite
  checkpoint create`, and `sprite destroy --force` removes a Sprite.

  Config (a keyword list):

    * `:bin` - the CLI to run (default `"sprite"`)
    * `:runner` - `fun(bin, args, stderr) -> {stdout, exit_status}`, where `stderr` is
      `:merge` or `:discard`; tests replace it
  """

  @behaviour SpriteProfiles.Sprites

  alias SpriteProfiles.Sprites.Rest

  @impl true
  def list_connectors(cfg) do
    with {:ok, json} <- api(cfg, "GET", Rest.connectors_path()) do
      {:ok, Rest.connectors(json)}
    end
  end

  @impl true
  def create(cfg, name, labels) do
    with {:ok, json} <- api(cfg, "POST", Rest.sprites_path(), Rest.create_body(name, labels)) do
      {:ok, Rest.info(json)}
    end
  end

  @impl true
  def get(cfg, name) do
    with {:ok, json} <- api(cfg, "GET", Rest.sprite_path(name)), do: {:ok, Rest.info(json)}
  end

  @impl true
  def set_labels(cfg, name, labels) do
    with {:ok, json} <- api(cfg, "PUT", Rest.sprite_path(name), Rest.labels_body(labels)) do
      {:ok, Rest.info(json)}
    end
  end

  @impl true
  def set_policy(cfg, name, policy) do
    with {:ok, _} <- api(cfg, "POST", Rest.policy_path(name), policy), do: :ok
  end

  @impl true
  def put_service(cfg, name, svc, spec) do
    with {:ok, body} <-
           api(cfg, "PUT", Rest.service_path(name, svc), Rest.service_body(spec), raw: true) do
      case body |> Rest.ndjson() |> Rest.ndjson_error() do
        nil -> :ok
        message -> {:error, "service '#{svc}' did not start: #{message}"}
      end
    end
  end

  @impl true
  def write_file(cfg, name, path, content, mode) do
    dir = Path.join(System.tmp_dir!(), "sprite-profiles-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    local = Path.join(dir, Path.basename(path))

    try do
      File.write!(local, content)
      File.chmod!(local, mode)

      case run(cfg, ["file", "push", "-p", "-s", name, local, path], :merge) do
        {_, 0} -> :ok
        {out, code} -> {:error, "could not push #{path} (sprite exited #{code}): #{tail(out)}"}
      end
    after
      File.rm_rf(dir)
    end
  end

  @impl true
  def exec(cfg, name, argv, _opts) do
    {out, code} = run(cfg, ["exec", "-s", name, "--no-stdin", "--" | argv], :merge)
    {:ok, %{status: code, output: out}}
  end

  @impl true
  def checkpoint(cfg, name, comment) do
    case run(cfg, ["checkpoint", "create", "-s", name, "--comment", comment], :merge) do
      {out, 0} ->
        case Rest.checkpoint_id(out) do
          nil -> {:error, "the checkpoint was not confirmed: #{tail(out)}"}
          id -> {:ok, id}
        end

      {out, code} ->
        {:error, "checkpoint failed (sprite exited #{code}): #{tail(out)}"}
    end
  end

  @impl true
  def destroy(cfg, name) do
    case run(cfg, ["destroy", "--force", name], :merge) do
      {_, 0} -> :ok
      {out, code} -> {:error, "could not destroy #{name} (sprite exited #{code}): #{tail(out)}"}
    end
  end

  ## sprite api

  @doc false
  def api_args(method, path, body) do
    data =
      case body do
        nil -> []
        body -> ["-H", "Content-Type: application/json", "-d", Jason.encode!(body)]
      end

    ["api", path, "--", "-sS", "-X", method, "-w", "\n%{http_code}"] ++ data
  end

  defp api(cfg, method, path, body \\ nil, opts \\ []) do
    {out, code} = run(cfg, api_args(method, path, body), :discard)
    {payload, status} = split_status(out)

    cond do
      code != 0 ->
        {:error, "sprite api #{method} #{path} failed (exit #{code}): #{tail(payload)}"}

      status in 200..299 and opts[:raw] ->
        {:ok, payload}

      status in 200..299 ->
        decode(payload)

      true ->
        {:error, "the Sprites API answered #{status} to #{method} #{path}: #{snippet(payload)}"}
    end
  end

  defp split_status(out) do
    case String.split(out, "\n") |> Enum.split(-1) do
      {lines, [code]} ->
        case Integer.parse(code) do
          {n, ""} -> {Enum.join(lines, "\n"), n}
          _ -> {out, 0}
        end

      _ ->
        {out, 0}
    end
  end

  defp decode(""), do: {:ok, %{}}

  defp decode(payload) do
    case Jason.decode(payload) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:error, "the Sprites API answered with something other than JSON"}
    end
  end

  defp snippet("<" <> _), do: "(an HTML page)"
  defp snippet(text), do: text |> String.trim() |> String.slice(0, 300)

  defp tail(text),
    do: text |> String.trim() |> String.split("\n") |> Enum.take(-5) |> Enum.join(" | ")

  ## running the CLI

  defp run(cfg, args, stderr) do
    bin = Keyword.get(cfg, :bin, "sprite")
    runner = Keyword.get(cfg, :runner, &default_runner/3)
    runner.(bin, args, stderr)
  end

  @doc false
  def default_runner(bin, args, :merge), do: System.cmd(bin, args, stderr_to_stdout: true)

  # `sprite api` writes "Calling API: ..." and curl's own messages to stderr.
  def default_runner(bin, args, :discard),
    do: System.cmd("/bin/sh", ["-c", ~s("$0" "$@" 2>/dev/null), bin | args])
end
