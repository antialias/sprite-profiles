defmodule SpriteProfiles.Sprites do
  @moduledoc """
  The boundary between the launcher and Fly.io Sprites: a behaviour and a small handle that
  dispatches to an adapter.

  Two adapters implement it:

    * `SpriteProfiles.Sprites.Cli` shells out to the installed, logged-in `sprite` CLI. It is
      what runs on a person's machine; the CLI keeps the credentials.
    * `SpriteProfiles.Sprites.Api` calls the REST API with `Req` and a token from
      `SPRITES_TOKEN` (or `SPRITE_TOKEN`), for a server.

  Every callback takes the adapter's own config first. Errors are `{:error, message}` with a
  sentence a person can act on; no adapter ever puts a token in a message.
  """

  @typedoc "What the launcher needs to know about a Sprite."
  @type info :: %{name: String.t(), labels: [String.t()], url: String.t() | nil}

  @typedoc "One org connector and its access policy, as `SpriteProfiles.Merge.admits?/3` reads it."
  @type connector :: %{
          id: String.t(),
          provider: String.t(),
          allow_all: boolean(),
          sprite_labels: [String.t()],
          name_prefix: String.t() | nil
        }

  @type config :: term()
  @type error :: {:error, String.t()}

  @callback list_connectors(config) :: {:ok, [connector]} | error
  @callback create(config, name :: String.t(), labels :: [String.t()]) :: {:ok, info} | error
  @callback get(config, name :: String.t()) :: {:ok, info} | error
  @callback set_labels(config, name :: String.t(), labels :: [String.t()]) :: {:ok, info} | error
  @callback set_policy(config, name :: String.t(), policy :: map()) :: :ok | error
  @callback put_service(config, name :: String.t(), service :: String.t(), spec :: map()) ::
              :ok | error
  @callback write_file(
              config,
              name :: String.t(),
              path :: String.t(),
              iodata(),
              mode :: integer()
            ) ::
              :ok | error
  @callback exec(config, name :: String.t(), argv :: [String.t()], opts :: keyword()) ::
              {:ok, %{status: integer(), output: binary()}} | error
  @callback checkpoint(config, name :: String.t(), comment :: String.t()) ::
              {:ok, String.t()} | error
  @callback destroy(config, name :: String.t()) :: :ok | error

  defstruct [:adapter, config: []]

  @type t :: %__MODULE__{adapter: module(), config: config}

  @doc "A handle on `adapter` with its `config`."
  def new(adapter, config \\ []), do: %__MODULE__{adapter: adapter, config: config}

  def list_connectors(%__MODULE__{adapter: a, config: c}), do: a.list_connectors(c)
  def create(%__MODULE__{adapter: a, config: c}, name, labels), do: a.create(c, name, labels)
  def get(%__MODULE__{adapter: a, config: c}, name), do: a.get(c, name)

  def set_labels(%__MODULE__{adapter: a, config: c}, name, labels),
    do: a.set_labels(c, name, labels)

  def set_policy(%__MODULE__{adapter: a, config: c}, name, policy),
    do: a.set_policy(c, name, policy)

  def put_service(%__MODULE__{adapter: a, config: c}, name, svc, spec),
    do: a.put_service(c, name, svc, spec)

  def write_file(%__MODULE__{adapter: a, config: c}, name, path, content, mode),
    do: a.write_file(c, name, path, content, mode)

  def exec(%__MODULE__{adapter: a, config: c}, name, argv, opts \\ []),
    do: a.exec(c, name, argv, opts)

  def checkpoint(%__MODULE__{adapter: a, config: c}, name, comment),
    do: a.checkpoint(c, name, comment)

  def destroy(%__MODULE__{adapter: a, config: c}, name), do: a.destroy(c, name)
end
