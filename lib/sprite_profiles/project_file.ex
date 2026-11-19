defmodule SpriteProfiles.ProjectFile do
  @moduledoc """
  `sprite-profiles.toml`: a project's set of profiles, as `package.json` is an npm
  project's dependencies.

      profiles = ["claude-code", "@acme/linear@1"]

      [inputs]
      # input = "value", as -i would pass

  `profiles` holds picks, in the order to apply them; `[inputs]` holds the values `-i`
  would pass. With no picks on the command line, `plan`, `launch` and `lock` read the file
  in the working directory, and `lock` writes `sprite-profiles.lock` beside it.

  `add/2` and `remove/2` change the `profiles` list and keep the rest of the file's text,
  comments included, when they can; otherwise they write the file afresh.
  """

  alias SpriteProfiles.{Address, Pick, Refusal}

  @name "sprite-profiles.toml"
  @lock "sprite-profiles.lock"
  @fields ~w(profiles inputs)
  @profiles_re ~r/^profiles[ \t]*=[ \t]*\[[^\]]*\]/m

  @type t :: %{profiles: [String.t()], inputs: %{optional(String.t()) => String.t()}}

  @doc "The file's name."
  def name, do: @name

  @doc "The project file in `dir`."
  def path(dir), do: Path.join(dir, @name)

  @doc "The lock file beside the project file `path`."
  def lock_path(path), do: Path.join(Path.dirname(path), @lock)

  @doc """
  Reads the file at `path`: `{:ok, %{profiles: picks, inputs: map}}`, `:missing`, or
  `{:error, [refusal]}` (`bad_project_file`).
  """
  @spec read(Path.t()) :: {:ok, t()} | :missing | {:error, [Refusal.t()]}
  def read(path) do
    case File.read(path) do
      {:ok, text} -> decode(text, path)
      {:error, :enoent} -> :missing
      {:error, reason} -> bad(path, "cannot be read: #{:file.format_error(reason)}")
    end
  end

  @doc "Decodes the file's text; `path` is for sentences."
  @spec decode(String.t(), Path.t()) :: {:ok, t()} | {:error, [Refusal.t()]}
  def decode(text, path) do
    case TomlElixir.decode(text, spec: :"1.0.0") do
      {:ok, map} -> validate(map, path)
      {:error, e} -> bad(path, "is not valid TOML 1.0: #{Exception.message(e)}")
    end
  end

  defp validate(map, path) do
    unknown = Map.keys(map) -- @fields
    profiles = Map.get(map, "profiles", [])
    inputs = Map.get(map, "inputs", %{})

    cond do
      unknown != [] ->
        bad(
          path,
          "has #{Enum.join(Enum.sort(unknown), ", ")}; it holds only profiles and [inputs]."
        )

      not (is_list(profiles) and Enum.all?(profiles, &is_binary/1)) ->
        bad(path, "has a profiles that is not a list of strings, like [\"claude-code\"].")

      not (is_map(inputs) and Enum.all?(inputs, fn {_, v} -> is_binary(v) end)) ->
        bad(path, "has [inputs] whose values are not all strings, as -i would pass them.")

      true ->
        {:ok, %{profiles: profiles, inputs: inputs}}
    end
  end

  defp bad(path, rest),
    do: {:error, [Refusal.new(:bad_project_file, [], "#{Path.basename(path)} #{rest}")]}

  @doc """
  What makes two picks the same profile, ignoring the version or ref: a name's
  `@HOST/NS/NAME`, an address's repository and folder, or a local name.
  """
  def identity(pick) do
    case Pick.kind(pick) do
      :name ->
        case Pick.parse(pick) do
          {:ok, p} -> Pick.identity(p)
          _ -> pick
        end

      :address ->
        case Address.parse(pick) do
          {:ok, a} -> Address.identity(a)
          _ -> pick
        end

      :local ->
        pick
    end
  end

  @doc """
  The list after adding `new` picks: one already present (by `identity/1`) is replaced
  where it stands; the others are appended in order.
  """
  def add(profiles, new) do
    Enum.reduce(new, profiles, fn pick, acc ->
      id = identity(pick)

      case Enum.find_index(acc, &(identity(&1) == id)) do
        nil -> acc ++ [pick]
        i -> List.replace_at(acc, i, pick)
      end
    end)
  end

  @doc """
  The list without `gone` (by `identity/1`): `{:ok, profiles}`, or `{:missing, picks}`
  for those of `gone` that are not in it.
  """
  def remove(profiles, gone) do
    ids = Enum.map(gone, &identity/1)

    case Enum.reject(gone, fn g -> Enum.any?(profiles, &(identity(&1) == identity(g))) end) do
      [] -> {:ok, Enum.reject(profiles, &(identity(&1) in ids))}
      missing -> {:missing, missing}
    end
  end

  @doc """
  The file's text with `profiles` as its list. `text` is the file as it was (nil when
  there is none): its `profiles = [...]` is replaced and the rest kept, unless that cannot
  be done safely, when the file is written afresh with its inputs.
  """
  def update(nil, profiles), do: encode(profiles, %{})

  def update(text, profiles) do
    case decode(text, @name) do
      {:ok, %{inputs: inputs}} ->
        edited =
          case Regex.scan(@profiles_re, text) do
            [_] -> Regex.replace(@profiles_re, text, list(profiles), global: false)
            [] -> list(profiles) <> "\n\n" <> text
            _ -> nil
          end

        if edited && decode(edited, @name) == {:ok, %{profiles: profiles, inputs: inputs}},
          do: edited,
          else: encode(profiles, inputs)

      {:error, _} ->
        encode(profiles, %{})
    end
  end

  @doc "A new file's text."
  def encode(profiles, inputs) do
    inputs_text =
      if inputs == %{},
        do: "# input = \"value\", as -i would pass\n",
        else: Enum.map_join(Enum.sort(inputs), "", fn {k, v} -> "#{key(k)} = #{q(v)}\n" end)

    "#{list(profiles)}\n\n[inputs]\n#{inputs_text}"
  end

  defp list([]), do: "profiles = []"
  defp list(picks), do: "profiles = [#{Enum.map_join(picks, ", ", &q/1)}]"

  defp key(k), do: if(Regex.match?(~r/^[A-Za-z0-9_-]+$/, k), do: k, else: q(k))

  defp q(s),
    do: "\"" <> (s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")) <> "\""
end
