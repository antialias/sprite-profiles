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

  A locked launch uses the commit and never resolves the ref. Locking again resolves every
  ref afresh; `diff/2` says which commits moved. A lock that cannot be read, misses a field
  or has a newer `format` is refused (`bad_lock`).
  """

  alias SpriteProfiles.{Address, Profile, Refusal}

  @format 1
  @default_path "sprite-profiles.lock"

  @type entry :: %{
          required(:pick) => String.t(),
          optional(:owner) => String.t(),
          optional(:repo) => String.t(),
          optional(:path) => String.t(),
          optional(:ref) => String.t(),
          optional(:sha) => String.t(),
          optional(:name) => String.t()
        }

  @doc "Where `mix profiles.lock` writes unless told otherwise."
  def default_path, do: @default_path

  @doc "The lock entries for resolved profiles, in pick order."
  @spec entries([Profile.t()]) :: [entry()]
  def entries(profiles) do
    Enum.map(profiles, fn
      %Profile{source: nil, pick: pick} ->
        %{pick: pick}

      %Profile{source: src, pick: pick, name: name} ->
        %{
          pick: pick,
          owner: src.owner,
          repo: src.repo,
          path: src.path,
          ref: src.ref,
          sha: src.sha,
          name: name
        }
    end)
  end

  @doc "The lock file's text for `entries`."
  @spec encode([entry()], DateTime.t()) :: String.t()
  def encode(entries, at \\ DateTime.utc_now()) do
    head = """
    # A set with every address pinned to a commit. Written by `mix profiles.lock`.
    format    = #{@format}
    locked_at = #{q(at |> DateTime.truncate(:second) |> DateTime.to_iso8601())}
    """

    body =
      Enum.map_join(entries, "", fn e ->
        keys = [:pick, :owner, :repo, :path, :ref, :sha, :name]

        lines =
          for k <- keys, Map.has_key?(e, k) do
            "#{String.pad_trailing(Atom.to_string(k), 5)} = #{q(e[k])}\n"
          end

        "\n[[picks]]\n" <> Enum.join(lines)
      end)

    head <> body
  end

  defp q(s),
    do: "\"" <> (s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")) <> "\""

  @doc "Writes the lock for `profiles` to `path`."
  def write(path, profiles) do
    File.write!(path, encode(entries(profiles)))
  end

  @doc """
  Reads a lock file. Returns `{:ok, entries}` or `{:error, [refusal]}` (`bad_lock`).
  """
  @spec read(Path.t()) :: {:ok, [entry()]} | {:error, [Refusal.t()]}
  def read(path) do
    with {:ok, text} <- read_file(path),
         {:ok, map} <- decode(text, path) do
      validate(map, path)
    end
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
          case entry(entry) do
            {:ok, e} -> {:cont, {:ok, acc ++ [e]}}
            {:error, why} -> {:halt, bad(path, "has a bad pick ##{i}: #{why}")}
          end
        end)

      _ ->
        bad(path, "needs format = #{@format} and a [[picks]] list")
    end
  end

  @address_fields ~w(owner repo path ref sha name)

  defp entry(%{"pick" => pick} = e) when is_binary(pick) do
    cond do
      not Address.address?(pick) ->
        if Profile.valid_name?(pick) and map_size(e) == 1,
          do: {:ok, %{pick: pick}},
          else: {:error, "#{inspect(pick)} is a local pick, which holds only `pick`"}

      not Enum.all?(@address_fields, &is_binary(e[&1])) ->
        {:error, "#{pick} needs #{Enum.join(@address_fields, ", ")}"}

      true ->
        with {:ok, a} <- Address.parse(pick),
             true <-
               {a.owner, a.repo, a.path, a.ref} == {e["owner"], e["repo"], e["path"], e["ref"]},
             true <- Regex.match?(~r/^[0-9a-f]{40}$/, e["sha"]),
             true <- Profile.valid_name?(e["name"]) do
          {:ok,
           %{
             pick: pick,
             owner: a.owner,
             repo: a.repo,
             path: a.path,
             ref: a.ref,
             sha: e["sha"],
             name: e["name"]
           }}
        else
          _ -> {:error, "#{pick} does not agree with its owner, repo, path, ref, sha or name"}
        end
    end
  end

  defp entry(_), do: {:error, "it has no `pick` string"}

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

  @doc "The pins of a lock, for `SpriteProfiles.Resolver.find/3`'s `:pins`."
  def pins(entries) do
    for %{sha: sha, name: name, pick: pick} <- entries,
        into: %{},
        do: {pick, %{sha: sha, name: name}}
  end

  @doc """
  What changed between an old lock and new entries: one line per address whose commit
  moved, as `pick: old → new (tag moved)`. `kinds` maps a pick to how its ref resolved
  (`:tag`, `:branch`, `:commit`).
  """
  @spec diff([entry()], [entry()], %{optional(String.t()) => atom()}) :: [String.t()]
  def diff(old, new, kinds \\ %{}) do
    before = for %{sha: sha, pick: p} <- old, into: %{}, do: {p, sha}

    for %{sha: sha, pick: p} <- new, was = before[p], was != sha do
      what =
        case kinds[p] do
          :tag -> " (tag moved)"
          :branch -> " (branch moved)"
          _ -> ""
        end

      "#{p}: #{String.slice(was, 0, 8)} → #{String.slice(sha, 0, 8)}#{what}"
    end
  end
end
