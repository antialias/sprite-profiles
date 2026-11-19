defmodule SpriteProfiles.Plan do
  @moduledoc """
  The result of merging a set of profiles: everything a Sprite will get, and the order it is
  applied in. Built by `SpriteProfiles.Merge`; printed by `format/1`.

  Every merged item remembers the profile it came from, so a reader can trace each line back.
  Profiles are identified by their qualified name (`acme.linear` for a fetched profile, the
  name for a local one); `picks` maps each to the pick as written, which is how the printed
  plan names them. `sources` says where each fetched profile came from.
  """

  @type t :: %__MODULE__{
          profiles: [String.t()],
          picks: %{optional(String.t()) => String.t()},
          sources: [map()],
          set: String.t(),
          privileged: boolean(),
          labels: [String.t()],
          inputs: [
            %{name: String.t(), value: String.t(), default: boolean(), profile: String.t()}
          ],
          env: %{optional(String.t()) => %{value: term(), profile: String.t()}},
          policy: [SpriteProfiles.Profile.policy_rule()] | nil,
          connectors: [map()],
          services: [map()],
          mcp_servers: [map()],
          claude_settings: map(),
          skills: [map()],
          files: [map()],
          before_checkpoint: [String.t()],
          after_checkpoint: [String.t()],
          setup: [%{profile: String.t(), script: String.t(), timeout: pos_integer()}]
        }

  defstruct profiles: [],
            picks: %{},
            sources: [],
            set: "",
            privileged: false,
            labels: [],
            inputs: [],
            env: %{},
            policy: nil,
            connectors: [],
            services: [],
            mcp_servers: [],
            claude_settings: %{},
            skills: [],
            files: [],
            before_checkpoint: [],
            after_checkpoint: [],
            setup: []

  @doc """
  The network policy as the Sprites API takes it (`{"rules": [...]}`), or nil when no
  profile declares one.
  """
  def policy_json(%__MODULE__{policy: nil}), do: nil

  def policy_json(%__MODULE__{policy: rules}) do
    %{
      "rules" =>
        Enum.map(rules, fn
          :defaults -> %{"include" => "defaults"}
          {action, domain} -> %{"action" => Atom.to_string(action), "domain" => domain}
        end)
    }
  end

  @doc "A human-readable rendering of the plan, as `mix profiles.plan` prints it."
  @spec format(t()) :: String.t()
  def format(%__MODULE__{} = plan) do
    [
      "Plan for #{plan.set}#{if plan.privileged, do: " (privileged: a person may launch it, an agent may not)", else: ""}",
      "",
      section("Apply order", apply_order(plan)),
      if(plan.sources == [], do: [], else: section("Sources", sources(plan))),
      if(plan.inputs == [], do: [], else: section("Inputs", inputs(plan))),
      section("Labels", plan.labels),
      section("Connectors", connectors(plan)),
      section("Network policy", policy(plan)),
      section("Env", env(plan)),
      section("Services", services(plan)),
      section("MCP servers", mcp(plan)),
      section("Claude settings", settings(plan.claude_settings)),
      section("Skills", Enum.map(plan.skills, &"~/#{&1.dest}  (#{shown(plan, &1.profile)})")),
      section("Files", Enum.map(plan.files, &"~/#{&1.dest}  (#{shown(plan, &1.profile)})"))
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  @doc """
  The Sources lines: for each fetched profile, its publisher, repository, ref and commit,
  and whether it runs a setup.sh. Empty for a set of local profiles.
  """
  @spec sources(t()) :: [String.t()]
  def sources(%__MODULE__{sources: sources}) do
    width = sources |> Enum.map(&String.length(&1.pick)) |> Enum.max(fn -> 0 end)

    Enum.map(sources, fn s ->
      sha = String.slice(s.sha, 0, 8)
      ref = if s.ref =~ ~r/^[0-9a-fA-F]{40}$/, do: "commit #{sha}", else: "#{s.ref} = #{sha}"

      setup =
        if s[:setup], do: ", setup.sh (up to #{duration(s.timeout)})", else: ", no setup.sh"

      "#{String.pad_trailing(s.pick, width)}  publisher #{s.owner}, repo #{s.owner}/#{s.repo}, #{ref}#{setup}"
    end)
  end

  defp shown(plan, q), do: Map.get(plan.picks, q, q)

  defp section(title, []), do: ["#{title}: none", ""]
  defp section(title, lines), do: ["#{title}:", Enum.map(lines, &"  #{&1}"), ""]

  defp apply_order(plan) do
    setup = Map.new(plan.setup, &{&1.profile, &1})

    step = fn {name, i} ->
      case setup[name] do
        nil -> "#{i}. #{shown(plan, name)}"
        s -> "#{i}. #{shown(plan, name)}  (setup.sh, up to #{duration(s.timeout)})"
      end
    end

    before = plan.before_checkpoint |> Enum.with_index(1) |> Enum.map(step)
    n = length(plan.before_checkpoint)

    after_ =
      plan.after_checkpoint |> Enum.with_index(n + 1) |> Enum.map(step)

    before ++ ["-- checkpoint \"profiled: #{plan.set}\" --"] ++ after_
  end

  defp duration(s) when rem(s, 3600) == 0, do: "#{div(s, 3600)}h"
  defp duration(s) when rem(s, 60) == 0, do: "#{div(s, 60)}m"
  defp duration(s), do: "#{s}s"

  defp inputs(plan) do
    Enum.map(plan.inputs, fn i ->
      "#{i.name} = #{inspect(i.value)}#{if i.default, do: " (default)", else: ""}  (#{shown(plan, i.profile)})"
    end)
  end

  defp connectors(plan) do
    Enum.map(plan.connectors, fn
      %{provider: "custom_api", name: name} = c when is_binary(name) ->
        "custom_api #{name}  (#{shown(plan, name)}): #{SpriteProfiles.Merge.custom_description(c)}; must admit a Sprite labelled profile:#{name}"

      c ->
        "#{c.provider}  (#{Enum.map_join(c.profiles, ", ", &shown(plan, &1))}); must admit a Sprite labelled #{Enum.map_join(c.profiles, " or ", &"profile:#{&1}")}"
    end)
  end

  defp policy(%{policy: nil}), do: ["(none set: the Sprite's default, unrestricted)"]

  defp policy(%{policy: rules}) do
    Enum.map(rules, fn
      :defaults -> "include defaults"
      {action, domain} -> "#{action} #{domain}"
    end)
  end

  defp env(plan) do
    plan.env
    |> Enum.sort()
    |> Enum.map(fn {key, %{value: v, profile: p}} ->
      "#{key} = #{env_value(v)}  (#{shown(plan, p)})"
    end)
  end

  defp env_value({:secret, name}), do: "<secret #{name}, read at launch>"
  defp env_value({:connector, provider}), do: "<#{provider} connector gateway URL>"
  defp env_value({:input, name}), do: "<input #{name}>"
  defp env_value(v), do: inspect(v)

  defp services(plan) do
    Enum.map(plan.services, fn s ->
      port = if s.http_port, do: ", http_port #{s.http_port}", else: ""
      "#{s.name}: #{Enum.join([s.cmd | s.args], " ")}#{port}  (#{shown(plan, s.profile)})"
    end)
  end

  defp mcp(plan) do
    Enum.map(plan.mcp_servers, fn s ->
      where = s.config["url"] || s.config["command"]
      via = if Map.get(s, :auth_connector), do: ", credential added by the gateway", else: ""
      "#{s.name} (#{s.type}) #{where}#{via}  (#{shown(plan, s.profile)})"
    end)
  end

  defp settings(map) do
    map
    |> leaves([])
    |> Enum.map(fn {path, v} -> "#{Enum.join(path, ".")} = #{Jason.encode!(v)}" end)
  end

  @doc false
  def leaves(map, []) when map == %{}, do: []

  def leaves(map, prefix) when is_map(map) and map_size(map) > 0 do
    map
    |> Enum.sort()
    |> Enum.flat_map(fn {k, v} -> leaves(v, prefix ++ [k]) end)
  end

  def leaves(v, prefix), do: [{prefix, v}]
end
