defmodule SpriteProfiles.Commands.Show do
  @moduledoc """
  `sprite-profiles show PICK`: resolve one pick as a launch would (a local name, an
  address or a published name on any supported host) and print what it can reach and do,
  computed from the loaded `%Profile{}`, then how to connect and launch it.

      @acme/linear 1.1.0  acme/sprite-profiles/linear@linear/v1.1.0 = 3c3c3c3c
        Linear's MCP server, through a connector
        Reaches:     connector custom_api https://mcp.linear.app, header (Bearer), /mcp only
        Network:     defaults; allows mcp.linear.app
        MCP servers: linear (http, credential from the connector)
        Env:         none
        Skills:      triage
        setup.sh:    none          privileged: no          files: 0
        Once per org:  sprite-profiles connect @acme/linear
        Launch:        sprite-profiles launch claude-code @acme/linear --name demo

  `touches/1` is the one-line form `search` prints.
  """

  alias SpriteProfiles.{Merge, Out, Pick, Profile, Resolver}

  @doc "Shows `pick`; returns the exit status (0, or 1 when it cannot be resolved)."
  @spec run(String.t(), keyword(), Out.t()) :: non_neg_integer()
  def run(pick, opts, %Out{} = out) do
    {dirs, resolve_opts} = Keyword.pop(opts, :dirs)
    {bundled, resolve_opts} = Keyword.pop(resolve_opts, :bundled)

    with :ok <- Merge.check_picks([pick]),
         {:ok, [profile]} <- Resolver.find([pick], dirs, resolve_opts) do
      Out.info(out, Enum.join(lines(profile, pick, bundled), "\n"))
      0
    else
      {:error, problems} -> Out.refused(out, problems)
    end
  end

  @doc "The lines `show` prints for a loaded profile picked as `pick`."
  @spec lines(Profile.t(), String.t(), Path.t() | nil) :: [String.t()]
  def lines(%Profile{} = p, pick, bundled \\ nil) do
    [
      header(p, pick, bundled),
      "  #{p.summary}",
      field("Reaches:", reaches(p)),
      field("Network:", network(p.policy)),
      if(p.services != [], do: field("Services:", Enum.map_join(p.services, ", ", &service/1))),
      field("MCP servers:", list_or_none(Enum.map(p.mcp_servers, &mcp/1))),
      field("Env:", list_or_none(env(p.env))),
      if(p.inputs != %{}, do: field("Inputs:", inputs(p.inputs))),
      field("Skills:", list_or_none(Enum.map(p.skills, & &1.name))),
      "  " <>
        column("setup.sh:    #{setup(p)}", 28) <>
        column("privileged: #{yes_no(p.privileged)}", 18) <>
        "files: #{length(p.files)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(hints(p, pick))
  end

  # At least two spaces after the text.
  defp column(text, width), do: String.pad_trailing(text, max(width, String.length(text) + 2))

  defp field(label, value), do: "  " <> String.pad_trailing(label, 13) <> value

  defp header(p, pick, bundled) do
    case p.source do
      nil ->
        where =
          cond do
            bundled && p.path && String.starts_with?(p.path, bundled) -> "bundled example"
            p.path -> "local, #{Out.home_relative(p.path)}"
            true -> "local"
          end

        "#{p.name}  (#{where})"

      s ->
        sha = String.slice(s.sha, 0, 8)

        case Pick.parse(pick) do
          {:ok, parsed} ->
            folder = if s.path in [nil, ""], do: "", else: "/#{s.path}"

            "#{Pick.base(parsed)} #{s.version || s.ref}  #{s.owner}/#{s.repo}#{folder}@#{s.ref} = #{sha}"

          _ ->
            "#{pick}  #{s.kind} #{s.ref} = #{sha}"
        end
    end
  end

  defp reaches(%Profile{connectors: []}), do: "no connector"

  defp reaches(p) do
    Enum.map_join(p.connectors, "; ", fn
      %{provider: "custom_api"} = c ->
        "connector custom_api #{c.base_url}, #{auth(c.auth)}, #{Enum.join(c.endpoints, " ")} only"

      c ->
        "connector #{c.provider} (from the Sprites catalogue)"
    end)
  end

  defp auth(%{method: "header", value: ""}), do: "bare token header"
  defp auth(%{method: "header", value: prefix}), do: "#{prefix} header"
  defp auth(%{method: "custom_header", value: h}), do: "#{h} header"
  defp auth(%{method: "query_param", value: q}), do: "?#{q}= parameter"
  defp auth(%{method: "url_path", value: t}), do: "in the path #{t}"
  defp auth(_), do: "Bearer header"

  defp network(nil), do: "sets no policy"

  defp network(rules) do
    allows = for {:allow, d} <- rules, do: d
    denies = for {:deny, d} <- rules, do: d

    [
      if(:defaults in rules, do: "defaults"),
      if(allows != [], do: "allows #{Enum.join(allows, ", ")}"),
      if(denies != [], do: "denies #{Enum.join(denies, ", ")}")
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "allows nothing"
      parts -> Enum.join(parts, "; ")
    end
  end

  defp service(%{name: n, http_port: nil}), do: n
  defp service(%{name: n, http_port: port}), do: "#{n} (http port #{port})"

  defp mcp(s) do
    how =
      cond do
        s.auth_connector -> ", credential from the connector"
        s.has_authorization -> ", Authorization header"
        s.requires_env != [] -> ", reads #{Enum.join(s.requires_env, ", ")}"
        true -> ""
      end

    "#{s.name} (#{s.type}#{how})"
  end

  defp env(env) do
    env
    |> Enum.sort()
    |> Enum.map(fn
      {k, {:secret, name}} -> "#{k} (secret #{name})"
      {k, {:connector, provider}} -> "#{k} (#{provider} connector URL)"
      {k, {:input, name}} -> "#{k} (input #{name})"
      {k, _} -> k
    end)
  end

  defp inputs(inputs) do
    inputs
    |> Enum.sort()
    |> Enum.map_join(", ", fn
      {name, %{default: nil}} -> "#{name} (required)"
      {name, %{default: d}} -> "#{name} (default #{inspect(d)})"
    end)
  end

  defp setup(%Profile{setup: nil}), do: "none"
  defp setup(p), do: "yes, up to #{duration(p.timeout)}"

  defp list_or_none([]), do: "none"
  defp list_or_none(list), do: Enum.join(list, ", ")

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"

  defp duration(s) when rem(s, 3600) == 0, do: "#{div(s, 3600)}h"
  defp duration(s) when rem(s, 60) == 0, do: "#{div(s, 60)}m"
  defp duration(s), do: "#{s}s"

  defp hints(p, pick) do
    custom? = Enum.any?(p.connectors, &(&1.provider == "custom_api"))
    catalogue = for c <- p.connectors, c.provider != "custom_api", do: c.provider

    connect =
      cond do
        custom? ->
          ["  Once per org:  sprite-profiles connect #{pick}"]

        catalogue != [] ->
          ["  Once per org:  add #{Enum.join(catalogue, ", ")} in the Sprites dashboard"]

        true ->
          []
      end

    set = if p.name == "claude-code", do: [pick], else: ["claude-code", pick]
    connect ++ ["  Launch:        sprite-profiles launch #{Enum.join(set, " ")} --name demo"]
  end

  @doc """
  What a profile can touch, in one line for `search`: `privileged`, `setup.sh 10m`, its
  connectors (`connector <host> <endpoints>` or `connector <provider>`), its services
  (`service <name>:<port>`) and the domains it allows (`allows a, b +N`). A profile with
  none of those is `nothing beyond the defaults`.
  """
  @spec touches(Profile.t()) :: String.t()
  def touches(%Profile{} = p) do
    allows = for {:allow, d} <- p.policy || [], do: d

    allows_text =
      case allows do
        [] -> nil
        [a, b] -> "allows #{a}, #{b}"
        [a] -> "allows #{a}"
        [a, b | rest] -> "allows #{a}, #{b} +#{length(rest)}"
      end

    [
      if(p.privileged, do: "privileged"),
      if(p.setup, do: "setup.sh #{duration(p.timeout)}"),
      Enum.map(p.connectors, fn
        %{provider: "custom_api"} = c ->
          "connector #{URI.parse(c.base_url).host} #{Enum.join(c.endpoints, " ")}"

        c ->
          "connector #{c.provider}"
      end),
      Enum.map(p.services, fn
        %{name: n, http_port: nil} -> "service #{n}"
        %{name: n, http_port: port} -> "service #{n}:#{port}"
      end),
      allows_text
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "nothing beyond the defaults"
      parts -> Enum.join(parts, ", ")
    end
  end
end
