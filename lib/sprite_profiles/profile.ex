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
  @input_name_re ~r/^[a-z][a-z0-9_]{0,30}$/
  @endpoint_re ~r/^\/[^\s*?#]*\*?$/
  @header_name_re ~r/^[A-Za-z0-9][A-Za-z0-9-]{0,63}$/
  @leading_ref_re ~r/^\$\{([A-Z_][A-Z0-9_]*)\}/

  @max_summary 80
  @max_input 256
  @max_timeout 3600
  @default_timeout 600

  # The newest profile format this reader knows. Format 2 adds inputs, custom API
  # connectors and MCP `auth = "connector"`.
  @format 2

  # Exported by the launcher to every setup.sh; a profile may not define them.
  @reserved_env ~w(PROFILED_PROFILE PROFILED_SET)

  @top_fields ~w(format name summary description privileged checkpoint timeout labels inputs env policy connectors services claude)

  @type env_value ::
          String.t() | {:connector, String.t()} | {:secret, String.t()} | {:input, String.t()}
  @type policy_rule :: :defaults | {:allow, String.t()} | {:deny, String.t()}

  @type service :: %{
          name: String.t(),
          cmd: String.t(),
          args: [String.t()],
          http_port: pos_integer() | nil,
          dir: String.t() | nil
        }

  @typedoc "An input: a value given at launch, never a secret. `default` nil means required."
  @type input :: %{
          name: String.t(),
          summary: String.t(),
          default: String.t() | nil,
          pattern: String.t() | nil
        }

  @typedoc """
  A connector the profile needs. A catalogue provider (`github`) has only `provider`; a
  custom API connector (`custom_api`) also has `base_url`, `auth`, `endpoints` and
  `test_url`. Its name in the org is the profile's qualified name.
  """
  @type connector :: %{
          provider: String.t(),
          base_url: String.t() | nil,
          auth: map() | nil,
          endpoints: [String.t()],
          test_url: String.t() | nil
        }

  @type mcp_server :: %{
          name: String.t(),
          type: String.t(),
          config: map(),
          auth_none: boolean(),
          auth_connector: boolean(),
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
          inputs: %{optional(String.t()) => input()},
          env: %{optional(String.t()) => env_value()},
          policy: [policy_rule()] | nil,
          connectors: [connector()],
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
    format: 1,
    description: "",
    privileged: false,
    checkpoint: true,
    timeout: @default_timeout,
    labels: [],
    inputs: %{},
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

    case Map.get(map, "format", 1) do
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

        case parse_fields(map, 1, folder, ctx, opts) do
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
    {inputs, e_inputs} = parse_inputs(Map.get(map, "inputs"), ctx)
    {connectors, e_conn} = parse_connectors(Map.get(map, "connectors"), ctx)
    # Env may name an input that failed its own checks; that is reported once, there.
    declared = if is_map(map["inputs"]), do: Map.keys(map["inputs"]), else: []
    env_ctx = %{privileged: privileged, connectors: connectors, inputs: declared}
    {env, e_env} = parse_env(Map.get(map, "env"), env_ctx, ctx)
    e_unused = unused_inputs(inputs, env, ctx)
    {policy, e_policy} = parse_policy(Map.get(map, "policy"), ctx)
    {services, e_services} = parse_services(Map.get(map, "services"), ctx)
    {settings, mcp, e_claude} = parse_claude(Map.get(map, "claude"), env, ctx)

    errors =
      needs_format(map, format, ctx) ++
        e_name ++
        e_unknown ++
        e_summary ++
        e_desc ++
        e_priv ++
        e_cp ++
        e_timeout ++
        e_labels ++
        e_inputs ++ e_conn ++ e_env ++ e_unused ++ e_policy ++ e_services ++ e_claude

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
         inputs: inputs,
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

  ## format 2: a profile that uses a format-2 field must say format = 2

  defp needs_format(_map, format, _ctx) when format >= 2, do: []

  defp needs_format(map, format, ctx) do
    map
    |> format2_fields()
    |> Enum.flat_map(fn field ->
      err(
        ctx,
        :needs_format,
        "uses #{field}, which is format 2, but is format #{format}; set format = 2."
      )
    end)
  end

  defp format2_fields(map) do
    env = if is_map(map["env"]), do: Map.values(map["env"]), else: []
    connectors = if is_list(map["connectors"]), do: map["connectors"], else: []

    servers =
      case map["claude"] do
        %{"mcp_servers" => %{} = m} -> Map.values(m)
        _ -> []
      end

    [
      {Map.has_key?(map, "inputs"), "[inputs]"},
      {Enum.any?(env, &match?(%{"from" => "input"}, &1)), ~s(env { from = "input" })},
      {Enum.any?(connectors, &match?(%{"provider" => "custom_api"}, &1)),
       ~s([[connectors]] provider = "custom_api")},
      {Enum.any?(servers, &match?(%{"auth" => "connector"}, &1)),
       ~s(an MCP server with auth = "connector")}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  ## inputs

  @input_fields ~w(summary default pattern)

  @doc "The longest input value, in characters."
  def max_input, do: @max_input

  defp parse_inputs(nil, _ctx), do: {%{}, []}

  defp parse_inputs(%{} = inputs, ctx) do
    inputs
    |> Enum.sort()
    |> Enum.reduce({%{}, []}, fn {name, spec}, {acc, errs} ->
      case input(name, spec, ctx) do
        {:ok, i} -> {Map.put(acc, name, i), errs}
        {:error, e} -> {acc, errs ++ e}
      end
    end)
  end

  defp parse_inputs(_, ctx),
    do: {%{}, err(ctx, :bad_field, "has inputs that are not a table of [inputs.<name>] tables.")}

  defp input(name, %{} = spec, ctx) do
    extra = unknown_keys(spec, @input_fields, "inputs.#{name}.", ctx)
    summary = spec["summary"]
    default = spec["default"]
    pattern = spec["pattern"]

    {regex, e_pattern} =
      case pattern do
        nil ->
          {nil, []}

        p when is_binary(p) ->
          case compile_pattern(p) do
            {:ok, re} ->
              {re, []}

            :error ->
              {nil,
               err(
                 ctx,
                 :bad_field,
                 "has input #{name} whose pattern #{inspect(p)} does not compile."
               )}
          end

        _ ->
          {nil, err(ctx, :bad_field, "has input #{name} whose pattern is not a string.")}
      end

    errs =
      extra ++
        check(
          Regex.match?(@input_name_re, name),
          ctx,
          "has input '#{name}'; input names are a-z, 0-9 and '_', starting with a letter, at most 31."
        ) ++
        check(
          is_binary(summary) and String.trim(summary) != "" and
            not String.contains?(summary, ["\n", "\r"]) and
            String.length(summary) <= @max_summary,
          ctx,
          "has input #{name} without a one-line summary of at most #{@max_summary} characters."
        ) ++
        e_pattern ++
        default_errors(name, default, regex && {regex, pattern}, ctx)

    if errs == [] do
      {:ok, %{name: name, summary: summary, default: default, pattern: pattern}}
    else
      {:error, errs}
    end
  end

  defp input(name, _spec, ctx),
    do: {:error, err(ctx, :bad_field, "has input #{inspect(name)} that is not a table.")}

  defp default_errors(_name, nil, _regex, _ctx), do: []

  defp default_errors(name, default, regex, ctx) when is_binary(default) do
    case input_value_problem(default, regex) do
      nil -> []
      why -> err(ctx, :bad_field, "has input #{name} whose default #{why}.")
    end
  end

  defp default_errors(name, _default, _regex, ctx),
    do:
      err(ctx, :bad_field, "has input #{name} whose default is not a string; values are strings.")

  # A pattern is matched against the whole value.
  defp compile_pattern(p) do
    case Regex.compile("\\A(?:" <> p <> ")\\z", "u") do
      {:ok, re} -> {:ok, re}
      {:error, _} -> :error
    end
  end

  @doc """
  Why `value` is not acceptable for `input`, as the end of a sentence, or nil when it is:
  a string of at most #{@max_input} characters on one line, matching the input's pattern.
  """
  @spec input_problem(input(), term()) :: String.t() | nil
  def input_problem(%{pattern: pattern}, value) do
    regex =
      case pattern && compile_pattern(pattern) do
        {:ok, re} -> re
        _ -> nil
      end

    input_value_problem(value, regex && {regex, pattern})
  end

  defp input_value_problem(value, regex) do
    cond do
      not is_binary(value) ->
        "is not a string"

      String.contains?(value, ["\n", "\r"]) ->
        "holds a newline; a value is one line"

      String.length(value) > @max_input ->
        "is #{String.length(value)} characters; a value is at most #{@max_input}"

      match?({_, _}, regex) and not Regex.match?(elem(regex, 0), value) ->
        "#{inspect(value)} does not match its pattern '#{elem(regex, 1)}'"

      true ->
        nil
    end
  end

  defp unused_inputs(inputs, env, ctx) do
    used = for {_key, {:input, name}} <- env, into: MapSet.new(), do: name

    inputs
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reject(&MapSet.member?(used, &1))
    |> Enum.flat_map(fn name ->
      err(
        ctx,
        :input_unused,
        "declares input #{name}, which no [env] entry uses; an input reaches the Sprite only through env, so add KEY = { from = \"input\", name = \"#{name}\" } or remove it."
      )
    end)
  end

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
    {connectors, errs} =
      Enum.reduce(list, {[], []}, fn
        %{"provider" => "custom_api"} = c, {acc, errs} ->
          case custom_connector(c, ctx) do
            {:ok, conn} -> {acc ++ [conn], errs}
            {:error, e} -> {acc, errs ++ e}
          end

        %{"provider" => provider} = c, {acc, errs} when is_binary(provider) ->
          extra = unknown_keys(c, ["provider"], "connectors.", ctx)

          if Regex.match?(@provider_re, provider) do
            {acc ++ [catalogue_connector(provider)], errs ++ extra}
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

    dup =
      if Enum.count(list, &match?(%{"provider" => "custom_api"}, &1)) > 1 do
        err(
          ctx,
          :duplicate_connector,
          "declares more than one custom_api connector; a profile has one, named by the profile, so split the APIs into profiles and pick them together."
        )
      else
        []
      end

    {Enum.uniq(connectors), errs ++ dup}
  end

  defp parse_connectors(_, ctx),
    do: {[], err(ctx, :bad_field, "has connectors that are not a [[connectors]] array.")}

  defp catalogue_connector(provider),
    do: %{provider: provider, base_url: nil, auth: nil, endpoints: [], test_url: nil}

  @custom_fields ~w(provider base_url auth endpoints test_url)

  # Fly's four auth methods, each with its companion field and that field's default.
  @auth_methods %{
    "header" => {"prefix", "Bearer"},
    "custom_header" => {"header", "X-Api-Key"},
    "query_param" => {"param", "api_key"},
    "url_path" => {"template", nil}
  }

  defp custom_connector(c, ctx) do
    extra = unknown_keys(c, @custom_fields, "connectors.", ctx)
    base_url = c["base_url"]
    endpoints = c["endpoints"]
    test_url = c["test_url"]
    {auth, e_auth} = parse_auth(Map.get(c, "auth", %{}), ctx)

    errs =
      extra ++
        check(
          https_url?(base_url),
          ctx,
          "has a custom_api connector whose base_url #{inspect(base_url)} is not an https URL without a query or fragment."
        ) ++
        e_auth ++
        check(
          is_list(endpoints) and endpoints != [] and
            Enum.all?(endpoints, &(is_binary(&1) and Regex.match?(@endpoint_re, &1))),
          ctx,
          "has a custom_api connector whose endpoints are not a non-empty list of paths like \"/exact\" or \"/prefix*\"."
        ) ++
        check(
          test_url_ok?(test_url, auth),
          ctx,
          "has a custom_api connector whose test_url #{inspect(test_url)} is not an https URL (or, for auth url_path, a path starting with '/')."
        )

    if errs == [] do
      {:ok,
       %{
         provider: "custom_api",
         base_url: base_url,
         auth: auth,
         endpoints: Enum.uniq(endpoints),
         test_url: test_url
       }}
    else
      {:error, errs}
    end
  end

  defp parse_auth(%{"method" => method} = auth, ctx) when is_map_key(@auth_methods, method) do
    {field, default} = Map.fetch!(@auth_methods, method)
    extra = unknown_keys(auth, ["method", field], "connectors.auth.", ctx)
    value = Map.get(auth, field, default)

    ok? =
      case {method, value} do
        {"header", v} -> is_binary(v) and not String.contains?(v, ["\n", "\r"])
        {"custom_header", v} -> is_binary(v) and Regex.match?(@header_name_re, v)
        {"query_param", v} -> is_binary(v) and Regex.match?(~r/^[A-Za-z0-9_.-]{1,64}$/, v)
        {"url_path", v} -> is_binary(v) and String.contains?(v, "{token}")
      end

    if ok? and extra == [] do
      {%{method: method, field: field, value: value}, []}
    else
      {nil,
       extra ++
         if(ok?,
           do: [],
           else:
             err(
               ctx,
               :bad_field,
               "has a custom_api connector whose auth #{field} is #{inspect(value)}; #{auth_hint(method)}."
             )
         )}
    end
  end

  defp parse_auth(%{} = auth, ctx) when not is_map_key(auth, "method"),
    do: parse_auth(Map.put(auth, "method", "header"), ctx)

  defp parse_auth(auth, ctx) do
    {nil,
     err(
       ctx,
       :bad_field,
       "has a custom_api connector with auth #{inspect(auth)}; auth is a table whose method is header, custom_header, query_param or url_path."
     )}
  end

  defp auth_hint("header"), do: "prefix is one line of text (\"\" sends the bare token)"
  defp auth_hint("custom_header"), do: "header is a header name"
  defp auth_hint("query_param"), do: "param is a query parameter name"
  defp auth_hint("url_path"), do: "template is a path holding {token}"

  defp https_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, query: nil, fragment: nil, userinfo: nil}
      when is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp https_url?(_), do: false

  defp test_url_ok?(nil, _auth), do: true
  defp test_url_ok?("/" <> _, %{method: "url_path"}), do: true

  defp test_url_ok?(url, _auth) when is_binary(url) do
    match?(%URI{scheme: "https", host: h} when is_binary(h) and h != "", URI.parse(url))
  end

  defp test_url_ok?(_, _), do: false

  defp parse_env(nil, _env_ctx, _ctx), do: {%{}, []}

  defp parse_env(map, env_ctx, ctx) when is_map(map) do
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
          case env_value(key, value, env_ctx, ctx) do
            {:ok, v} -> {Map.put(acc, key, v), errs}
            {:error, e} -> {acc, errs ++ e}
          end
      end
    end)
  end

  defp parse_env(_, _env_ctx, ctx),
    do: {%{}, err(ctx, :bad_field, "has an env that is not a table.")}

  defp env_value(_key, v, _env_ctx, _ctx) when is_binary(v), do: {:ok, v}

  defp env_value(key, %{"secret" => name} = v, env_ctx, ctx) when map_size(v) == 1 do
    cond do
      not env_ctx.privileged ->
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

  defp env_value(key, %{"from" => "connector", "provider" => provider} = v, env_ctx, ctx)
       when map_size(v) == 2 do
    if Enum.any?(env_ctx.connectors, &(&1.provider == provider)) do
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

  defp env_value(key, %{"from" => "input", "name" => name} = v, env_ctx, ctx)
       when map_size(v) == 2 do
    if is_binary(name) and name in env_ctx.inputs do
      {:ok, {:input, name}}
    else
      {:error,
       err(
         ctx,
         :env_input_undeclared,
         "sets env #{key} from input #{inspect(name)}, which it does not declare; add [inputs.#{name}] with a summary."
       )}
    end
  end

  defp env_value(key, _v, _env_ctx, ctx) do
    {:error,
     err(
       ctx,
       :bad_field,
       "has env #{key} that is neither a string, { secret = \"NAME\" }, { from = \"connector\", provider = \"...\" } nor { from = \"input\", name = \"...\" }."
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

  defp parse_claude(nil, _env, _ctx), do: {%{}, [], []}

  defp parse_claude(%{} = claude, env, ctx) do
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
            case mcp_server(name, cfg, env, ctx) do
              {:ok, s} -> {acc ++ [s], errs}
              {:error, e} -> {acc, errs ++ e}
            end
          end)

        _ ->
          {[], err(ctx, :bad_field, "has claude.mcp_servers that is not a table.")}
      end

    {settings, servers, extra ++ e_settings ++ e_servers}
  end

  defp parse_claude(_, _env, ctx),
    do: {%{}, [], err(ctx, :bad_field, "has a claude that is not a table.")}

  @mcp_fields ~w(type url headers command args env auth requires_env)

  defp mcp_server(name, %{} = cfg, profile_env, ctx) do
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
          auth in [nil, "none", "connector"],
          ctx,
          "has MCP server '#{name}' with auth #{inspect(auth)}; it is \"none\" or \"connector\"."
        ) ++
        check(
          auth != "connector" or connector_url?(cfg["url"], profile_env),
          ctx,
          "has MCP server '#{name}' with auth = \"connector\" whose url does not start with ${KEY}, KEY being an env this profile resolves from a connector; the gateway adds the credential only on that URL."
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
         auth_connector: auth == "connector",
         has_authorization:
           Enum.any?(Map.keys(headers), &(String.downcase(&1) == "authorization")),
         requires_env: Enum.uniq(requires ++ refs)
       }}
    else
      {:error, errs}
    end
  end

  defp mcp_server(name, _cfg, _env, ctx),
    do: {:error, err(ctx, :bad_field, "has MCP server '#{name}' that is not a table.")}

  defp connector_url?(url, env) when is_binary(url) do
    case Regex.run(@leading_ref_re, url) do
      [_, key] -> match?({:connector, _}, env[key])
      _ -> false
    end
  end

  defp connector_url?(_url, _env), do: false

  defp check(true, _ctx, _msg), do: []
  defp check(false, ctx, msg), do: err(ctx, :bad_field, msg)

  defp string_map?(m), do: is_map(m) and Enum.all?(m, fn {_, v} -> is_binary(v) end)
  defp string_list?(l), do: is_list(l) and Enum.all?(l, &is_binary/1)
end
