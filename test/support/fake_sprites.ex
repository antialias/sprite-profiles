defmodule SpriteProfiles.FakeSprites do
  @moduledoc """
  A `SpriteProfiles.Sprites` adapter for tests: it records every call and answers from a
  function, so a test can script failures. No network.

      {sprites, log} = FakeSprites.start()
      {sprites, log} = FakeSprites.start(fn {:create, _args} -> {:error, "full"}; _ -> :default end)
      FakeSprites.calls(log)
  """

  @behaviour SpriteProfiles.Sprites

  alias SpriteProfiles.Sprites

  @doc """
  Starts a fake. `respond` gets `{callback, args}` and returns the answer, or `:default`
  for the usual success.
  """
  def start(respond \\ fn _ -> :default end) do
    {:ok, log} = Agent.start_link(fn -> [] end)
    {Sprites.new(__MODULE__, log: log, respond: respond), log}
  end

  @doc "Every call so far, in order, as `{callback, args}`."
  def calls(log), do: log |> Agent.get(& &1) |> Enum.reverse()

  @doc "The calls to one callback."
  def calls(log, name), do: for({^name, args} <- calls(log), do: args)

  @impl true
  def list_connectors(cfg), do: call(cfg, :list_connectors, [], {:ok, []})

  @impl true
  def create_custom_connector(cfg, body) do
    connector = %{
      id: "conn_custom",
      provider: "custom_api",
      name: body["name"],
      allow_all: false,
      sprite_labels: get_in(body, ["access_policy", "sprite_labels"]) || [],
      name_prefix: nil,
      allowed_endpoints: get_in(body, ["access_policy", "allowed_endpoints"]) || [],
      blocked_endpoints: [],
      base_url: body["base_api_url"]
    }

    call(cfg, :create_custom_connector, [body], {:ok, connector})
  end

  @impl true
  def test_custom_connector(cfg, id),
    do: call(cfg, :test_custom_connector, [id], {:ok, %{status: "ok", message: "HTTP 200"}})

  @impl true
  def create(cfg, name, labels),
    do: call(cfg, :create, [name, labels], {:ok, %{name: name, labels: labels, url: "url"}})

  @impl true
  def get(cfg, name), do: call(cfg, :get, [name], {:ok, %{name: name, labels: [], url: "url"}})

  @impl true
  def set_labels(cfg, name, labels),
    do: call(cfg, :set_labels, [name, labels], {:ok, %{name: name, labels: labels, url: "url"}})

  @impl true
  def set_policy(cfg, name, policy), do: call(cfg, :set_policy, [name, policy], :ok)

  @impl true
  def put_service(cfg, name, svc, spec), do: call(cfg, :put_service, [name, svc, spec], :ok)

  @impl true
  def write_file(cfg, name, path, content, mode),
    do: call(cfg, :write_file, [name, path, IO.iodata_to_binary(content), mode], :ok)

  @impl true
  def exec(cfg, name, argv, opts) do
    default =
      case argv do
        ["bash", "-c", script] ->
          cond do
            script =~ ~s(printf '%s' "$HOME") -> {:ok, %{status: 0, output: "/home/sprite"}}
            script =~ "settings.json" -> {:ok, %{status: 0, output: ~s({"hooks":{}})}}
            true -> {:ok, %{status: 0, output: "ok"}}
          end

        _ ->
          {:ok, %{status: 0, output: ""}}
      end

    case call(cfg, :exec, [name, argv, opts], default) do
      # Like an adapter that cannot stream: everything at once, at the end. A `respond`
      # function that streams calls `opts[:on_output]` itself and answers `{:streamed, _}`.
      {:streamed, answer} ->
        answer

      {:ok, %{output: out}} = answer ->
        if opts[:on_output] && out != "", do: opts[:on_output].(out)
        answer

      answer ->
        answer
    end
  end

  @impl true
  def checkpoint(cfg, name, comment), do: call(cfg, :checkpoint, [name, comment], {:ok, "v2"})

  @impl true
  def destroy(cfg, name), do: call(cfg, :destroy, [name], :ok)

  defp call(cfg, name, args, default) do
    Agent.update(cfg[:log], &[{name, args} | &1])

    case cfg[:respond].({name, args}) do
      :default -> default
      answer -> answer
    end
  end
end
