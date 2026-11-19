defmodule SpriteProfiles.Profile do
  @moduledoc """
  One profile: a folder holding `profile.toml`, and optionally `setup.sh`, `files/` and
  `claude/skills/`, read into a struct.

  `load/1` reads a folder from disk. `parse/2` is the pure part: it takes the decoded
  `profile.toml` map (plus what was found on disk) and returns the struct or a list of
  `SpriteProfiles.Profile.Error`s. The format is described in `docs/SPEC.md`.
  """

  alias SpriteProfiles.Profile.Error

  @name_re ~r/^[a-z][a-z0-9-]{1,30}$/
  @env_key_re ~r/^[A-Z_][A-Z0-9_]*$/
  @provider_re ~r/^[a-z][a-z0-9_]{0,40}$/
  # Fly accepts labels of up to 128 bytes (measured; see docs/RESULTS.md).
  @label_re ~r/^[a-z0-9][a-z0-9_.:-]{0,127}$/
  @service_re ~r/^[a-z][a-z0-9-]{0,30}$/
  @mcp_name_re ~r/^[A-Za-z0-9_-]{1,64}$/
  @skill_re ~r/^[a-z0-9][a-z0-9-]{0,62}$/
  @domain_re ~r/^(\*\.)?[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/
  @duration_re ~r/^([1-9][0-9]*)(s|m|h)$/
  @env_ref_re ~r/\$\{([A-Za-z_][A-Za-z0-9_]*)(:-[^}]*)?\}/

  @max_summary 80
  @max_timeout 3600
  @default_timeout 600

  # The newest profile format this reader knows.
  @format 1

  # Exported by the launcher to every setup.sh; a profile may not define them.
  @reserved_env ~w(PROFILED_PROFILE PROFILED_SET)

  @top_fields ~w(format name summary description privileged checkpoint timeout labels env policy connectors services claude)

  @type env_value :: String.t() | {:connector, String.t()} | {:secret, String.t()}
  @type policy_rule :: :defaults | {:allow, String.t()} | {:deny, String.t()}

  @type service :: %{
          name: String.t(),
          cmd: String.t(),
          args: [String.t()],
          http_port: pos_integer() | nil,
          dir: String.t() | nil
        }

  @type mcp_server :: %{
          name: String.t(),
          type: String.t(),
          config: map(),
          auth_none: boolean(),
          has_authorization: boolean(),
          requires_env: [String.t()]
        }

  @type file_entry :: %{source: String.t() | nil, path: String.t(), executable: boolean()}
  @type skill :: %{name: String.t(), source: String.t() | nil, files: [String.t()]}

  @type t :: %__MODULE__{
          name: String.t(),
          summary: String.t(),
          description: String.t(),
          privileged: boolean(),
          checkpoint: boolean(),
          timeout: pos_integer(),
          labels: [String.t()],
          env: %{optional(String.t()) => env_value()},
          policy: [policy_rule()] | nil,
          connectors: [String.t()],
          services: [service()],
          claude_settings: map(),
          mcp_servers: [mcp_server()],
          setup: String.t() | nil,
          files: [file_entry()],
          skills: [skill()],
          path: String.t() | nil,
          format: pos_integer(),
          qualified: String.t(),
          pick: String.t(),
          source: source() | nil
        }

  @typedoc "Where a fetched profile came from; nil for a local one."
  @type source :: %{
          owner: String.t(),
          repo: String.t(),
          path: String.t(),
          ref: String.t(),
          sha: String.t()
        }

  @enforce_keys [:name, :summary]
  defstruct [
    :name,
    :summary,
    :setup,
    :path,
    :qualified,
    :pick,
    :source,
    format: @format,
    description: "",
    privileged: false,
    checkpoint: true,
    timeout: @default_timeout,
    labels: [],
    env: %{},
    policy: nil,
    connectors: [],
    services: [],
    claude_settings: %{},
    mcp_servers: [],
    files: [],
    skills: []
  ]

  @doc "The newest profile format this reader knows."
  def format, do: @format

  @doc "The pattern every profile name must match."
  def name_regex, do: @name_re

  @doc "True when `name` is a valid profile name."
  def valid_name?(name) when is_binary(name), do: Regex.match?(@name_re, name)
  def valid_name?(_), do: false

  ## Loading from disk

  @doc """
  Reads the profile folder at `dir`. The folder's base name is the profile's name.

  Options: `:name`, the name the profile must declare instead (nil allows any name, as at
  a repository root); `:display`, how sentences name the profile (default the name).
  """
  @spec load(Path.t(), keyword()) :: {:ok, t()} | {:error, [Error.t()]}
  def load(dir, opts \\ []) do
    expected =
      case Keyword.fetch(opts, :name) do
        {:ok, name} -> name
        :error -> Path.basename(dir)
      end

    folder = opts[:display] || expected || Path.basename(dir)
    toml_path = Path.join(dir, "profile.toml")

    with {:ok, text} <- read_toml(toml_path, folder),
         {:ok, map} <- decode_toml(text, folder),
         {:ok, found, disk_errors} <- scan_disk(dir, folder) do
      case parse(map, Keyword.merge(found, folder: expected, display: folder, path: dir)) do
        {:ok, profile} when disk_errors == [] -> {:ok, profile}
        {:ok, _profile} -> {:error, disk_errors}
        {:error, errors} -> {:error, errors ++ disk_errors}
      end
    end
  end

  @doc """
  Reads every profile folder under `root` (folders without a `profile.toml` are skipped).
  Returns `{profiles, errors}`, both sorted by name.
  """
  @spec load_all(Path.t()) :: {[t()], [Error.t()]}
  def load_all(root) do
    root
    |> File.ls!()
    |> Enum.sort()
    |> Enum.map(&Path.join(root, &1))
    |> Enum.filter(&File.regular?(Path.join(&1, "profile.toml")))
    |> Enum.reduce({[], []}, fn dir, {oks, errs} ->
      case load(dir) do
        {:ok, p} -> {[p | oks], errs}
        {:error, e} -> {oks, errs ++ e}
      end
    end)
    |> then(fn {oks, errs} -> {Enum.reverse(oks), errs} end)
  end

  defp read_toml(path, folder) do
    case File.read(path) do
      {:ok, text} ->
        {:ok, text}

      {:error, _} ->
        {:error,
         [
           Error.new(
             :missing_profile_toml,
             folder,
             "profile '#{folder}' has no profile.toml at #{path}; every profile folder needs one."
           )
         ]}
    end
  end

  defp decode_toml(text, folder) do
    # TOML 1.0, so profile files stay readable by any TOML parser, not only this one.
    case TomlElixir.decode(text, spec: :"1.0.0") do
      {:ok, map} ->
        {:ok, map}

      {:error, e} ->
        {:error,
         [
           Error.new(
             :bad_toml,
             folder,
             "profile '#{folder}' has a profile.toml that is not valid TOML 1.0: #{Exception.message(e)}"
           )
         ]}
    end
  end

  defp scan_disk(dir, folder) do
    setup = Path.join(dir, "setup.sh")
    setup = if File.regular?(setup), do: setup

    {files, file_errors} = scan_tree(Path.join(dir, "files"), folder)
    {skills, skill_errors} = scan_skills(Path.join(dir, "claude"), folder)

    {:ok, [setup: setup, files: files, skills: skills], file_errors ++ skill_errors}
  end

  # Regular files only, relative paths, sorted; symlinks and other oddities are refused.
  defp scan_tree(root, folder) do
    if File.dir?(root) do
      walk(root, "", folder)
    else
      {[], []}
    end
  end

  defp walk(root, rel, folder) do
    here = Path.join(root, rel)

    here
    |> File.ls!()
    |> Enum.sort()
    |> Enum.reduce({[], []}, fn entry, {files, errs} ->
      rel_entry = if rel == "", do: entry, else: Path.join(rel, entry)
      full = Path.join(root, rel_entry)

      case File.lstat(full) do
        {:ok, %File.Stat{type: :directory}} ->
          {f, e} = walk(root, rel_entry, folder)
          {files ++ f, errs ++ e}

        {:ok, %File.Stat{type: :regular, mode: mode}} ->
          entry = %{source: full, path: rel_entry, executable: Bitwise.band(mode, 0o111) != 0}
          {files ++ [entry], errs}

        _ ->
          {files,
           errs ++
             [
               Error.new(
                 :bad_file,
                 folder,
                 "profile '#{folder}' holds #{full}, which is not a regular file; profiles push regular files only, so replace it with a copy."
               )
             ]}
      end
    end)
  end

  defp scan_skills(claude_dir, folder) do
    if File.dir?(claude_dir) do
      extra =
        claude_dir
        |> File.ls!()
        |> Enum.reject(&(&1 == "skills"))
        |> Enum.sort()
        |> Enum.map(fn entry ->
          Error.new(
            :unknown_entry,
            folder,
            "profile '#{folder}' has claude/#{entry}; only claude/skills/ is read, so move or remove it."
          )
        end)

      skills_dir = Path.join(claude_dir, "skills")

      {skills, errs} =
        if File.dir?(skills_dir) do
          skills_dir
          |> File.ls!()
          |> Enum.sort()
          |> Enum.reduce({[], []}, fn skill, {acc, errs} ->
            scan_skill(Path.join(skills_dir, skill), skill, folder, acc, errs)
          end)
        else
          {[], []}
        end

      {Enum.reverse(skills), extra ++ errs}
    else
      {[], []}
    end
  end

  defp scan_skill(dir, skill, folder, acc, errs) do
    cond do
      not File.dir?(dir) ->
        {acc,
         errs ++
           [
             Error.new(
               :bad_skill,
               folder,
               "profile '#{folder}' has claude/skills/#{skill}, which is not a folder; each skill is a folder holding a SKILL.md."
             )
           ]}

      not Regex.match?(@skill_re, skill) ->
        {acc,
         errs ++
           [
             Error.new(
               :bad_skill,
               folder,
               "profile '#{folder}' has a skill named '#{skill}'; skill names are lowercase letters, digits and '-'."
             )
           ]}

      not File.regular?(Path.join(dir, "SKILL.md")) ->
        {acc,
         errs ++
           [
             Error.new(
               :bad_skill,
               folder,
               "profile '#{folder}' has skill '#{skill}' with no SKILL.md; add one."
             )
           ]}

      true ->
        {files, file_errs} = walk(dir, "", folder)

        {[%{name: skill, source: dir, files: Enum.map(files, & &1.path)} | acc],
         errs ++ file_errs}
    end
  end

  ## Parsing (pure)

  @doc """
  Builds a profile from a decoded `profile.toml` map.

  Options: `:folder` (the folder name the `name` field must match; defaults to the
  `name` field), `:display` (how sentences name the profile; defaults to the folder),
  `:path`, `:setup` (path of setup.sh or nil), `:files` and `:skills` (as found on disk).

  `format` is read first: a format newer than this reader's is refused alone
  (`unsupported_format`), so a future field is one refusal rather than many.
  """
  @spec parse(map(), keyword()) :: {:ok, t()} | {:error, [Error.t()]}
  def parse(map, opts \\ []) when is_map(map) do
    raw_name = Map.get(map, "name")
    folder = Keyword.get(opts, :folder) || (is_binary(raw_name) && raw_name) || "?"
    ctx = %{p: opts[:display] || folder}

    case Map.get(map, "format", @format) do
      f when is_integer(f) and f > @format ->
        {:error,
         err(
           ctx,
           :unsupported_format,
           "is format #{f}; this launcher reads up to format #{@format}, so upgrade sprite-profiles."
         )}

      f when is_integer(f) and f >= 1 ->
        parse_fields(map, f, folder, ctx, opts)

      f ->
        e_format =
          err(ctx, :bad_field, "has format #{inspect(f)}; format is a whole number, 1 or more.")

        case parse_fields(map, @format, folder, ctx, opts) do
          {:ok, _} -> {:error, e_format}
          {:error, errors} -> {:error, e_format ++ errors}
        end
    end
  end

  defp parse_fields(map, format, folder, ctx, opts) do
    {name, e_name} = parse_name(Map.get(map, "name"), folder, ctx)
    e_unknown = unknown_keys(map, @top_fields, "", ctx)
    {summary, e_summary} = parse_summary(Map.get(map, "summary"), ctx)
    {description, e_desc} = string_field(map, "description", "", ctx)
    {privileged, e_priv} = bool_field(map, "privileged", false, ctx)
    {checkpoint, e_cp} = parse_checkpoint(map, privileged, ctx)
    {timeout, e_timeout} = parse_timeout(Map.get(map, "timeout"), ctx)
    {labels, e_labels} = parse_labels(Map.get(map, "labels"), ctx)
    {connectors, e_conn} = parse_connectors(Map.get(map, "connectors"), ctx)
    {env, e_env} = parse_env(Map.get(map, "env"), privileged, connectors, ctx)
    {policy, e_policy} = parse_policy(Map.get(map, "policy"), ctx)
    {services, e_services} = parse_services(Map.get(map, "services"), ctx)
    {settings, mcp, e_claude} = parse_claude(Map.get(map, "claude"), ctx)

    errors =
      e_name ++
        e_unknown ++
        e_summary ++
        e_desc ++
        e_priv ++
        e_cp ++
        e_timeout ++
        e_labels ++ e_conn ++ e_env ++ e_policy ++ e_services ++ e_claude

    if errors == [] do
      {:ok,
       %__MODULE__{
         format: format,
         name: name,
         qualified: name,
         pick: name,
         summary: summary,
         description: description,
         privileged: privileged,
         checkpoint: checkpoint,
         timeout: timeout,
         labels: labels,
         env: env,
         policy: policy,
         connectors: connectors,
         services: services,
         claude_settings: settings,
         mcp_servers: mcp,
         setup: Keyword.get(opts, :setup),
         files: Keyword.get(opts, :files, []),
         skills: Keyword.get(opts, :skills, []),
         path: Keyword.get(opts, :path)
       }}
    else
      {:error, errors}
    end
  end

  defp err(ctx, code, msg), do: [Error.new(code, ctx.p, "profile '#{ctx.p}' #{msg}")]

  defp parse_name(nil, _folder, ctx),
    do: {nil, err(ctx, :missing_field, "has no name; set name to the folder's name.")}

  defp parse_name(name, folder, ctx) when is_binary(name) do
    cond do
      not valid_name?(name) ->
        {nil,
         err(
           ctx,
           :bad_name,
           "has name '#{name}'; names are 2-31 characters of a-z, 0-9 and '-', starting with a letter."
         )}

      name != folder ->
        {nil,
         err(
           ctx,
           :name_mismatch,
           "has name '#{name}' in a folder named '#{folder}'; make them the same."
         )}

      true ->
        {name, []}
    end
  end

  defp parse_name(_, _folder, ctx),
    do: {nil, err(ctx, :bad_field, "has a name that is not a string.")}

  defp unknown_keys(map, allowed, prefix, ctx) do
    map
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed))
    |> Enum.sort()
    |> Enum.flat_map(fn key ->
      err(
        ctx,
        :unknown_field,
        "has an unknown field `#{prefix}#{key}`; the format has no such field (see docs/SPEC.md)."
      )
    end)
  end

  defp parse_summary(nil, ctx),
    do: {nil, err(ctx, :missing_field, "has no summary; add a one-line summary.")}

  defp parse_summary(s, ctx) when is_binary(s) do
    length = String.length(s)

    cond do
      String.contains?(s, ["\n", "\r"]) ->
        {nil, err(ctx, :bad_field, "has a summary of more than one line; keep it to one.")}

      String.trim(s) == "" ->
        {nil,
         err(ctx, :bad_field, "has an empty summary; say in one line what it gives a Sprite.")}

      length > @max_summary ->
        {nil,
         err(
           ctx,
           :bad_field,
           "has a summary of #{length} characters; keep it to #{@max_summary}."
         )}

      true ->
        {s, []}
    end
  end

  defp parse_summary(_, ctx),
    do: {nil, err(ctx, :bad_field, "has a summary that is not a string.")}

  defp string_field(map, key, default, ctx) do
    case Map.get(map, key, default) do
      v when is_binary(v) -> {v, []}
      _ -> {default, err(ctx, :bad_field, "has a #{key} that is not a string.")}
    end
  end

  defp bool_field(map, key, default, ctx) do
    case Map.get(map, key, default) do
      v when is_boolean(v) -> {v, []}
      _ -> {default, err(ctx, :bad_field, "has a #{key} that is not true or false.")}
    end
  end

  defp parse_checkpoint(map, privileged, ctx) do
    {value, errors} = bool_field(map, "checkpoint", not privileged, ctx)

    if privileged and value do
      {false,
       errors ++
         err(
           ctx,
           :privileged_checkpoint,
           "is privileged and sets checkpoint = true; privileged profiles are applied after the checkpoint so credentials are never saved in one, so remove the line."
         )}
    else
      {value, errors}
    end
  end

  defp parse_timeout(nil, _ctx), do: {@default_timeout, []}

  defp parse_timeout(t, ctx) when is_binary(t) do
    case Regex.run(@duration_re, t) do
      [_, n, unit] ->
        seconds = String.to_integer(n) * %{"s" => 1, "m" => 60, "h" => 3600}[unit]

        if seconds <= @max_timeout do
          {seconds, []}
        else
          {@default_timeout,
           err(ctx, :bad_field, "has timeout \"#{t}\"; the most a setup may take is 1h.")}
        end

      nil ->
        {@default_timeout,
         err(
           ctx,
           :bad_field,
           "has timeout \"#{t}\"; write a whole number with s, m or h, like \"15m\"."
         )}
    end
  end

  defp parse_timeout(_, ctx),
    do:
      {@default_timeout, err(ctx, :bad_field, "has a timeout that is not a string like \"15m\".")}

  defp parse_labels(nil, _ctx), do: {[], []}

  defp parse_labels(list, ctx) when is_list(list) do
    Enum.reduce(list, {[], []}, fn label, {acc, errs} ->
      cond do
        not is_binary(label) or not Regex.match?(@label_re, label) ->
          {acc,
           errs ++
             err(
               ctx,
               :bad_field,
               "has label #{inspect(label)}; labels are lowercase letters, digits and . _ : -."
             )}

        String.starts_with?(label, "profile:") ->
          {acc,
           errs ++
             err(
               ctx,
               :reserved_label,
               "declares label '#{label}'; profile: labels are given only by picking that profile, since connectors are granted by them."
             )}

        true ->
          {acc ++ [label], errs}
      end
    end)
    |> then(fn {acc, errs} -> {Enum.uniq(acc), errs} end)
  end

  defp parse_labels(_, ctx), do: {[], err(ctx, :bad_field, "has labels that are not a list.")}

  defp parse_connectors(nil, _ctx), do: {[], []}

  defp parse_connectors(list, ctx) when is_list(list) do
    Enum.reduce(list, {[], []}, fn
      %{"provider" => provider} = c, {acc, errs} when is_binary(provider) ->
        extra = unknown_keys(c, ["provider"], "connectors.", ctx)

        if Regex.match?(@provider_re, provider) do
          {acc ++ [provider], errs ++ extra}
        else
          {acc,
           errs ++
             extra ++
             err(
               ctx,
               :bad_field,
               "has connector provider '#{provider}', which is not a provider name."
             )}
        end

      _, {acc, errs} ->
        {acc,
         errs ++ err(ctx, :bad_field, "has a [[connectors]] entry without a provider string.")}
    end)
    |> then(fn {acc, errs} -> {Enum.uniq(acc), errs} end)
  end

  defp parse_connectors(_, ctx),
    do: {[], err(ctx, :bad_field, "has connectors that are not a [[connectors]] array.")}

  defp parse_env(nil, _privileged, _connectors, _ctx), do: {%{}, []}

  defp parse_env(map, privileged, connectors, ctx) when is_map(map) do
    map
    |> Enum.sort()
    |> Enum.reduce({%{}, []}, fn {key, value}, {acc, errs} ->
      cond do
        not Regex.match?(@env_key_re, key) ->
          {acc,
           errs ++
             err(
               ctx,
               :bad_field,
               "has env key '#{key}'; env keys are uppercase letters, digits and '_'."
             )}

        key in @reserved_env ->
          {acc,
           errs ++
             err(
               ctx,
               :reserved_env,
               "defines env #{key}, which the launcher sets for every setup.sh; remove it."
             )}

        true ->
          case env_value(key, value, privileged, connectors, ctx) do
            {:ok, v} -> {Map.put(acc, key, v), errs}
            {:error, e} -> {acc, errs ++ e}
          end
      end
    end)
  end

  defp parse_env(_, _privileged, _connectors, ctx),
    do: {%{}, err(ctx, :bad_field, "has an env that is not a table.")}

  defp env_value(_key, v, _priv, _conns, _ctx) when is_binary(v), do: {:ok, v}

  defp env_value(key, %{"secret" => name} = v, privileged, _conns, ctx) when map_size(v) == 1 do
    cond do
      not privileged ->
        {:error,
         err(
           ctx,
           :secret_needs_privileged,
           "reads secret #{inspect(name)} into env #{key} but is not privileged; a secret may only come from a privileged profile, which agents cannot launch and checkpoints never hold, so set privileged = true or remove it."
         )}

      not (is_binary(name) and Regex.match?(@env_key_re, name)) ->
        {:error,
         err(
           ctx,
           :bad_field,
           "names secret #{inspect(name)} for env #{key}; secret names are uppercase letters, digits and '_'."
         )}

      true ->
        {:ok, {:secret, name}}
    end
  end

  defp env_value(key, %{"from" => "connector", "provider" => provider} = v, _priv, conns, ctx)
       when map_size(v) == 2 do
    if provider in conns do
      {:ok, {:connector, provider}}
    else
      {:error,
       err(
         ctx,
         :env_connector_undeclared,
         "resolves env #{key} from connector #{inspect(provider)} without declaring it; add [[connectors]] provider = #{inspect(provider)}."
       )}
    end
  end

  defp env_value(key, _v, _priv, _conns, ctx) do
    {:error,
     err(
       ctx,
       :bad_field,
       "has env #{key} that is neither a string, { secret = \"NAME\" } nor { from = \"connector\", provider = \"...\" }."
     )}
  end

  defp parse_policy(nil, _ctx), do: {nil, []}

  defp parse_policy(%{} = policy, ctx) do
    extra = unknown_keys(policy, ["rules"], "policy.", ctx)

    case Map.get(policy, "rules", []) do
      rules when is_list(rules) ->
        {parsed, errs} =
          Enum.reduce(rules, {[], []}, fn rule, {acc, errs} ->
            case policy_rule(rule, ctx) do
              {:ok, r} -> {acc ++ [r], errs}
              {:error, e} -> {acc, errs ++ e}
            end
          end)

        {Enum.uniq(parsed), extra ++ errs}

      _ ->
        {nil, extra ++ err(ctx, :bad_field, "has policy.rules that is not a list.")}
    end
  end

  defp parse_policy(_, ctx), do: {nil, err(ctx, :bad_field, "has a policy that is not a table.")}

  defp policy_rule(%{"include" => "defaults"} = r, _ctx) when map_size(r) == 1,
    do: {:ok, :defaults}

  defp policy_rule(%{"action" => action, "domain" => domain} = r, ctx)
       when map_size(r) == 2 and action in ["allow", "deny"] and is_binary(domain) do
    if Regex.match?(@domain_re, domain) do
      {:ok, {String.to_existing_atom(action), domain}}
    else
      {:error, err(ctx, :bad_field, "has policy domain '#{domain}', which is not a domain name.")}
    end
  end

  defp policy_rule(rule, ctx) do
    {:error,
     err(
       ctx,
       :bad_field,
       "has policy rule #{inspect(rule)}; a rule is { include = \"defaults\" } or { action = \"allow\" | \"deny\", domain = \"...\" }."
     )}
  end

  @service_fields ~w(name cmd args http_port dir)

  defp parse_services(nil, _ctx), do: {[], []}

  defp parse_services(list, ctx) when is_list(list) do
    {services, errs} =
      Enum.reduce(list, {[], []}, fn s, {acc, errs} ->
        case service(s, ctx) do
          {:ok, svc} -> {acc ++ [svc], errs}
          {:error, e} -> {acc, errs ++ e}
        end
      end)

    dup_errs =
      services
      |> Enum.frequencies_by(& &1.name)
      |> Enum.filter(fn {_, n} -> n > 1 end)
      |> Enum.flat_map(fn {name, _} ->
        err(ctx, :duplicate_service, "defines service '#{name}' twice; give each a unique name.")
      end)

    port_errs =
      case Enum.filter(services, & &1.http_port) do
        [a, b | _] ->
          err(
            ctx,
            :http_port_conflict,
            "gives services '#{a.name}' and '#{b.name}' an http_port; a Sprite routes HTTP to one service, so keep one."
          )

        _ ->
          []
      end

    {services, errs ++ dup_errs ++ port_errs}
  end

  defp parse_services(_, ctx),
    do: {[], err(ctx, :bad_field, "has services that are not a [[services]] array.")}

  defp service(%{} = s, ctx) do
    extra = unknown_keys(s, @service_fields, "services.", ctx)
    name = s["name"]
    args = Map.get(s, "args", [])
    port = s["http_port"]
    dir = s["dir"]

    errs =
      extra ++
        if(is_binary(name) and Regex.match?(@service_re, name),
          do: [],
          else:
            err(
              ctx,
              :bad_field,
              "has service name #{inspect(name)}; service names are lowercase letters, digits and '-'."
            )
        ) ++
        if(is_binary(s["cmd"]) and s["cmd"] != "",
          do: [],
          else: err(ctx, :bad_field, "has service #{inspect(name)} without a cmd.")
        ) ++
        if(is_list(args) and Enum.all?(args, &is_binary/1),
          do: [],
          else: err(ctx, :bad_field, "has service #{inspect(name)} whose args are not strings.")
        ) ++
        if(is_nil(port) or (is_integer(port) and port in 1..65_535),
          do: [],
          else:
            err(ctx, :bad_field, "has service #{inspect(name)} with http_port #{inspect(port)}.")
        ) ++
        if(is_nil(dir) or is_binary(dir),
          do: [],
          else: err(ctx, :bad_field, "has service #{inspect(name)} whose dir is not a string.")
        )

    if errs == [] do
      {:ok, %{name: name, cmd: s["cmd"], args: args, http_port: port, dir: dir}}
    else
      {:error, errs}
    end
  end

  defp service(_, ctx),
    do: {:error, err(ctx, :bad_field, "has a [[services]] entry that is not a table.")}

  defp parse_claude(nil, _ctx), do: {%{}, [], []}

  defp parse_claude(%{} = claude, ctx) do
    extra = unknown_keys(claude, ["settings", "mcp_servers"], "claude.", ctx)

    {settings, e_settings} =
      case Map.get(claude, "settings", %{}) do
        %{} = s -> {s, []}
        _ -> {%{}, err(ctx, :bad_field, "has claude.settings that is not a table.")}
      end

    {servers, e_servers} =
      case Map.get(claude, "mcp_servers", %{}) do
        %{} = m ->
          m
          |> Enum.sort()
          |> Enum.reduce({[], []}, fn {name, cfg}, {acc, errs} ->
            case mcp_server(name, cfg, ctx) do
              {:ok, s} -> {acc ++ [s], errs}
              {:error, e} -> {acc, errs ++ e}
            end
          end)

        _ ->
          {[], err(ctx, :bad_field, "has claude.mcp_servers that is not a table.")}
      end

    {settings, servers, extra ++ e_settings ++ e_servers}
  end

  defp parse_claude(_, ctx),
    do: {%{}, [], err(ctx, :bad_field, "has a claude that is not a table.")}

  @mcp_fields ~w(type url headers command args env auth requires_env)

  defp mcp_server(name, %{} = cfg, ctx) do
    extra = unknown_keys(cfg, @mcp_fields, "claude.mcp_servers.#{name}.", ctx)
    type = Map.get(cfg, "type", if(Map.has_key?(cfg, "command"), do: "stdio", else: "http"))
    headers = Map.get(cfg, "headers", %{})
    env = Map.get(cfg, "env", %{})
    args = Map.get(cfg, "args", [])
    requires = Map.get(cfg, "requires_env", [])
    auth = Map.get(cfg, "auth")

    errs =
      extra ++
        check(Regex.match?(@mcp_name_re, name), ctx, "has MCP server name '#{name}'.") ++
        check(
          type in ["http", "sse", "stdio"],
          ctx,
          "has MCP server '#{name}' of type #{inspect(type)}; use http, sse or stdio."
        ) ++
        check(
          type == "stdio" or is_binary(cfg["url"]),
          ctx,
          "has #{type} MCP server '#{name}' without a url."
        ) ++
        check(
          type != "stdio" or is_binary(cfg["command"]),
          ctx,
          "has stdio MCP server '#{name}' without a command."
        ) ++
        check(
          string_map?(headers),
          ctx,
          "has MCP server '#{name}' whose headers are not strings."
        ) ++
        check(string_map?(env), ctx, "has MCP server '#{name}' whose env values are not strings.") ++
        check(string_list?(args), ctx, "has MCP server '#{name}' whose args are not strings.") ++
        check(
          string_list?(requires) and Enum.all?(requires, &Regex.match?(@env_key_re, &1)),
          ctx,
          "has MCP server '#{name}' whose requires_env is not a list of env names."
        ) ++
        check(
          is_nil(auth) or auth == "none",
          ctx,
          "has MCP server '#{name}' with auth #{inspect(auth)}; the only value is \"none\"."
        )

    if errs == [] do
      config = Map.drop(cfg, ["auth", "requires_env"]) |> Map.put("type", type)

      refs =
        [cfg["url"] | Map.values(headers) ++ Map.values(env) ++ args]
        |> Enum.filter(&is_binary/1)
        |> Enum.flat_map(fn s -> Regex.scan(@env_ref_re, s) end)
        |> Enum.reject(fn m -> length(m) > 2 end)
        |> Enum.map(fn [_, var | _] -> var end)

      {:ok,
       %{
         name: name,
         type: type,
         config: config,
         auth_none: auth == "none",
         has_authorization:
           Enum.any?(Map.keys(headers), &(String.downcase(&1) == "authorization")),
         requires_env: Enum.uniq(requires ++ refs)
       }}
    else
      {:error, errs}
    end
  end

  defp mcp_server(name, _cfg, ctx),
    do: {:error, err(ctx, :bad_field, "has MCP server '#{name}' that is not a table.")}

  defp check(true, _ctx, _msg), do: []
  defp check(false, ctx, msg), do: err(ctx, :bad_field, msg)

  defp string_map?(m), do: is_map(m) and Enum.all?(m, fn {_, v} -> is_binary(v) end)
  defp string_list?(l), do: is_list(l) and Enum.all?(l, &is_binary/1)
end
