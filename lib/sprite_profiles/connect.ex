defmodule SpriteProfiles.Connect do
  @moduledoc """
  Creates or updates, in a person's org, the custom API connector a profile declares.

  The connector is named by the profile's qualified name (`acme.linear`, or `linear` for a
  local pick), points at the declared base URL with the declared auth method, and has an
  access policy that admits Sprites labelled `profile:<qualified name>` and allows the
  declared endpoints: the four things `SpriteProfiles.Merge.check_connectors/4` checks at
  launch, so they cannot be typed wrong.

  `load/2` resolves the pick, `body/3` builds the request (pure), and `connect/3` posts it
  and asks Fly to test the stored credential. `mix profiles.connect` reads the token from
  the terminal and calls them; a test or an iex session can call `connect/3` with a token
  in hand. The token is only ever a value passed to `connect/3`: nothing here prints, logs
  or stores it.
  """

  alias SpriteProfiles.{Merge, Profile, ProfilePath, Refusal, Resolver, Sprites}

  @gateway "https://api.sprites.dev/v1/gateway"

  @auth_fields %{
    "header" => "auth_header_prefix",
    "custom_header" => "auth_custom_header_name",
    "query_param" => "auth_query_param_name",
    "url_path" => "auth_url_path_template"
  }

  @doc """
  Resolves one pick (a name or an address) and returns `{:ok, profile, connector}`, the
  profile's custom API connector, or `{:error, problems}`: the pick's refusals or validation
  errors, or `no_custom_connector`.

  Options: `:dirs` (the search path; default as `mix profiles.plan` has it) and those of
  `SpriteProfiles.Resolver.find/3`.
  """
  @spec load(String.t(), keyword()) ::
          {:ok, Profile.t(), Profile.connector()} | {:error, [Refusal.t() | Profile.Error.t()]}
  def load(pick, opts \\ []) do
    dirs = opts[:dirs] || ProfilePath.dirs([])

    with :ok <- Merge.check_picks([pick]),
         {:ok, [profile]} <- Resolver.find([pick], dirs, opts) do
      case Enum.find(profile.connectors, &(&1.provider == "custom_api")) do
        nil ->
          {:error,
           [
             Refusal.new(
               :no_custom_connector,
               [pick],
               "profile '#{pick}' declares no custom API connector, so there is nothing to connect; catalogue connectors (#{catalogue(profile)}) are set up in the Sprites dashboard."
             )
           ]}

        connector ->
          {:ok, profile, connector}
      end
    end
  end

  defp catalogue(profile) do
    case Enum.map(profile.connectors, & &1.provider) do
      [] -> "none here"
      list -> Enum.join(list, ", ")
    end
  end

  @doc "The connector's name: the profile's qualified name."
  def name(%Profile{} = p), do: p.qualified || p.name

  @doc "The label its access policy admits."
  def label(%Profile{} = p), do: "profile:#{name(p)}"

  @doc "What `mix profiles.connect` prints before it asks for the token."
  @spec summary(Profile.t(), Profile.connector()) :: [String.t()]
  def summary(%Profile{} = p, c) do
    [
      "Connector:  #{name(p)}  (custom_api)",
      "Base URL:   #{c.base_url}",
      "Auth:       #{auth_line(c.auth)}",
      "Policy:     Sprites labelled #{label(p)}; endpoints #{Enum.join(c.endpoints, " ")}",
      "Test URL:   #{c.test_url || "(none: the credential is not tested)"}"
    ]
  end

  defp auth_line(%{method: "header", value: ""}), do: "Authorization: <token>"
  defp auth_line(%{method: "header", value: prefix}), do: "Authorization: #{prefix} <token>"
  defp auth_line(%{method: "custom_header", value: h}), do: "#{h}: <token>"
  defp auth_line(%{method: "query_param", value: q}), do: "?#{q}=<token>"
  defp auth_line(%{method: "url_path", value: t}), do: "path #{t}"

  @doc """
  The body of `POST /v1/oauth/connections/custom_api` for `profile`'s connector `c`, with
  `token` as the credential. Fly updates a connector of the same name in place, so the same
  body rotates a token or repairs a policy.
  """
  @spec body(Profile.t(), Profile.connector(), String.t()) :: map()
  def body(%Profile{} = p, c, token) do
    %{
      "name" => name(p),
      "base_api_url" => c.base_url,
      "access_token" => token,
      "auth_method" => c.auth.method,
      Map.fetch!(@auth_fields, c.auth.method) => c.auth.value,
      "description" => "sprite-profiles: #{p.pick || name(p)}",
      "access_policy" => %{
        "sprite_labels" => [label(p)],
        "allowed_endpoints" => c.endpoints
      }
    }
    |> then(fn b -> if c.test_url, do: Map.put(b, "test_url", c.test_url), else: b end)
  end

  @doc """
  Creates or updates `profile`'s custom API connector with `token`, then, when it declares
  a `test_url`, asks Fly to test the stored credential (by `connection_id`, so the token is
  sent once). Returns `{:ok, %{connector: c, gateway_url: url, test: result | nil}}` or
  `{:error, message}`; neither holds the token.
  """
  @spec connect(Profile.t(), String.t(), Sprites.t()) :: {:ok, map()} | {:error, String.t()}
  def connect(%Profile{} = p, token, %Sprites{} = sprites) when is_binary(token) do
    with {:ok, c} <- custom(p),
         :ok <- check_token(token),
         {:ok, created} <- Sprites.create_custom_connector(sprites, body(p, c, token)) do
      test =
        if c.test_url do
          case Sprites.test_custom_connector(sprites, created.id) do
            {:ok, result} -> result
            {:error, message} -> %{status: "error", message: message}
          end
        end

      {:ok,
       %{connector: created, gateway_url: "#{@gateway}/custom_api/#{created.id}", test: test}}
    end
  end

  defp custom(p) do
    case Enum.find(p.connectors, &(&1.provider == "custom_api")) do
      nil -> {:error, "profile '#{p.pick || p.name}' declares no custom API connector"}
      c -> {:ok, c}
    end
  end

  defp check_token(token) do
    cond do
      String.trim(token) == "" -> {:error, "no token was given, so nothing was sent"}
      String.contains?(token, ["\n", "\r"]) -> {:error, "the token holds a line break"}
      true -> :ok
    end
  end
end
