defmodule SpriteProfiles.Merge do
  @moduledoc """
  Merges an ordered list of profiles into a `SpriteProfiles.Plan`, or refuses.

  Pure: no files, no network. The rules are the ones in `docs/SPEC.md`: union where that is
  safe, refusal where two profiles disagree, so nothing is ever picked silently. Every
  refusal found is returned, not only the first, so a person can fix them in one pass.
  """

  alias SpriteProfiles.{Address, ClaudeSettings, Pick, Plan, Profile, Refusal}

  @max_picks 8

  # Fly refuses a label over 128 bytes (measured; see docs/RESULTS.md).
  @max_label 128

  @doc "The longest label a Sprite accepts, in bytes."
  def max_label, do: @max_label

  @doc "The most profiles one set may hold."
  def max_picks, do: @max_picks

  @doc """
  Checks the picks alone (count, repeats, spelling), before any profile is read. A pick is a
  profile name, an address (`owner/repo[/path]@ref`) or a name pick (`@owner/name[@V]`); see
  `SpriteProfiles.Pick`. The same address at two refs, or the same name at two versions, is
  a repeat.
  """
  @spec check_picks([String.t()]) :: :ok | {:error, [Refusal.t()]}
  def check_picks([]) do
    {:error, [Refusal.new(:no_profiles, [], "a set needs at least one profile; pick one.")]}
  end

  def check_picks(picks) do
    bad =
      picks
      |> Enum.uniq()
      |> Enum.flat_map(&pick_problem/1)

    dups =
      picks
      |> Enum.group_by(&pick_identity/1)
      |> Enum.filter(fn {_, list} -> length(list) > 1 end)
      |> Enum.sort_by(fn {_, [first | _]} -> Enum.find_index(picks, &(&1 == first)) end)
      |> Enum.map(fn {id, list} ->
        case Enum.uniq(list) do
          [one] ->
            Refusal.new(
              :duplicate_pick,
              [one],
              "profile '#{one}' is picked #{length(list)} times; pick each profile once."
            )

          several ->
            Refusal.new(
              :duplicate_pick,
              several,
              "#{Enum.map_join(several, " and ", &"'#{&1}'")} are one profile (#{id}) picked at different refs or versions; pick it once."
            )
        end
      end)

    count =
      if length(picks) > @max_picks do
        [
          Refusal.new(
            :too_many_profiles,
            [],
            "a set holds at most #{@max_picks} profiles and this one has #{length(picks)}; drop some."
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

  defp pick_problem(pick) do
    case Pick.kind(pick) do
      :address -> address_problem(pick)
      :name -> name_problem(pick)
      :local -> local_problem(pick)
    end
  end

  defp address_problem(pick) do
    case Address.parse(pick) do
      {:ok, _} ->
        []

      {:error, :address_needs_ref} ->
        [
          Refusal.new(
            :address_needs_ref,
            [pick],
            "#{inspect(pick)} has no ref; add a tag, a branch or a commit, like #{pick}@v1 or #{pick}@main."
          )
        ]

      {:error, :bad_address} ->
        [
          Refusal.new(
            :bad_address,
            [],
            "#{inspect(pick)} is not an address; an address is owner/repo[/path]@ref, as GitHub Actions writes it, or HOST/owner/repo[/path]@ref on another git host (a namespace of several segments ends its repository with .git: HOST/group/sub/repo.git/path@ref)."
          )
        ]
    end
  end

  defp name_problem(pick) do
    case Pick.parse(pick) do
      {:ok, _} ->
        []

      {:error, :bad_name} ->
        [
          Refusal.new(
            :bad_name,
            [],
            "#{inspect(pick)} is not a published name; a name is @owner/name, or @HOST/owner/name on another git host, optionally with a version (@owner/name@1) or a ref (@owner/name@main)."
          )
        ]
    end
  end

  defp local_problem(pick) do
    if Profile.valid_name?(pick) do
      []
    else
      [
        Refusal.new(
          :bad_name,
          [],
          "#{inspect(pick)} is not a profile name; names are 2-31 characters of a-z, 0-9 and '-', starting with a letter."
        )
      ]
    end
  end

  # Two picks are the same profile when they name it the same way, ignoring the ref or
  # version. A name and an address of one profile are told apart only once both are
  # fetched, by their qualified name (`profile_collision`).
  defp pick_identity(pick) do
    case Pick.kind(pick) do
      :address ->
        case Address.parse(pick) do
          {:ok, address} -> Address.identity(address)
          _ -> pick
        end

      :name ->
        case Pick.parse(pick) do
          {:ok, p} -> Pick.identity(p)
          _ -> pick
        end

      :local ->
        pick
    end
  end

  @doc """
  Merges `profiles` in pick order.

  Options: `caller: :person | :agent` (default `:person`). An agent is refused any set
  holding a privileged profile (`not_for_agents`). `inputs: %{name => value}`, the values
  given for the set's inputs (`-i`, or a lock's `[inputs]`); an input not given takes its
  default.
  """
  @spec merge([Profile.t()], keyword()) :: {:ok, Plan.t()} | {:error, [Refusal.t()]}
  def merge(profiles, opts \\ []) do
    profiles = Enum.map(profiles, &identify/1)
    picks = Enum.map(profiles, & &1.pick)

    with :ok <- check_picks(picks),
         :ok <- check_collisions(profiles),
         :ok <- check_labels(profiles) do
      inputs = merge_inputs(profiles, Keyword.get(opts, :inputs, %{}))
      env = merge_env(profiles, inputs.values)
      provided = Map.keys(env.value)

      results = [
        inputs,
        env,
        merge_services(profiles),
        merge_mcp(profiles, provided),
        merge_settings(profiles),
        merge_files(profiles)
      ]

      refusals =
        Enum.flat_map(results, & &1.refusals) ++ agent_refusals(profiles, opts)

      if refusals == [] do
        [inputs, env, services, mcp, settings, files] = results

        plan =
          build_plan(profiles, env.value, services.value, mcp.value, settings.value, files.value)

        {:ok, %{plan | inputs: inputs.value}}
      else
        {:error, refusals}
      end
    end
  end

  # Profiles built by hand (in tests, say) may lack a qualified name or a pick.
  defp identify(%Profile{} = p),
    do: %{p | qualified: p.qualified || p.name, pick: p.pick || p.qualified || p.name}

  defp check_collisions(profiles) do
    refusals =
      profiles
      |> Enum.group_by(& &1.qualified)
      |> Enum.filter(fn {_, list} -> length(list) > 1 end)
      |> Enum.sort_by(fn {q, _} -> first_index(profiles, q) end)
      |> Enum.map(fn {q, list} ->
        picks = Enum.map(list, & &1.pick)

        Refusal.new(
          :profile_collision,
          picks,
          "#{Enum.map_join(picks, " and ", &"'#{&1}'")} are both the profile #{q}, and a profile has one label (profile:#{q}); keep one of them."
        )
      end)

    if refusals == [], do: :ok, else: {:error, refusals}
  end

  defp check_labels(profiles) do
    refusals =
      for p <- profiles,
          label <- ["profile:#{p.qualified}" | p.labels],
          byte_size(label) > @max_label do
        Refusal.new(
          :label_too_long,
          [p.pick],
          "profile '#{p.pick}' gives the label #{label}, which is #{byte_size(label)} bytes; a Sprite takes labels of up to #{@max_label}, so shorten the name."
        )
      end

    if refusals == [], do: :ok, else: {:error, refusals}
  end

  defp build_plan(profiles, env, services, mcp, settings, {files, skills}) do
    names = Enum.map(profiles, & &1.qualified)
    {before, after_} = Enum.split_with(profiles, &(&1.checkpoint and not &1.privileged))

    %Plan{
      profiles: names,
      picks: Map.new(profiles, &{&1.qualified, &1.pick}),
      sources: sources(profiles),
      set: Enum.map_join(profiles, "+", & &1.pick),
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
      before_checkpoint: Enum.map(before, & &1.qualified),
      after_checkpoint: Enum.map(after_, & &1.qualified),
      setup:
        for(
          p <- before ++ after_,
          p.setup,
          do: %{profile: p.qualified, script: p.setup, timeout: p.timeout}
        )
    }
  end

  defp sources(profiles) do
    for %Profile{source: %{} = src} = p <- profiles do
      Map.merge(src, %{
        pick: p.pick,
        profile: p.qualified,
        setup: p.setup != nil,
        timeout: p.timeout
      })
    end
  end

  # How sentences name a profile: its pick as written.
  defp shown(profiles, q) do
    case Enum.find(profiles, &(&1.qualified == q)) do
      nil -> q
      p -> p.pick
    end
  end

  ## labels, policy, connectors: unions that never refuse

  defp labels(profiles) do
    (Enum.map(profiles, &"profile:#{&1.qualified}") ++ Enum.flat_map(profiles, & &1.labels))
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

  # Catalogue providers are grouped by provider; a custom API connector is the profile's
  # own, named by its qualified name.
  defp connectors(profiles) do
    entries = for p <- profiles, c <- p.connectors, do: {c, p.qualified}
    {custom, catalogue} = Enum.split_with(entries, fn {c, _} -> c.provider == "custom_api" end)

    grouped =
      catalogue
      |> Enum.group_by(fn {c, _} -> c.provider end, &elem(&1, 1))
      |> Enum.map(fn {provider, owners} -> %{provider: provider, name: nil, profiles: owners} end)

    own =
      Enum.map(custom, fn {c, q} ->
        c
        |> Map.take([:provider, :base_url, :auth, :endpoints, :test_url])
        |> Map.merge(%{name: q, profiles: [q]})
      end)

    Enum.sort_by(grouped ++ own, fn c ->
      {first_index(profiles, hd(c.profiles)), c.name != nil}
    end)
  end

  defp first_index(profiles, q), do: Enum.find_index(profiles, &(&1.qualified == q))

  ## inputs: one name per set; each resolved to a value before any API call

  defp merge_inputs(profiles, given) do
    declared = for p <- profiles, {name, i} <- Enum.sort(p.inputs), do: {name, i, p}

    collisions =
      declared
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 2))
      |> Enum.filter(fn {_, ps} -> length(ps) > 1 end)
      |> Enum.sort_by(fn {_, [p | _]} -> first_index(profiles, p.qualified) end)
      |> Enum.map(fn {name, [a, b | _]} ->
        Refusal.new(
          :input_collision,
          [a.pick, b.pick],
          "profiles '#{a.pick}' and '#{b.pick}' both declare input #{name}; a value is given by name alone, so rename it in one of them."
        )
      end)

    known = MapSet.new(declared, &elem(&1, 0))

    unknown =
      given
      |> Map.keys()
      |> Enum.sort()
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.map(fn name ->
        have =
          case Enum.sort(MapSet.to_list(known)) do
            [] -> "the set declares no inputs"
            names -> "the set's inputs are #{Enum.join(names, ", ")}"
          end

        Refusal.new(
          :input_unknown,
          [],
          "an input #{name} was given, and no profile in the set declares it; #{have}."
        )
      end)

    {values, entries, problems} =
      declared
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.reduce({%{}, [], []}, fn {name, input, p}, {values, entries, problems} ->
        {value, default?} =
          case Map.fetch(given, name) do
            {:ok, v} -> {v, false}
            :error -> {input.default, true}
          end

        cond do
          is_nil(value) ->
            {values, entries,
             problems ++
               [
                 Refusal.new(
                   :input_missing,
                   [p.pick],
                   "profile '#{p.pick}' needs input #{name} (#{input.summary}) and none was given; give it with -i #{name}=VALUE."
                 )
               ]}

          why = Profile.input_problem(input, value) ->
            {values, entries,
             problems ++
               [
                 Refusal.new(
                   :input_invalid,
                   [p.pick],
                   "profile '#{p.pick}' takes input #{name} (#{input.summary}), and the value given #{why}; give another."
                 )
               ]}

          true ->
            entry = %{name: name, value: value, default: default?, profile: p.qualified}
            {Map.put(values, name, value), entries ++ [entry], problems}
        end
      end)

    %{value: entries, values: values, refusals: collisions ++ unknown ++ problems}
  end

  ## env: a key two profiles define is a refusal, even with the same value

  defp merge_env(profiles, inputs) do
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
                     [shown(profiles, first), p.pick],
                     "profiles '#{shown(profiles, first)}' and '#{p.pick}' both define env #{key}; a set will not pick one silently, so remove it from one of them."
                   )
                 ]}

            _ ->
              v =
                case v do
                  {:input, name} -> Map.get(inputs, name, v)
                  v -> v
                end

              {Map.put(acc, key, %{value: v, profile: p.qualified}), refusals}
          end
        end)
      end)

    %{value: value, refusals: refusals}
  end

  ## services: same name refuses; at most one http_port across the set

  defp merge_services(profiles) do
    all = for p <- profiles, s <- p.services, do: Map.put(s, :profile, p.qualified)

    name_refusals =
      all
      |> Enum.group_by(& &1.name)
      |> Enum.filter(fn {_, list} -> length(list) > 1 end)
      |> Enum.sort_by(fn {_, [s | _]} -> first_index(profiles, s.profile) end)
      |> Enum.map(fn {name, [a, b | _]} ->
        {a, b} = {shown(profiles, a.profile), shown(profiles, b.profile)}

        Refusal.new(
          :service_collision,
          [a, b],
          "profiles '#{a}' and '#{b}' both define service '#{name}'; a set will not pick one silently, so rename it in one of them."
        )
      end)

    port_refusals =
      case Enum.filter(all, & &1.http_port) do
        [a, b | _] ->
          [
            Refusal.new(
              :http_port_conflict,
              [shown(profiles, a.profile), shown(profiles, b.profile)],
              "profiles '#{shown(profiles, a.profile)}' and '#{shown(profiles, b.profile)}' both give a service an http_port ('#{a.name}' on #{a.http_port}, '#{b.name}' on #{b.http_port}); a Sprite routes its URL to one service, so drop http_port from one of them."
            )
          ]

        _ ->
          []
      end

    %{value: all, refusals: name_refusals ++ port_refusals}
  end

  ## MCP servers: same name refuses; a server that would need a sign-in refuses

  defp merge_mcp(profiles, provided_env) do
    all = for p <- profiles, s <- p.mcp_servers, do: Map.put(s, :profile, p.qualified)

    collisions =
      all
      |> Enum.group_by(& &1.name)
      |> Enum.filter(fn {_, list} -> length(list) > 1 end)
      |> Enum.sort_by(fn {_, [s | _]} -> first_index(profiles, s.profile) end)
      |> Enum.map(fn {name, [a, b | _]} ->
        {a, b} = {shown(profiles, a.profile), shown(profiles, b.profile)}

        Refusal.new(
          :mcp_server_collision,
          [a, b],
          "profiles '#{a}' and '#{b}' both define MCP server '#{name}'; a set will not pick one silently, so remove it from one of them."
        )
      end)

    logins =
      Enum.flat_map(all, &needs_login(%{&1 | profile: shown(profiles, &1.profile)}, provided_env))

    %{value: all, refusals: collisions ++ logins}
  end

  defp needs_login(%{type: type} = s, provided) do
    missing = Enum.reject(s.requires_env, &(&1 in provided))

    cond do
      type != "stdio" and not s.has_authorization and not s.auth_none and
          not Map.get(s, :auth_connector, false) ->
        [
          Refusal.new(
            :mcp_needs_login,
            [s.profile],
            "profile '#{s.profile}' adds #{type} MCP server '#{s.name}' with no Authorization header and neither auth = \"none\" nor auth = \"connector\"; an unattended Sprite cannot answer a sign-in, so give it a header, reach it through a connector, or mark it auth = \"none\" if it needs none."
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
              {put_in_path(merged, path, v), Map.put_new(owners, path, p.pick), refusals}

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
                     [first, p.pick],
                     "profiles '#{first}' and '#{p.pick}' both set Claude setting #{Enum.join(path, ".")}, to different values; a set will not pick one silently, so remove it from one of them."
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
              profile: p.qualified,
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
                profile: p.qualified,
                source: s.source && Path.join(s.source, rel),
                dest: Path.join([".claude/skills", skill_folder(p, s), rel]),
                executable: false
              }
            end)
          end)

        files ++ skills
      end)

    refusals = file_collisions(entries, profiles)

    skills =
      for p <- profiles,
          s <- p.skills,
          do: %{
            profile: p.qualified,
            skill: s.name,
            source: s.source,
            dest: ".claude/skills/#{skill_folder(p, s)}/"
          }

    files =
      entries
      |> Enum.filter(&(&1.kind == :file))
      |> Enum.map(&Map.delete(&1, :kind))

    %{value: {files, skills}, refusals: refusals}
  end

  @doc """
  The folder under `~/.claude/skills/` a profile's skill lands in:
  `<qualified name>--<skill>`. Claude Code loads skills from folders with a `.` in their
  name (checked on a Sprite; see docs/RESULTS.md).
  """
  def skill_folder(%Profile{} = p, %{name: skill}), do: "#{p.qualified || p.name}--#{skill}"

  defp file_collisions(entries, profiles) do
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
                 [shown(profiles, clash), shown(profiles, e.profile)],
                 "profiles '#{shown(profiles, clash)}' and '#{shown(profiles, e.profile)}' both push ~/#{e.dest}; a set will not pick one silently, so remove it from one of them."
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
          [p.pick],
          "profile '#{p.pick}' is privileged; an agent may not launch a set that holds it, so a person must launch this set."
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
  `sprite_labels` and `name_prefix`, as the Sprites API gives them (see `admits?/3`). A
  custom API connector also has `:name`, `:allowed_endpoints`, `:blocked_endpoints` and
  `:base_url` (nil when the API does not report it). `setup_urls` maps providers to the URL
  where one is set up. Option `name:` is the Sprite's name, for a policy with a name prefix.

  A catalogue provider needs a connector of that provider admitting the Sprite
  (`connector_missing`). A custom API connector needs the one named by its profile's
  qualified name (`connector_missing`), admitting the Sprite (`connector_not_admitted`),
  covering every declared endpoint (`connector_endpoints`) and, when known, with the
  declared base URL (`connector_base_url`).
  """
  @spec check_connectors(Plan.t(), [map()], %{optional(String.t()) => String.t()}, keyword()) ::
          :ok | {:error, [Refusal.t()]}
  def check_connectors(%Plan{} = plan, available, setup_urls \\ %{}, opts \\ []) do
    name = Keyword.get(opts, :name)

    refusals =
      Enum.flat_map(plan.connectors, fn
        %{provider: "custom_api", name: cname} = c when is_binary(cname) ->
          check_custom(plan, c, available, name)

        c ->
          check_catalogue(plan, c, available, setup_urls, name)
      end)

    if refusals == [], do: :ok, else: {:error, refusals}
  end

  defp check_catalogue(plan, %{provider: provider, profiles: owners}, available, setup_urls, name) do
    if Enum.any?(available, &(&1.provider == provider and admits?(&1, plan.labels, name))) do
      []
    else
      where =
        case setup_urls do
          %{^provider => url} -> "set one up at #{url}"
          _ -> "set one up in the Sprites dashboard"
        end

      labels = Enum.map_join(owners, " or ", &"profile:#{&1}")
      picks = Enum.map(owners, &Map.get(plan.picks, &1, &1))
      names = Enum.map_join(picks, " and ", &"'#{&1}'")

      what =
        if length(owners) > 1, do: "profiles #{names} need", else: "profile #{names} needs"

      [
        Refusal.new(
          :connector_missing,
          picks,
          "#{what} a #{provider} connector that admits Sprites labelled #{labels}, and the org has none; #{where} and add that label to its access policy."
        )
      ]
    end
  end

  defp check_custom(plan, c, available, sprite_name) do
    pick = Map.get(plan.picks, c.name, c.name)
    label = "profile:#{c.name}"
    named = Enum.filter(available, &(&1.provider == "custom_api" and &1[:name] == c.name))
    admitting = Enum.filter(named, &admits?(&1, plan.labels, sprite_name))
    wanted = custom_description(c)
    fix = "a person creates or repairs it with: mix profiles.connect -p #{pick}"

    case {named, admitting} do
      {[], _} ->
        [
          Refusal.new(
            :connector_missing,
            [pick],
            "profile '#{pick}' needs a custom API connector named #{c.name} (#{wanted}), and the org has none; #{fix}, or in the Sprites dashboard with an access policy admitting Sprites labelled #{label}."
          )
        ]

      {_, []} ->
        [
          Refusal.new(
            :connector_not_admitted,
            [pick],
            "profile '#{pick}' needs the custom API connector #{c.name}, and its access policy does not admit this Sprite; it must admit Sprites labelled #{label}, so #{fix}."
          )
        ]

      {_, [found | _]} ->
        uncovered =
          Enum.reject(
            c.endpoints,
            &endpoint_covered?(
              &1,
              found[:allowed_endpoints] || [],
              found[:blocked_endpoints] || []
            )
          )

        endpoints =
          if uncovered == [] do
            []
          else
            [
              Refusal.new(
                :connector_endpoints,
                [pick],
                "profile '#{pick}' calls #{Enum.join(uncovered, ", ")} through the custom API connector #{c.name}, and its access policy does not allow #{if length(uncovered) > 1, do: "them", else: "it"} (allowed: #{list_or_all(found[:allowed_endpoints])}; blocked: #{list_or_none(found[:blocked_endpoints])}); #{fix}."
              )
            ]
          end

        base =
          if found[:base_url] in [nil, ""] or same_url?(found.base_url, c.base_url) do
            []
          else
            [
              Refusal.new(
                :connector_base_url,
                [pick],
                "profile '#{pick}' reaches #{c.base_url} through the custom API connector #{c.name}, and that connector points at #{found.base_url}; #{fix}."
              )
            ]
          end

        endpoints ++ base
    end
  end

  @doc "How a plan names a custom API connector's settings: base URL, auth, endpoints."
  def custom_description(c) do
    "base URL #{c.base_url}, auth #{auth_description(c.auth)}, endpoints #{Enum.join(c.endpoints, " ")}"
  end

  defp auth_description(%{method: "header", value: ""}), do: "header (bare token)"
  defp auth_description(%{method: "header", value: prefix}), do: "header (#{prefix})"
  defp auth_description(%{method: method, value: v}), do: "#{method} (#{v})"
  defp auth_description(_), do: "header (Bearer)"

  defp list_or_all(list) when list in [nil, []], do: "every path"
  defp list_or_all(list), do: Enum.join(list, " ")
  defp list_or_none(list) when list in [nil, []], do: "none"
  defp list_or_none(list), do: Enum.join(list, " ")

  defp same_url?(a, b), do: String.trim_trailing(a, "/") == String.trim_trailing(b, "/")

  @doc """
  The connector the launcher uses for a plan connector entry: for a custom API connector,
  the one named by its profile that admits the Sprite; for a catalogue provider, the first
  of that provider that admits it. Nil when there is none.
  """
  def find_connector(entry, available, labels, sprite_name) do
    Enum.find(available, fn a ->
      a.provider == entry.provider and
        (entry[:name] == nil or a[:name] == entry.name) and
        admits?(a, labels, sprite_name)
    end)
  end

  @doc """
  True when a connector's endpoint rules let a Sprite call every path the declared pattern
  names. `declared` is `/exact` or `/prefix*`. It is covered when `allowed` is empty (Fly
  then allows every path) or holds a pattern covering it: the same pattern, or `/p*` where
  `p` is a prefix of the declared pattern's literal part. And no `blocked` pattern may
  overlap it, compared without regard to case, as Fly blocks.
  """
  @spec endpoint_covered?(String.t(), [String.t()], [String.t()]) :: boolean()
  def endpoint_covered?(declared, allowed, blocked) do
    allowed? = allowed == [] or Enum.any?(allowed, &allow_covers?(&1, declared))
    allowed? and not Enum.any?(blocked, &overlaps?(&1, declared))
  end

  defp allow_covers?(same, same), do: true

  defp allow_covers?(allow, declared) do
    case wildcard(allow) do
      {:prefix, p} -> String.starts_with?(literal(declared), p)
      {:exact, _} -> false
    end
  end

  defp overlaps?(block, declared) do
    {bk, b} = wildcard(String.downcase(block))
    {dk, d} = wildcard(String.downcase(declared))

    case {bk, dk} do
      {:exact, :exact} -> b == d
      {:prefix, :exact} -> String.starts_with?(d, b)
      {:exact, :prefix} -> String.starts_with?(b, d)
      {:prefix, :prefix} -> String.starts_with?(d, b) or String.starts_with?(b, d)
    end
  end

  defp wildcard(pattern) do
    if String.ends_with?(pattern, "*"),
      do: {:prefix, String.trim_trailing(pattern, "*")},
      else: {:exact, pattern}
  end

  defp literal(pattern), do: elem(wildcard(pattern), 1)

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
