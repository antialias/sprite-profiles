defmodule SpriteProfiles.Lock do
  @moduledoc """
  A lock file: a set with every address pinned to a commit. It *is* the set: `plan` and
  `launch` take `--lock FILE` instead of `--profile`.

  ```toml
  format    = 1
  locked_at = "2026-11-19T10:00:00Z"

  [[picks]]
  pick = "claude-code"                 # local: resolved on the search path at use

  [[picks]]
  pick  = "acme/profiles/linear@v1"
  owner = "acme"
  repo  = "profiles"
  path  = "linear"
  ref   = "v1"
  sha   = "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b"
  name  = "linear"
  ```

  A lock may also hold the values given for the set's inputs, in a top-level `[inputs]`
  table; it is then `format = 2`, and `format = 1` otherwise, so a lock without inputs still
  reads on an older launcher.

  A name pick (`@owner/name[@V]`) is pinned with where its name was found, and its version
  (none for a ref pick); a lock holding one is `format = 3`:

  ```toml
  [[picks]]
  pick    = "@acme/linear@1"
  version = "1.2.0"
  host    = "github.com"
  owner   = "acme"
  repo    = "sprite-profiles"
  path    = "linear"
  ref     = "linear/v1.2.0"
  sha     = "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b"
  name    = "linear"
  ```

  An address or a name on a host other than GitHub also holds its `host`, and makes the
  lock `format = 3`:

  ```toml
  [[picks]]
  pick  = "git.example.com/team/profiles/linear@v1"
  host  = "git.example.com"
  owner = "team"
  repo  = "profiles"
  path  = "linear"
  ref   = "v1"
  sha   = "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b"
  name  = "linear"
  ```

  A locked launch uses the commit and never resolves the ref, the name or the version.
  Locking again resolves every pick afresh; `diff/2` says which commits and versions
  moved. A lock that cannot be read, misses a field or has a newer `format` is refused
  (`bad_lock`). Format-1 and format-2 locks still read.
  """

  alias SpriteProfiles.{Address, Pick, Profile, Refusal}

  @format 3
  @input_name_re ~r/^[a-z][a-z0-9_]{0,30}$/
  @default_path "sprite-profiles.lock"

  @type entry :: %{
          required(:pick) => String.t(),
          optional(:version) => String.t() | nil,
          optional(:host) => String.t(),
          optional(:owner) => String.t(),
          optional(:repo) => String.t(),
          optional(:path) => String.t(),
          optional(:ref) => String.t(),
          optional(:sha) => String.t(),
          optional(:name) => String.t()
        }

  @keys [:pick, :version, :host, :owner, :repo, :path, :ref, :sha, :name]

  @doc "Where `mix profiles.lock` writes unless told otherwise."
  def default_path, do: @default_path

  @doc "The lock entries for resolved profiles, in pick order."
  @spec entries([Profile.t()]) :: [entry()]
  def entries(profiles) do
    Enum.map(profiles, fn
      %Profile{source: nil, pick: pick} ->
        %{pick: pick}

      %Profile{source: src, pick: "@" <> _ = pick, name: name} ->
        %{
          pick: pick,
          version: src[:version],
          host: src[:host] || Pick.github(),
          owner: src.owner,
          repo: src.repo,
          path: src.path,
          ref: src.ref,
          sha: src.sha,
          name: name
        }

      %Profile{source: src, pick: pick, name: name} ->
        with_host(
          %{
            pick: pick,
            owner: src.owner,
            repo: src.repo,
            path: src.path,
            ref: src.ref,
            sha: src.sha,
            name: name
          },
          src[:host]
        )
    end)
  end

  # An address records its host only off GitHub.
  defp with_host(entry, host) when host in [nil, "github.com"], do: entry
  defp with_host(entry, host), do: Map.put(entry, :host, host)

  @doc "The lock file's text for `entries` and the given `inputs` (`%{name => value}`)."
  @spec encode([entry()], DateTime.t(), %{optional(String.t()) => String.t()}) :: String.t()
  def encode(entries, at \\ DateTime.utc_now(), inputs \\ %{}) do
    format =
      cond do
        Enum.any?(entries, &(Pick.kind(&1.pick) == :name or Map.has_key?(&1, :host))) -> 3
        inputs != %{} -> 2
        true -> 1
      end

    head = """
    # A set with every address and name pinned to a commit. Written by `sprite-profiles lock` (or `mix profiles.lock`).
    format    = #{format}
    locked_at = #{q(at |> DateTime.truncate(:second) |> DateTime.to_iso8601())}
    """

    head =
      if inputs == %{} do
        head
      else
        head <>
          "\n[inputs]\n" <>
          Enum.map_join(Enum.sort(inputs), "", fn {k, v} -> "#{k} = #{q(v)}\n" end)
      end

    body =
      Enum.map_join(entries, "", fn e ->
        keys = for k <- @keys, e[k] != nil, do: k

        width =
          keys |> Enum.map(&String.length(Atom.to_string(&1))) |> Enum.max(fn -> 5 end) |> max(5)

        lines =
          for k <- keys do
            "#{String.pad_trailing(Atom.to_string(k), width)} = #{q(e[k])}\n"
          end

        "\n[[picks]]\n" <> Enum.join(lines)
      end)

    head <> body
  end

  defp q(s),
    do: "\"" <> (s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")) <> "\""

  @doc "Writes the lock for `profiles`, with the given `inputs`, to `path`."
  def write(path, profiles, inputs \\ %{}) do
    File.write!(path, encode(entries(profiles), DateTime.utc_now(), inputs))
  end

  @doc """
  Reads a lock file's picks. Returns `{:ok, entries}` or `{:error, [refusal]}` (`bad_lock`).
  """
  @spec read(Path.t()) :: {:ok, [entry()]} | {:error, [Refusal.t()]}
  def read(path) do
    with {:ok, %{picks: entries}} <- load(path), do: {:ok, entries}
  end

  @doc """
  Reads a lock file: `{:ok, %{picks: entries, inputs: %{name => value}}}` or
  `{:error, [refusal]}` (`bad_lock`).
  """
  @spec load(Path.t()) ::
          {:ok, %{picks: [entry()], inputs: %{optional(String.t()) => String.t()}}}
          | {:error, [Refusal.t()]}
  def load(path) do
    with {:ok, text} <- read_file(path),
         {:ok, map} <- decode(text, path),
         {:ok, entries} <- validate(map, path),
         {:ok, inputs} <- validate_inputs(map, path) do
      {:ok, %{picks: entries, inputs: inputs}}
    end
  end

  defp validate_inputs(%{"inputs" => inputs, "format" => f}, path) do
    cond do
      f < 2 ->
        bad(path, "holds [inputs], which is format 2, but says format = #{f}")

      not is_map(inputs) ->
        bad(path, "has an [inputs] that is not a table")

      true ->
        case Enum.find(Enum.sort(inputs), fn {k, v} -> not input_ok?(k, v) end) do
          nil ->
            {:ok, inputs}

          {k, _} ->
            bad(
              path,
              "has a bad input #{inspect(k)}: a value is one line of text, at most 256 characters"
            )
        end
    end
  end

  defp validate_inputs(_map, _path), do: {:ok, %{}}

  defp input_ok?(k, v) do
    Regex.match?(@input_name_re, k) and is_binary(v) and String.length(v) <= 256 and
      not String.contains?(v, ["\n", "\r"])
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> bad(path, "cannot be read (#{:file.format_error(reason)})")
    end
  end

  defp decode(text, path) do
    case TomlElixir.decode(text, spec: :"1.0.0") do
      {:ok, map} -> {:ok, map}
      {:error, e} -> bad(path, "is not valid TOML: #{Exception.message(e)}")
    end
  end

  defp validate(map, path) do
    case map do
      %{"format" => f} when is_integer(f) and f > @format ->
        bad(
          path,
          "is format #{f}; this launcher reads up to format #{@format}, so upgrade sprite-profiles"
        )

      %{"format" => f, "picks" => picks} when is_integer(f) and f >= 1 and is_list(picks) ->
        picks
        |> Enum.with_index(1)
        |> Enum.reduce_while({:ok, []}, fn {entry, i}, {:ok, acc} ->
          case entry(entry, f) do
            {:ok, e} -> {:cont, {:ok, acc ++ [e]}}
            {:error, why} -> {:halt, bad(path, "has a bad pick ##{i}: #{why}")}
          end
        end)

      _ ->
        bad(path, "needs a format (1 to #{@format}) and a [[picks]] list")
    end
  end

  @address_fields ~w(owner repo path ref sha name)
  @name_fields ~w(host owner repo path ref sha name)

  defp entry(%{"pick" => pick} = e, format) when is_binary(pick) do
    case Pick.kind(pick) do
      :local ->
        if Profile.valid_name?(pick) and map_size(e) == 1,
          do: {:ok, %{pick: pick}},
          else: {:error, "#{inspect(pick)} is a local pick, which holds only `pick`"}

      :address ->
        address_entry(pick, e)

      :name ->
        name_entry(pick, e, format)
    end
  end

  defp entry(_, _), do: {:error, "it has no `pick` string"}

  # An address on GitHub may leave out its host; one elsewhere names it.
  defp address_entry(pick, e) do
    if Enum.all?(@address_fields, &is_binary(e[&1])) do
      with {:ok, a} <- Address.parse(pick),
           true <- e["host"] == a.host or (e["host"] == nil and Address.github?(a)),
           true <-
             {a.owner, a.repo, a.path, a.ref} == {e["owner"], e["repo"], e["path"], e["ref"]},
           true <- sha?(e["sha"]),
           true <- Profile.valid_name?(e["name"]) do
        {:ok,
         with_host(
           %{
             pick: pick,
             owner: a.owner,
             repo: a.repo,
             path: a.path,
             ref: a.ref,
             sha: e["sha"],
             name: e["name"]
           },
           a.host
         )}
      else
        _ -> {:error, "#{pick} does not agree with its host, owner, repo, path, ref, sha or name"}
      end
    else
      {:error, "#{pick} needs #{Enum.join(@address_fields, ", ")}"}
    end
  end

  defp name_entry(pick, e, format) do
    cond do
      format < 3 ->
        {:error, "#{pick} is a name, which a lock holds from format 3, but it says #{format}"}

      not Enum.all?(@name_fields, &is_binary(e[&1])) ->
        {:error, "#{pick} needs #{Enum.join(@name_fields, ", ")}"}

      true ->
        with {:ok, p} <- Pick.parse(pick),
             true <- e["host"] == p.host,
             true <- {e["owner"], e["name"]} == {Pick.ns(p), p.name},
             true <- where_ok?(e["repo"], e["path"]),
             true <- sha?(e["sha"]),
             true <- version_ok?(p, e["version"], e["ref"]) do
          {:ok,
           %{
             pick: pick,
             version: e["version"],
             host: p.host,
             owner: e["owner"],
             repo: e["repo"],
             path: e["path"],
             ref: e["ref"],
             sha: e["sha"],
             name: e["name"]
           }}
        else
          _ ->
            {:error,
             "#{pick} does not agree with its version, host, owner, repo, path, ref, sha or name"}
        end
    end
  end

  defp sha?(s), do: Regex.match?(~r/^[0-9a-f]{40}$/, s)

  defp where_ok?(repo, path) do
    segments = if path == "", do: [repo], else: [repo | String.split(path, "/")]
    Enum.all?(segments, &(&1 not in ["", ".", ".."] and &1 =~ ~r/^[A-Za-z0-9._-]+$/))
  end

  # A ref pick holds no version and the ref as picked; a version pick holds the version
  # its tag names, matching the pick's prefix.
  defp version_ok?(%Pick{version: {:ref, ref}}, nil, ref), do: true
  defp version_ok?(%Pick{version: {:ref, _}}, _, _), do: false

  defp version_ok?(%Pick{} = p, version, ref) when is_binary(version) do
    Pick.semver(version) != :error and
      (ref == "v" <> version or String.ends_with?(ref, "/v" <> version)) and
      (p.version == nil or Pick.matches?(p, version))
  end

  defp version_ok?(_, _, _), do: false

  defp bad(path, why),
    do:
      {:error,
       [
         Refusal.new(
           :bad_lock,
           [],
           "the lock file #{path} #{why}; write it again with mix profiles.lock."
         )
       ]}

  @doc "The picks of a lock, in order."
  def picks(entries), do: Enum.map(entries, & &1.pick)

  @doc """
  The pins of a lock, for `SpriteProfiles.Resolver.find/3`'s `:pins`: the commit and name
  of each address, and for a name pick also where it was found and its version.
  """
  def pins(entries) do
    for %{sha: sha, name: name, pick: pick} = e <- entries, into: %{} do
      if Pick.kind(pick) == :name,
        do: {pick, Map.take(e, [:sha, :name, :owner, :repo, :path, :ref, :version])},
        else: {pick, %{sha: sha, name: name}}
    end
  end

  @doc """
  What changed between an old lock and new entries: one line per pick whose version or
  commit moved, as `@acme/linear@1: 1.0.0 → 1.1.0 (new version)` or
  `pick: old → new (tag moved)`. `kinds` maps a pick to how its ref resolved (`:tag`,
  `:branch`, `:commit`).
  """
  @spec diff([entry()], [entry()], %{optional(String.t()) => atom()}) :: [String.t()]
  def diff(old, new, kinds \\ %{}) do
    before = Map.new(old, &{&1.pick, &1})

    for %{sha: _, pick: p} = e <- new,
        was = before[p],
        is_map(was) and is_binary(was[:sha]),
        line = change(p, was, e, kinds[p]),
        line != nil,
        do: line
  end

  defp change(p, %{version: v1}, %{version: v2}, _kind)
       when is_binary(v1) and is_binary(v2) and v1 != v2,
       do: "#{p}: #{v1} → #{v2} (new version)"

  defp change(_p, %{sha: sha}, %{sha: sha}, _kind), do: nil

  defp change(p, %{sha: was}, %{sha: sha}, kind) do
    what =
      case kind do
        :tag -> " (tag moved)"
        :branch -> " (branch moved)"
        _ -> ""
      end

    "#{p}: #{String.slice(was, 0, 8)} → #{String.slice(sha, 0, 8)}#{what}"
  end
end
