defmodule SpriteProfiles.Launcher do
  @moduledoc """
  Creates a Sprite and applies a set of profiles to it.

  The sequence (see `docs/SPEC.md`, "Launching"):

    1. Resolve the set and refuse locally, before any API call: bad picks, addresses that
       cannot be resolved or fetched, invalid profiles, merge refusals, a missing secret, a
       bad Sprite name. A fetched profile is named by its qualified name (`acme.linear`)
       in its label, its skills folder and `PROFILED_PROFILE`; its Task hold, whose name
       may not hold a `.`, is `profiled-setup-acme--linear`.
    2. Check connectors against the org's (only when the set needs one).
    3. Create the Sprite with its labels, and verify them; set them again if they did not
       stick.
    4. Set the network policy, when the plan has one.
    5. Per profile, in plan order: push `files/` and skills, lay its Claude settings over the
       Sprite's, register its MCP servers, run `setup.sh` under a Sprites Task hold with a
       heartbeat, then create its services. The env file is written at the start of each
       phase.
    6. Checkpoint with the comment `profiled: <set>`.
    7. Apply privileged and `checkpoint = false` profiles the same way.
    8. Write a launch record (JSON) and return it, with every step's time.

  All Sprite access goes through a `SpriteProfiles.Sprites` handle, so tests use a stub.
  """

  alias SpriteProfiles.{
    ClaudeSettings,
    Merge,
    Plan,
    Profile,
    ProfilePath,
    Refusal,
    Resolver,
    Sprites
  }

  @gateway "https://api.sprites.dev/v1/gateway"
  @sprite_name_re ~r/^[a-z][a-z0-9-]{1,62}$/
  @state_dir "~/.local/state/sprite-profiles/launches"
  @secrets_dir "~/.config/sprite-profiles/secrets"

  # Launcher-owned paths, relative to the Sprite's $HOME.
  @env_file ".config/profiled/env.sh"
  @runner ".config/profiled/run-setup.sh"
  @setup_dir ".config/profiled/setup"

  @doc """
  Resolves `names` (picks: names or addresses) into `{:ok, plan, profiles, secrets}`, or
  `{:error, refusals}`. Calls no Sprites API: reads the profiles folder and the secrets
  folder, and fetches from GitHub what an address needs and the cache lacks.

  Options: `:dirs` (the profile search path; see `SpriteProfiles.ProfilePath`), `:dir` (one
  folder, instead of `:dirs`), `:caller` (`:person` or `:agent`), `:secrets_dir`,
  `:name` (checked when given), `:inputs` (`%{name => value}`, the values given for the
  set's inputs), and those of `SpriteProfiles.Resolver.find/3` (`:pins`
  from a lock, `:offline`, `:cache_dir`, `:req_options`).
  """
  def resolve(names, opts \\ []) do
    with :ok <- Merge.check_picks(names),
         {:ok, profiles} <- Resolver.find(names, dirs(opts), opts),
         {:ok, plan} <-
           Merge.merge(profiles,
             caller: Keyword.get(opts, :caller, :person),
             inputs: Keyword.get(opts, :inputs, %{})
           ),
         :ok <- check_name(opts[:name]),
         {:ok, secrets} <- read_secrets(plan, Keyword.get(opts, :secrets_dir, @secrets_dir)) do
      {:ok, plan, profiles, secrets}
    end
  end

  @doc """
  Launches a set. Returns `{:ok, record}`, `{:error, refusals}` when refused before a
  Sprite was created, or `{:error, record}` when a step failed.

  Options, besides those of `resolve/2`:

    * `:sprites` - a `SpriteProfiles.Sprites` handle (required)
    * `:name` - the Sprite's name; default `<picks>-<4 hex>`
    * `:destroy_on_failure` - destroy the Sprite when a step after its creation fails
    * `:state_dir` - where launch records go (default `#{@state_dir}`)
    * `:on_step` - `fun(step)`, called as each step finishes, for live output
    * `:on_resolved` - `fun(plan)`, called once the set is resolved, before any API call
  """
  def launch(names, opts) do
    sprites = Keyword.fetch!(opts, :sprites)

    with {:ok, plan, profiles, secrets} <- resolve(names, opts) do
      name = opts[:name] || default_name(plan)
      Keyword.get(opts, :on_resolved, fn _ -> :ok end).(plan)

      state = %{
        sprites: sprites,
        name: name,
        plan: plan,
        profiles: Map.new(profiles, &{&1.qualified, &1}),
        secrets: secrets,
        connector_env: %{},
        phase_env: %{},
        home: nil,
        info: nil,
        labels_via: nil,
        checkpoint: nil,
        created: false,
        steps: [],
        on_step: Keyword.get(opts, :on_step, fn _ -> :ok end),
        started_at: DateTime.utc_now()
      }

      case run_steps(state, steps(plan)) do
        {:ok, state} ->
          {:ok, finish(state, :ok, nil, opts)}

        {:refused, refusals} ->
          {:error, refusals}

        {:error, state, error} ->
          state = maybe_destroy(state, opts)
          {:error, finish(state, :failed, error, opts)}
      end
    end
  end

  ## the steps

  defp steps(plan) do
    phase = fn names, label ->
      [{:env, nil, label} | Enum.flat_map(names, &profile_steps/1)]
    end

    connectors = if plan.connectors == [], do: [], else: [{:connectors, nil, nil}]
    policy = if plan.policy, do: [{:policy, nil, nil}], else: []

    connectors ++
      [{:create, nil, nil}] ++
      policy ++
      [{:prepare, nil, nil}] ++
      phase.(plan.before_checkpoint, :checkpointed) ++
      [{:checkpoint, nil, nil}] ++
      if(plan.after_checkpoint == [], do: [], else: phase.(plan.after_checkpoint, :all))
  end

  defp profile_steps(name) do
    for kind <- [:files, :settings, :mcp, :setup, :services], do: {kind, name, nil}
  end

  defp run_steps(state, steps) do
    Enum.reduce_while(steps, {:ok, state}, fn {kind, profile, arg}, {:ok, state} ->
      t0 = System.monotonic_time(:millisecond)

      case step(kind, profile, arg, state) do
        :skip ->
          {:cont, {:ok, state}}

        {:ok, state, detail} ->
          {:cont, {:ok, record_step(state, kind, profile, t0, :ok, detail)}}

        {:refused, refusals} ->
          {:halt, {:refused, refusals}}

        {:error, message} ->
          state = record_step(state, kind, profile, t0, :failed, message)
          {:halt, {:error, state, %{step: kind, profile: profile, message: message}}}
      end
    end)
  end

  defp record_step(state, kind, profile, t0, outcome, detail) do
    s = %{
      step: kind,
      profile: profile,
      ms: System.monotonic_time(:millisecond) - t0,
      outcome: outcome,
      detail: detail
    }

    state.on_step.(s)
    %{state | steps: state.steps ++ [s]}
  end

  # 2. connectors
  defp step(:connectors, _, _, state) do
    with {:ok, available} <- Sprites.list_connectors(state.sprites) do
      case Merge.check_connectors(state.plan, available, %{}, name: state.name) do
        :ok ->
          env =
            for {key, %{value: {:connector, provider}, profile: p}} <- state.plan.env,
                into: %{} do
              entry =
                Enum.find(state.plan.connectors, fn c ->
                  c.provider == provider and (c.name == nil or c.name == p)
                end)

              c = Merge.find_connector(entry, available, state.plan.labels, state.name)
              {key, "#{@gateway}/#{provider}/#{c.id}"}
            end

          names = Enum.map_join(state.plan.connectors, ", ", &connector_name/1)
          {:ok, %{state | connector_env: env}, "admitted: #{names}"}

        {:error, refusals} ->
          {:refused, refusals}
      end
    end
  end

  # 3. create, with labels; verify them
  defp step(:create, _, _, state) do
    want = state.plan.labels

    with {:ok, info} <- Sprites.create(state.sprites, state.name, want) do
      state = %{state | created: true, info: info}

      if same_labels?(info.labels, want) do
        {:ok, %{state | labels_via: "create"}, "labels set at create: #{Enum.join(want, ", ")}"}
      else
        with {:ok, _} <- Sprites.set_labels(state.sprites, state.name, want),
             {:ok, info} <- Sprites.get(state.sprites, state.name) do
          if same_labels?(info.labels, want) do
            {:ok, %{state | info: info, labels_via: "update"},
             "labels set after create: #{Enum.join(want, ", ")}"}
          else
            {:error, "the Sprite's labels are #{inspect(info.labels)}, not #{inspect(want)}"}
          end
        end
      end
    end
  end

  # 4. network policy
  defp step(:policy, _, _, state) do
    policy = Plan.policy_json(state.plan)

    with :ok <- Sprites.set_policy(state.sprites, state.name, policy) do
      {:ok, state, "#{length(policy["rules"])} rules"}
    end
  end

  # $HOME, the env file sourced from ~/.bashrc, the setup runner
  defp step(:prepare, _, _, state) do
    script = """
    set -e
    mkdir -p "$HOME/.config/profiled/setup"
    line='[ -f "$HOME/#{@env_file}" ] && . "$HOME/#{@env_file}"'
    grep -qxF "$line" "$HOME/.bashrc" 2>/dev/null || printf '%s\\n' "$line" >> "$HOME/.bashrc"
    printf '%s' "$HOME"
    """

    with {:ok, home} <- sh(state, script),
         state = %{state | home: String.trim(home)},
         :ok <- write(state, @runner, runner_script(), 0o755) do
      {:ok, state, "home #{state.home}"}
    end
  end

  # the env file for a phase: the checkpointed profiles' env, then everyone's
  defp step(:env, _, phase, state) do
    names =
      case phase do
        :checkpointed -> state.plan.before_checkpoint
        :all -> state.plan.profiles
      end

    env = env_values(state, names)
    content = Enum.map_join(Enum.sort(env), "", fn {k, v} -> "export #{k}=#{sh_quote(v)}\n" end)
    header = "# Written by sprite-profiles for the set #{state.plan.set}.\n"

    with :ok <- write(state, @env_file, header <> content, 0o600) do
      {:ok, %{state | phase_env: env},
       "#{map_size(env)} vars: #{env |> Map.keys() |> Enum.sort() |> Enum.join(", ")}"}
    end
  end

  # 5a. files and skills, as one tarball
  defp step(:files, p, _, state) do
    profile = state.profiles[p]

    case file_entries(profile) do
      [] ->
        :skip

      entries ->
        with {:ok, tar} <- tarball(entries),
             remote = "/tmp/profiled-#{p}.tar",
             :ok <- Sprites.write_file(state.sprites, state.name, remote, tar, 0o600),
             {:ok, _} <- sh(state, untar_script(remote, entries)) do
          skills = Enum.count(profile.skills)
          files = length(profile.files)
          {:ok, state, "#{files} files, #{skills} skills"}
        end
    end
  end

  # 5b. Claude settings, laid over the Sprite's own
  defp step(:settings, p, _, state) do
    fragment = state.profiles[p].claude_settings

    if fragment == %{} do
      :skip
    else
      with {:ok, current} <- sh(state, "cat \"$HOME/.claude/settings.json\" 2>/dev/null || true"),
           {:ok, base} <- decode_settings(current),
           merged = ClaudeSettings.overlay(base, fragment),
           :ok <-
             write(
               state,
               ".claude/settings.json",
               Jason.encode!(merged, pretty: true) <> "\n",
               0o644
             ) do
        {:ok, state, Enum.join(Map.keys(fragment) |> Enum.sort(), ", ")}
      end
    end
  end

  # 5c. MCP servers, at user scope
  defp step(:mcp, p, _, state) do
    servers = state.profiles[p].mcp_servers

    if servers == [] do
      :skip
    else
      script =
        Enum.map_join(servers, "\n", fn s ->
          name = sh_quote(s.name)

          "claude mcp remove --scope user #{name} >/dev/null 2>&1 || true\n" <>
            "claude mcp add-json --scope user #{name} #{sh_quote(Jason.encode!(s.config))}"
        end)

      with {:ok, _} <- sh(state, "set -e\n" <> script) do
        {:ok, state, Enum.map_join(servers, ", ", & &1.name)}
      end
    end
  end

  # 5d. setup.sh under a Task hold
  defp step(:setup, p, _, state) do
    profile = state.profiles[p]

    if profile.setup == nil do
      :skip
    else
      script = File.read!(profile.setup)
      args = [p, Integer.to_string(profile.timeout), state.plan.set]

      with :ok <- write(state, "#{@setup_dir}/#{p}.sh", script, 0o755),
           {:ok, out} <-
             sh(
               state,
               "bash \"$HOME/#{@runner}\" " <> Enum.map_join(args, " ", &sh_quote/1),
               timeout: (profile.timeout + 60) * 1000
             ) do
        {:ok, state, last_line(out)}
      end
    end
  end

  # 5e. services
  defp step(:services, p, _, state) do
    services = state.profiles[p].services

    if services == [] do
      :skip
    else
      Enum.reduce_while(services, {:ok, state, []}, fn s, {:ok, state, done} ->
        # A service gets its phase's env, the same set the env file holds.
        spec = Map.put(%{s | dir: expand(s.dir, state.home)}, :env, state.phase_env)

        case Sprites.put_service(state.sprites, state.name, s.name, spec) do
          :ok -> {:cont, {:ok, state, done ++ [s.name]}}
          {:error, message} -> {:halt, {:error, message}}
        end
      end)
      |> case do
        {:ok, state, names} -> {:ok, state, Enum.join(names, ", ")}
        error -> error
      end
    end
  end

  # 6. checkpoint
  defp step(:checkpoint, _, _, state) do
    with {:ok, id} <-
           Sprites.checkpoint(state.sprites, state.name, "profiled: #{state.plan.set}") do
      {:ok, %{state | checkpoint: id}, id}
    end
  end

  ## resolve helpers

  defp dirs(opts) do
    cond do
      opts[:dirs] -> opts[:dirs]
      opts[:dir] -> [Path.expand(opts[:dir])]
      true -> ProfilePath.dirs([])
    end
  end

  defp check_name(nil), do: :ok

  defp check_name(name) do
    if is_binary(name) and Regex.match?(@sprite_name_re, name) do
      :ok
    else
      {:error,
       [
         Refusal.new(
           :bad_sprite_name,
           [],
           "#{inspect(name)} is not a Sprite name this launcher will use; use 2-63 characters of a-z, 0-9 and '-', starting with a letter."
         )
       ]}
    end
  end

  # Secrets for privileged profiles, read from the launching machine before anything runs.
  defp read_secrets(plan, dir) do
    dir = Path.expand(dir)

    {secrets, refusals} =
      plan.env
      |> Enum.sort()
      |> Enum.reduce({%{}, []}, fn
        {key, %{value: {:secret, secret}, profile: p}}, {acc, refusals} ->
          path = Path.join(dir, secret)

          case File.read(path) do
            {:ok, text} when byte_size(text) > 0 ->
              {Map.put(acc, key, String.trim_trailing(text, "\n")), refusals}

            _ ->
              {acc,
               refusals ++
                 [
                   Refusal.new(
                     :secret_missing,
                     [p],
                     "profile '#{p}' needs the secret #{secret} and there is none at #{path}; put it there (one line, chmod 600) or leave '#{p}' out."
                   )
                 ]}
          end

        _, acc ->
          acc
      end)

    if refusals == [], do: {:ok, secrets}, else: {:error, refusals}
  end

  @doc "Where secrets are read from unless `:secrets_dir` says otherwise."
  def default_secrets_dir, do: @secrets_dir

  @doc """
  The default Sprite name for a plan: the profiles' short names joined by '-', then 4 hex
  digits.
  """
  def default_name(%Plan{profiles: names}) do
    base =
      names
      |> Enum.map_join("-", &(&1 |> String.split(".") |> List.last()))
      |> String.slice(0, 40)
      |> String.trim_trailing("-")

    base <> "-" <> Base.encode16(:crypto.strong_rand_bytes(2), case: :lower)
  end

  ## apply helpers

  defp connector_name(%{name: name, provider: provider}) when is_binary(name),
    do: "#{provider} #{name}"

  defp connector_name(%{provider: provider}), do: provider

  defp same_labels?(have, want), do: Enum.sort(have || []) == Enum.sort(want)

  defp env_values(state, names) do
    for {key, %{value: v, profile: p}} <- state.plan.env, p in names, into: %{} do
      value =
        case v do
          {:secret, _} -> Map.fetch!(state.secrets, key)
          {:connector, _} -> Map.fetch!(state.connector_env, key)
          text -> text
        end

      {key, value}
    end
  end

  @doc false
  def file_entries(%Profile{} = p) do
    files = Enum.map(p.files, &%{source: &1.source, dest: &1.path, executable: &1.executable})

    skills =
      for s <- p.skills, rel <- s.files do
        %{
          source: Path.join(s.source, rel),
          dest: Path.join([".claude/skills", Merge.skill_folder(p, s), rel]),
          executable: false
        }
      end

    files ++ skills
  end

  defp tarball(entries) do
    path =
      Path.join(System.tmp_dir!(), "sprite-profiles-#{System.unique_integer([:positive])}.tar")

    try do
      list = Enum.map(entries, &{String.to_charlist(&1.dest), String.to_charlist(&1.source)})

      case :erl_tar.create(String.to_charlist(path), list, []) do
        :ok -> {:ok, File.read!(path)}
        {:error, reason} -> {:error, "could not pack the profile's files: #{inspect(reason)}"}
      end
    after
      File.rm(path)
    end
  end

  defp untar_script(remote, entries) do
    {exec, plain} = Enum.split_with(entries, & &1.executable)

    chmod = fn
      [], _ -> ""
      list, mode -> "chmod #{mode} " <> Enum.map_join(list, " ", &sh_quote(&1.dest)) <> "\n"
    end

    "set -e\ncd \"$HOME\"\ntar --no-same-owner -xf #{remote}\nrm -f #{remote}\n" <>
      chmod.(plain, "0644") <> chmod.(exec, "0755")
  end

  defp decode_settings(text) do
    case String.trim(text) do
      "" ->
        {:ok, %{}}

      json ->
        case Jason.decode(json) do
          {:ok, %{} = map} -> {:ok, map}
          _ -> {:error, "~/.claude/settings.json on the Sprite is not a JSON object"}
        end
    end
  end

  defp expand(nil, _home), do: nil
  defp expand("~", home), do: home
  defp expand("~/" <> rest, home), do: Path.join(home, rest)
  defp expand(dir, _home), do: dir

  defp write(state, rel, content, mode),
    do: Sprites.write_file(state.sprites, state.name, Path.join(state.home, rel), content, mode)

  defp sh(state, script, opts \\ []) do
    case Sprites.exec(state.sprites, state.name, ["bash", "-c", script], opts) do
      {:ok, %{status: 0, output: out}} -> {:ok, out}
      {:ok, %{status: code, output: out}} -> {:error, "exited #{code}: #{tail(out)}"}
      {:error, message} -> {:error, message}
    end
  end

  @doc false
  def sh_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  defp tail(out),
    do: out |> String.trim() |> String.split("\n") |> Enum.take(-15) |> Enum.join("\n")

  defp last_line(out), do: out |> String.trim() |> String.split("\n") |> List.last() || ""

  @doc false
  def runner_script do
    ~S"""
    #!/usr/bin/env bash
    # Written by sprite-profiles: runs one profile's setup.sh under a Sprites Task hold.
    # A Sprite pauses about 30 s after output stops, even mid-job, unless a Task holds it.
    # usage: run-setup.sh PROFILE TIMEOUT_SECONDS SET
    set -u
    profile="$1"; timeout_s="$2"; set_name="$3"
    # Task names take only a-z, 0-9 and '-', so a qualified name's '.' becomes '--', and
    # anything else outside them (a '_' in another host's namespace) becomes '-'.
    task="${profile//./--}"; task="profiled-setup-${task//[^a-z0-9-]/-}"
    [ -f "$HOME/.config/profiled/env.sh" ] && . "$HOME/.config/profiled/env.sh"
    export PROFILED_PROFILE="$profile" PROFILED_SET="$set_name"

    # PUT creates the Task or extends it.
    hold() {
      sprite-env curl -s -X PUT "/v1/tasks/$task" \
        -H 'Content-Type: application/json' -d '{"expire":"3m"}'
    }
    held="$(hold 2>&1)"
    echo "[profiled] Task hold: $held"
    ( while sleep 60; do hold >/dev/null 2>&1; done ) >/dev/null 2>&1 &
    beat=$!

    cd "$HOME"
    timeout "$timeout_s" bash "$HOME/.config/profiled/setup/$profile.sh" </dev/null
    rc=$?

    pkill -P "$beat" 2>/dev/null; kill "$beat" 2>/dev/null; wait "$beat" 2>/dev/null
    sprite-env curl -s -X DELETE "/v1/tasks/$task" >/dev/null 2>&1
    [ "$rc" = 124 ] && echo "[profiled] setup.sh for $profile ran past its timeout of ${timeout_s}s" >&2
    exit "$rc"
    """
  end

  ## finishing

  defp maybe_destroy(%{created: true} = state, opts) do
    if opts[:destroy_on_failure] do
      t0 = System.monotonic_time(:millisecond)

      case Sprites.destroy(state.sprites, state.name) do
        :ok -> record_step(state, :destroy, nil, t0, :ok, "destroyed after the failure")
        {:error, m} -> record_step(state, :destroy, nil, t0, :failed, m)
      end
    else
      state
    end
  end

  defp maybe_destroy(state, _opts), do: state

  defp finish(state, outcome, error, opts) do
    record = %{
      name: state.name,
      set: state.plan.set,
      profiles: state.plan.profiles,
      sources:
        Enum.map(
          state.plan.sources,
          &Map.take(&1, [:pick, :host, :owner, :repo, :path, :ref, :sha, :version])
        ),
      before_checkpoint: state.plan.before_checkpoint,
      after_checkpoint: state.plan.after_checkpoint,
      privileged: state.plan.privileged,
      labels: state.plan.labels,
      labels_via: state.labels_via,
      url: state.info && state.info.url,
      policy: Plan.policy_json(state.plan),
      connectors: Enum.map(state.plan.connectors, &connector_name/1),
      env_keys: state.plan.env |> Map.keys() |> Enum.sort(),
      inputs: Map.new(state.plan.inputs, &{&1.name, &1.value}),
      checkpoint: state.checkpoint,
      outcome: outcome,
      error: error,
      steps: state.steps,
      total_ms: Enum.sum(Enum.map(state.steps, & &1.ms)),
      started_at: DateTime.to_iso8601(state.started_at),
      finished_at: DateTime.to_iso8601(DateTime.utc_now())
    }

    path = write_record(record, Keyword.get(opts, :state_dir, @state_dir))
    Map.put(record, :record_path, path)
  end

  defp write_record(record, dir) do
    dir = Path.expand(dir)
    File.mkdir_p!(dir)
    stamp = record.started_at |> String.replace(~r/[^0-9TZ]/, "")
    path = Path.join(dir, "#{record.name}-#{stamp}.json")
    File.write!(path, Jason.encode!(record, pretty: true) <> "\n")
    path
  end
end
