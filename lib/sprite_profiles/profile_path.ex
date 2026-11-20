defmodule SpriteProfiles.ProfilePath do
  @moduledoc """
  Where profiles are looked for: a search path of folders, each holding profile folders.

  The path is every `--dir` given, in order, then the folders in `SPRITE_PROFILES_PATH`
  (colon-separated). When neither gives a folder, it is the repository's `profiles/` plus
  `~/.config/sprite-profiles/profiles` when that exists, so private profiles can live outside
  the repository.

  A pick is found in exactly one folder. A name that is in two folders is refused
  (`profile_ambiguous`), naming both paths, rather than one shadowing the other.
  """

  alias SpriteProfiles.{Pick, Profile, Refusal}

  @env "SPRITE_PROFILES_PATH"
  @repo_dir "profiles"
  @private_dir "~/.config/sprite-profiles/profiles"

  @doc "The environment variable that adds folders to the path."
  def env_var, do: @env

  @doc """
  The search path for the given `--dir` values and the value of `SPRITE_PROFILES_PATH`
  (`nil` or `""` when unset). Folders are expanded and deduplicated, first one kept.
  """
  @spec dirs([Path.t()], String.t() | nil) :: [Path.t()]
  def dirs(cli_dirs, env_value \\ System.get_env(@env)) do
    from_env = String.split(env_value || "", ":", trim: true)

    case cli_dirs ++ from_env do
      [] -> [@repo_dir | Enum.filter([@private_dir], &File.dir?(Path.expand(&1)))]
      given -> given
    end
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  @doc """
  Finds and loads each of `names` along `dirs`. Returns `{:ok, profiles}` in pick order, or
  `{:error, problems}` with every refusal and validation error found.
  """
  @spec find([String.t()], [Path.t()]) ::
          {:ok, [Profile.t()]} | {:error, [Refusal.t() | Profile.Error.t()]}
  def find(names, dirs) do
    results = Enum.map(names, &find_one(&1, dirs))
    errors = missing_dirs(dirs) ++ Enum.flat_map(results, &errors/1)

    if errors == [],
      do: {:ok, Enum.map(results, fn {:ok, p} -> p end)},
      else: {:error, errors}
  end

  @doc "A `profile_dir_missing` refusal for each folder on the path that does not exist."
  @spec missing_dirs([Path.t()]) :: [Refusal.t()]
  def missing_dirs(dirs) do
    for dir <- dirs, not File.dir?(dir) do
      Refusal.new(
        :profile_dir_missing,
        [],
        "the profile folder #{dir} does not exist; fix the --dir or #{@env} entry."
      )
    end
  end

  defp errors({:error, e}), do: e
  defp errors(_), do: []

  @doc """
  Loads the profile folder a path pick names (`SpriteProfiles.Pick.resolve_path/2`, with
  relative paths taken from `base`), with the checks a folder on the search path gets: its
  name must be the folder's. The profile's pick is the path as written; its qualified name
  is its name, as for any local profile.
  """
  @spec load_path(String.t(), Path.t()) ::
          {:ok, Profile.t()} | {:error, [Refusal.t() | Profile.Error.t()]}
  def load_path(pick, base) do
    dir = Pick.resolve_path(pick, base)

    if File.dir?(dir) do
      with {:ok, profile} <- Profile.load(dir, display: pick, name: folder_name(dir)),
           do: {:ok, %{profile | pick: pick}}
    else
      {:error,
       [
         Refusal.new(
           :profile_not_found,
           [pick],
           "there is no profile folder at #{dir} (picked as #{pick}); check the path."
         )
       ]}
    end
  end

  # A published profile's repository is named `sprite-profile-NAME`, so a checkout of one is
  # a folder of that name, holding profile NAME: its author can pick it as `./`.
  defp folder_name(dir) do
    case Path.basename(dir) do
      "sprite-profile-" <> name when name != "" -> name
      base -> base
    end
  end

  @doc "Finds and loads one profile by name along `dirs`."
  @spec find_one(String.t(), [Path.t()]) ::
          {:ok, Profile.t()} | {:error, [Refusal.t() | Profile.Error.t()]}
  def find_one(name, dirs) do
    case for(dir <- dirs, path = Path.join(dir, name), File.dir?(path), do: path) do
      [path] ->
        Profile.load(path)

      [] ->
        {:error,
         [
           Refusal.new(
             :profile_not_found,
             [name],
             "there is no profile '#{name}' in #{Enum.join(dirs, ", ")}; check the name, or add its folder with --dir or #{@env}."
           )
         ]}

      paths ->
        {:error,
         [
           Refusal.new(
             :profile_ambiguous,
             [name],
             "profile '#{name}' is in more than one folder (#{Enum.join(paths, " and ")}); rename one, or leave its folder off the path."
           )
         ]}
    end
  end
end
