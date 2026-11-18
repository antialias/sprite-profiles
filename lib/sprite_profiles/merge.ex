defmodule SpriteProfiles.Merge do
  @moduledoc """
  Merges an ordered list of profiles into a `SpriteProfiles.Plan`, or refuses.

  Pure: no files, no network. The rules are the ones in `docs/SPEC.md`: union where that is
  safe, refusal where two profiles disagree, so nothing is ever picked silently. Every
  refusal found is returned, not only the first, so a person can fix them in one pass.
  """

  alias SpriteProfiles.{ClaudeSettings, Plan, Profile, Refusal}

  @max_picks 8

  @doc "The most profiles one set may hold."
  def max_picks, do: @max_picks

  @doc """
  Checks the picked names alone (count, repeats, spelling), before any profile is read.
  """
  @spec check_picks([String.t()]) :: :ok | {:error, [Refusal.t()]}
  def check_picks([]) do
    {:error, [Refusal.new(:no_profiles, [], "a set needs at least one profile; pick one.")]}
  end

  def check_picks(names) do
    bad =
      names
      |> Enum.reject(&Profile.valid_name?/1)
      |> Enum.uniq()
      |> Enum.map(fn name ->
        Refusal.new(
          :bad_name,
          [],
          "#{inspect(name)} is not a profile name; names are 2-31 characters of a-z, 0-9 and '-', starting with a letter."
        )
      end)

    dups =
      names
      |> Enum.frequencies()
      |> Enum.filter(fn {_, n} -> n > 1 end)
      |> Enum.sort()
      |> Enum.map(fn {name, n} ->
        Refusal.new(
          :duplicate_pick,
          [name],
          "profile '#{name}' is picked #{n} times; pick each profile once."
        )
      end)

    count =
      if length(names) > @max_picks do
        [
          Refusal.new(
            :too_many_profiles,
            [],
            "a set holds at most #{@max_picks} profiles and this one has #{length(names)}; drop some."
          )
        ]
      else
        []
      end

    case count ++ dups ++ bad do
      [] -> :ok
      refusals -> {:error, refusals}
    end
  end

  @doc """
  Merges `profiles` in pick order.

  Options: `caller: :person | :agent` (default `:person`). An agent is refused any set
  holding a privileged profile (`not_for_agents`).
  """
  @spec merge([Profile.t()], keyword()) :: {:ok, Plan.t()} | {:error, [Refusal.t()]}
  def merge(profiles, opts \\ []) do
    names = Enum.map(profiles, & &1.name)

    with :ok <- check_picks(names) do
      env = merge_env(profiles)
      provided = Map.keys(env.value)

      results = [
        env,
        merge_services(profiles),
        merge_mcp(profiles, provided),
        merge_settings(profiles),
        merge_files(profiles)
      ]

      refusals =
        Enum.flat_map(results, & &1.refusals) ++ agent_refusals(profiles, opts)

      if refusals == [] do
        [_env, services, mcp, settings, files] = results

        {:ok,
         build_plan(profiles, env.value, services.value, mcp.value, settings.value, files.value)}
      else
        {:error, refusals}
      end
    end
  end

  defp build_plan(profiles, env, services, mcp, settings, {files, skills}) do
    names = Enum.map(profiles, & &1.name)
    {before, after_} = Enum.split_with(profiles, &(&1.checkpoint and not &1.privileged))

    %Plan{
      profiles: names,
      set: Enum.join(names, "+"),
      privileged: Enum.any?(profiles, & &1.privileged),
      labels: labels(profiles),
      env: env,
      policy: policy(profiles),
      connectors: connectors(profiles),
      services: services,
      mcp_servers: mcp,
      claude_settings: settings,
      files: files,
      skills: skills,
      before_checkpoint: Enum.map(before, & &1.name),
      after_checkpoint: Enum.map(after_, & &1.name),
      setup:
        for(
          p <- before ++ after_,
          p.setup,
          do: %{profile: p.name, script: p.setup, timeout: p.timeout}
        )
    }
  end

  ## labels, policy, connectors: unions that never refuse

  defp labels(profiles) do
    (Enum.map(profiles, &"profile:#{&1.name}") ++ Enum.flat_map(profiles, & &1.labels))
    |> Enum.uniq()
  end

  # Union, deduplicated; `include defaults` once; every deny before every allow, so a deny
  # in any profile wins. Nil when no profile declares a policy.
  defp policy(profiles) do
    declared = profiles |> Enum.map(& &1.policy) |> Enum.reject(&is_nil/1)

    if declared == [] do
      nil
    else
      rules = declared |> List.flatten() |> Enum.uniq()
      denies = Enum.filter(rules, &match?({:deny, _}, &1))
      defaults = Enum.filter(rules, &(&1 == :defaults))
      allows = Enum.filter(rules, &match?({:allow, _}, &1))
      denies ++ defaults ++ allows
    end
  end

  defp connectors(profiles) do
    profiles
    |> Enum.flat_map(fn p -> Enum.map(p.connectors, &{&1, p.name}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {provider, owners} -> %{provider: provider, profiles: owners} end)
    |> Enum.sort_by(fn c -> first_index(profiles, hd(c.profiles)) end)
  end

  defp first_index(profiles, name), do: Enum.find_index(profiles, &(&1.name == name))

  ## env: a key two profiles define is a refusal, even with the same value

  defp merge_env(profiles) do
    {value, refusals} =
      Enum.reduce(profiles, {%{}, []}, fn p, {acc, refusals} ->
        p.env
        |> Enum.sort()
        |> Enum.reduce({acc, refusals}, fn {key, v}, {acc, refusals} ->
          case acc do
            %{^key => %{profile: first}} ->
              {acc,
               refusals ++
                 [
                   Refusal.new(
                     :env_collision,
                     [first, p.name],
                     "profiles '#{first}' and '#{p.name}' both define env #{key}; a set will not pick one silently, so remove it from one of them."
                   )
                 ]}

            _ ->
              {Map.put(acc, key, %{value: v, profile: p.name}), refusals}
          end
        end)
      end)

    %{value: value, refusals: refusals}
  end

  ## services: same name refuses; at most one http_port across the set

  defp merge_services(profiles) do
    all = for p <- profiles, s <- p.services, do: Map.put(s, :profile, p.name)

    name_refusals =
      all
      |> Enum.group_by(& &1.name)
      |> Enum.filter(fn {_, list} -> length(list) > 1 end)
      |> Enum.sort_by(fn {_, [s | _]} -> first_index(profiles, s.profile) end)
      |> Enum.map(fn {name, [a, b | _]} ->
        Refusal.new(
          :service_collision,
          [a.profile, b.profile],
          "profiles '#{a.profile}' and '#{b.profile}' both define service '#{name}'; a set will not pick one silently, so rename it in one of them."
        )
      end)

    port_refusals =
      case Enum.filter(all, & &1.http_port) do
        [a, b | _] ->
          [
            Refusal.new(
              :http_port_conflict,
              [a.profile, b.profile],
              "profiles '#{a.profile}' and '#{b.profile}' both give a service an http_port ('#{a.name}' on #{a.http_port}, '#{b.name}' on #{b.http_port}); a Sprite routes its URL to one service, so drop http_port from one of them."
            )
          ]

        _ ->
          []
      end

    %{value: all, refusals: name_refusals ++ port_refusals}
  end

  ## MCP servers: same name refuses; a server that would need a sign-in refuses

  defp merge_mcp(profiles, provided_env) do
    all = for p <- profiles, s <- p.mcp_servers, do: Map.put(s, :profile, p.name)

    collisions =
      all
      |> Enum.group_by(& &1.name)
      |> Enum.filter(fn {_, list} -> length(list) > 1 end)
      |> Enum.sort_by(fn {_, [s | _]} -> first_index(profiles, s.profile) end)
      |> Enum.map(fn {name, [a, b | _]} ->
        Refusal.new(
          :mcp_server_collision,
          [a.profile, b.profile],
          "profiles '#{a.profile}' and '#{b.profile}' both define MCP server '#{name}'; a set will not pick one silently, so remove it from one of them."
        )
      end)

    logins = Enum.flat_map(all, &needs_login(&1, provided_env))

    %{value: all, refusals: collisions ++ logins}
  end

  defp needs_login(%{type: type} = s, provided) do
    missing = Enum.reject(s.requires_env, &(&1 in provided))

    cond do
      type != "stdio" and not s.has_authorization and not s.auth_none ->
        [
          Refusal.new(
            :mcp_needs_login,
            [s.profile],
            "profile '#{s.profile}' adds #{type} MCP server '#{s.name}' with no Authorization header and no auth = \"none\"; an unattended Sprite cannot answer a sign-in, so give it a header or mark it auth = \"none\" if it needs none."
          )
        ]

      missing != [] ->
        [
          Refusal.new(
            :mcp_needs_login,
            [s.profile],
            "profile '#{s.profile}' adds MCP server '#{s.name}', which needs env #{Enum.join(missing, ", ")}, and no profile in the set defines it; an unattended Sprite cannot answer a sign-in, so add a profile that provides it or leave '#{s.profile}' out."
          )
        ]

      true ->
        []
    end
  end

  ## Claude settings: deep merge; a leaf set differently by two profiles refuses, except
  ## the lists that combine (hooks arrays, permissions.allow/deny)

  defp merge_settings(profiles) do
    {merged, _owners, refusals} =
      Enum.reduce(profiles, {%{}, %{}, []}, fn p, acc ->
        p.claude_settings
        |> Plan.leaves([])
        |> Enum.reduce(acc, fn {path, v}, {merged, owners, refusals} ->
          case conflict(merged, owners, path, v) do
            :ok ->
              {put_in_path(merged, path, v), Map.put_new(owners, path, p.name), refusals}

            :combine ->
              combined = ClaudeSettings.combine(get_path(merged, path), v)
              {put_in_path(merged, path, combined), owners, refusals}

            :same ->
              {merged, owners, refusals}

            {:conflict, owner_path} ->
              first = Map.fetch!(owners, owner_path)

              {merged, owners,
               refusals ++
                 [
                   Refusal.new(
                     :settings_collision,
                     [first, p.name],
                     "profiles '#{first}' and '#{p.name}' both set Claude setting #{Enum.join(path, ".")}, to different values; a set will not pick one silently, so remove it from one of them."
                   )
                 ]}
          end
        end)
      end)

    %{value: merged, refusals: refusals}
  end

  # A leaf conflicts with an equal path holding another value, or with a path that is a
  # prefix of it (or it of one) already set by another profile. The lists in
  # `ClaudeSettings.combinable?/1` combine instead, when both sides are lists.
  defp conflict(merged, owners, path, v) do
    cond do
      Map.has_key?(owners, path) and ClaudeSettings.combinable?(path) and is_list(v) and
          is_list(get_path(merged, path)) ->
        :combine

      Map.has_key?(owners, path) ->
        if get_path(merged, path) == v, do: :same, else: {:conflict, path}

      owner = Enum.find(Map.keys(owners), &prefix?(&1, path)) ->
        {:conflict, owner}

      owner = Enum.find(Map.keys(owners), &prefix?(path, &1)) ->
        {:conflict, owner}

      true ->
        :ok
    end
  end

  defp prefix?(short, long),
    do: length(short) < length(long) and Enum.take(long, length(short)) == short

  defp get_path(map, path), do: get_in(map, Enum.map(path, &Access.key(&1)))

  defp put_in_path(map, [key], v), do: Map.put(map, key, v)

  defp put_in_path(map, [key | rest], v),
    do: Map.put(map, key, put_in_path(Map.get(map, key, %{}), rest, v))

  ## files/ and skills: pushed in pick order; one path from two profiles refuses

  defp merge_files(profiles) do
    entries =
      Enum.flat_map(profiles, fn p ->
        files =
          Enum.map(p.files, fn f ->
            %{
              kind: :file,
              profile: p.name,
              source: f.source,
              dest: f.path,
              executable: f.executable
            }
          end)

        skills =
          Enum.flat_map(p.skills, fn s ->
            Enum.map(s.files, fn rel ->
              %{
                kind: :skill,
                profile: p.name,
                source: s.source && Path.join(s.source, rel),
                dest: Path.join([".claude/skills", "#{p.name}--#{s.name}", rel]),
                executable: false
              }
            end)
          end)

        files ++ skills
      end)

    refusals = file_collisions(entries)

    skills =
      for p <- profiles,
          s <- p.skills,
          do: %{
            profile: p.name,
            skill: s.name,
            source: s.source,
            dest: ".claude/skills/#{p.name}--#{s.name}/"
          }

    files =
      entries
      |> Enum.filter(&(&1.kind == :file))
      |> Enum.map(&Map.delete(&1, :kind))

    %{value: {files, skills}, refusals: refusals}
  end

  defp file_collisions(entries) do
    {_, refusals} =
      Enum.reduce(entries, {%{}, []}, fn e, {seen, refusals} ->
        {claims, clashes_with} = path_keys(e.dest)

        clash =
          Enum.find_value(clashes_with, fn key ->
            case seen do
              %{^key => owner} when owner != e.profile -> owner
              _ -> nil
            end
          end)

        seen = Enum.reduce(claims, seen, &Map.put_new(&2, &1, e.profile))

        if clash do
          {seen,
           refusals ++
             [
               Refusal.new(
                 :file_collision,
                 [clash, e.profile],
                 "profiles '#{clash}' and '#{e.profile}' both push ~/#{e.dest}; a set will not pick one silently, so remove it from one of them."
               )
             ]}
        else
          {seen, refusals}
        end
      end)

    refusals
  end

  # A file claims its own path as a file and each parent as a folder. It clashes with the
  # same path pushed as a file or used as a folder, and with a parent pushed as a file.
  defp path_keys(dest) do
    parts = Path.split(dest)
    parents = for n <- 1..(length(parts) - 1)//1, do: Path.join(Enum.take(parts, n))

    claims = [{:file, dest} | Enum.map(parents, &{:dir, &1})]
    clashes = [{:file, dest}, {:dir, dest} | Enum.map(parents, &{:file, &1})]
    {claims, clashes}
  end

  ## privileged

  defp agent_refusals(profiles, opts) do
    if Keyword.get(opts, :caller, :person) == :agent do
      profiles
      |> Enum.filter(& &1.privileged)
      |> Enum.map(fn p ->
        Refusal.new(
          :not_for_agents,
          [p.name],
          "profile '#{p.name}' is privileged; an agent may not launch a set that holds it, so a person must launch this set."
        )
      end)
    else
      []
    end
  end

  ## connectors against what the org has (the launcher supplies the list)

  @doc """
  Checks the plan's connectors against the org's. Pure: the launcher fetches `available`
  from the Sprites API and passes it in.

  Each available connector is a map with `:provider` and its access policy: `allow_all`,
  `sprite_labels` and `name_prefix`, as the Sprites API gives them. See `admits?/3`.
  `setup_urls` maps providers to the URL where one is set up. Option `name:` is the
  Sprite's name, for a policy with a name prefix.
  """
  @spec check_connectors(Plan.t(), [map()], %{optional(String.t()) => String.t()}, keyword()) ::
          :ok | {:error, [Refusal.t()]}
  def check_connectors(%Plan{} = plan, available, setup_urls \\ %{}, opts \\ []) do
    name = Keyword.get(opts, :name)

    refusals =
      Enum.flat_map(plan.connectors, fn %{provider: provider, profiles: owners} ->
        if Enum.any?(available, &(&1.provider == provider and admits?(&1, plan.labels, name))) do
          []
        else
          where =
            case setup_urls do
              %{^provider => url} -> "set one up at #{url}"
              _ -> "set one up in the Sprites dashboard"
            end

          labels = Enum.map_join(owners, " or ", &"profile:#{&1}")
          names = Enum.map_join(owners, " and ", &"'#{&1}'")

          what =
            if length(owners) > 1, do: "profiles #{names} need", else: "profile #{names} needs"

          [
            Refusal.new(
              :connector_missing,
              owners,
              "#{what} a #{provider} connector that admits Sprites labelled #{labels}, and the org has none; #{where} and add that label to its access policy."
            )
          ]
        end
      end)

    if refusals == [], do: :ok, else: {:error, refusals}
  end

  @doc """
  True when a connector's access policy admits a Sprite with `labels` and `name`, by the
  Sprites rule: `allow_all` admits every Sprite; otherwise the Sprite must carry **all** of
  `sprite_labels` and its name must start with `name_prefix`, for whichever of the two the
  policy sets. A policy that sets neither admits no Sprite (the connector is dormant).
  """
  @spec admits?(map(), [String.t()], String.t() | nil) :: boolean()
  def admits?(connector, labels, name) do
    wanted = Map.get(connector, :sprite_labels) || []
    prefix = Map.get(connector, :name_prefix)
    prefix = if prefix in [nil, ""], do: nil, else: prefix

    cond do
      Map.get(connector, :allow_all, false) -> true
      wanted == [] and prefix == nil -> false
      true -> Enum.all?(wanted, &(&1 in labels)) and prefix_ok?(prefix, name)
    end
  end

  defp prefix_ok?(nil, _name), do: true
  defp prefix_ok?(prefix, name) when is_binary(name), do: String.starts_with?(name, prefix)
  defp prefix_ok?(_prefix, nil), do: false
end
