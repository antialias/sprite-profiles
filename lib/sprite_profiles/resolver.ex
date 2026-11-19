defmodule SpriteProfiles.Resolver do
  @moduledoc """
  Turns a set's picks into profiles (`SpriteProfiles.Pick.kind/1` tells them apart). A
  local name is looked up on the search path (`SpriteProfiles.ProfilePath`); an address
  (`owner/repo[/path]@ref`) is resolved to a commit, fetched into the cache and read from
  there (`SpriteProfiles.GitHub`); a name pick (`@owner/name[@version]`) is first found by
  convention (`SpriteProfiles.Names`), then fetched like the address it stands for.

  A fetched profile's qualified name is `<owner>.<name>`, whether it was picked by name or
  by address; its pick is as written; its `source` holds the host, owner, repository,
  path, ref, commit, how the ref resolved, and the version (nil unless picked by version).
  """

  alias SpriteProfiles.{Address, GitHub, Host, Names, Pick, Profile, ProfilePath, Refusal}

  @doc """
  Finds and loads each pick, in order. Returns `{:ok, profiles}` or `{:error, problems}`
  with every refusal and validation error found.

  Options: `:pins`, a map from pick to `%{sha: sha, name: name}` (from a lock: the ref is
  not resolved, and the profile must declare that name; a name pick's pin also holds its
  `owner`, `repo`, `path`, `ref` and `version`, so no name is resolved); `:offline`; and the
  `SpriteProfiles.GitHub` options (`:cache_dir`, `:req_options`, ...).
  """
  @spec find([String.t()], [Path.t()], keyword()) ::
          {:ok, [Profile.t()]} | {:error, [Refusal.t() | Profile.Error.t()]}
  def find(picks, dirs, opts \\ []) do
    local? = Enum.any?(picks, &(Pick.kind(&1) == :local))
    missing = if local?, do: ProfilePath.missing_dirs(dirs), else: []

    results =
      Enum.map(picks, fn pick ->
        case Pick.kind(pick) do
          :local -> ProfilePath.find_one(pick, dirs)
          :address -> find_address(pick, opts)
          :name -> find_name(pick, opts)
        end
      end)

    errors = missing ++ Enum.flat_map(results, &errors/1)

    if errors == [],
      do: {:ok, Enum.map(results, fn {:ok, p} -> p end)},
      else: {:error, errors}
  end

  defp errors({:error, e}), do: e
  defp errors(_), do: []

  defp find_address(pick, opts) do
    gh = Keyword.put(opts, :pick, pick)
    pin = (opts[:pins] || %{})[pick]

    with {:ok, address} <- parse(pick),
         {:ok, sha, kind} <- sha(address, pin, gh),
         {:ok, root} <- wrap(GitHub.fetch(address, sha, gh)),
         {:ok, profile} <- load(address, root, sha, pick),
         :ok <- check_pin(profile, pin) do
      {:ok, fetched(profile, pick, address, sha, kind, nil)}
    end
  end

  defp find_name(pick, opts) do
    gh = Keyword.put(opts, :pick, pick)
    pin = (opts[:pins] || %{})[pick]

    with {:ok, p} <- parse_name(pick),
         {:ok, r} <- name_target(p, pick, pin, gh),
         {:ok, root} <- wrap(Host.fetch(r.host, r.address, r.sha, gh)),
         {:ok, profile} <- load(r.address, root, r.sha, pick, p.name),
         :ok <- check_pin(profile, pin) do
      {:ok, fetched(profile, pick, r.address, r.sha, r.kind, r.version)}
    end
  end

  defp fetched(profile, pick, address, sha, kind, version) do
    source = %{
      host: Pick.github(),
      owner: address.owner,
      repo: address.repo,
      path: address.path,
      ref: address.ref,
      sha: sha,
      kind: kind,
      version: version
    }

    %{profile | qualified: Address.qualified(address, profile.name), pick: pick, source: source}
  end

  defp parse_name(pick) do
    case Pick.parse(pick) do
      {:ok, p} ->
        if Pick.supported?(p), do: {:ok, p}, else: {:error, [Names.host_not_supported(p, pick)]}

      {:error, code} ->
        {:error, [Refusal.new(code, [pick], "#{inspect(pick)} is not a usable name.")]}
    end
  end

  # A locked name resolves nothing: the lock holds where it was found.
  defp name_target(p, _pick, %{sha: sha} = pin, _opts) do
    {:ok,
     %{
       host: p.host,
       address: %Address{owner: pin.owner, repo: pin.repo, path: pin.path, ref: pin.ref},
       sha: sha,
       kind: :locked,
       version: pin[:version]
     }}
  end

  defp name_target(p, pick, nil, opts), do: wrap(Names.resolve(p, pick, opts))

  defp parse(pick) do
    case Address.parse(pick) do
      {:ok, a} ->
        {:ok, a}

      {:error, code} ->
        {:error, [Refusal.new(code, [pick], "#{inspect(pick)} is not a usable address.")]}
    end
  end

  defp sha(_address, %{sha: sha}, _opts), do: {:ok, sha, :locked}
  defp sha(address, nil, opts), do: wrap(GitHub.resolve(address, opts))

  defp wrap({:error, %Refusal{} = r}), do: {:error, [r]}
  defp wrap(ok), do: ok

  defp load(address, root, sha, pick, name \\ nil) do
    dir = if address.path == "", do: root, else: Path.join(root, address.path)

    if File.dir?(dir) do
      Profile.load(dir, name: name || Address.expected_name(address), display: pick)
    else
      {:error,
       [
         Refusal.new(
           :profile_not_found,
           [pick],
           "profile '#{pick}' names the folder #{address.path}, which #{Address.repo_slug(address)} does not have at #{String.slice(sha, 0, 8)}; check the path."
         )
       ]}
    end
  end

  defp check_pin(_profile, nil), do: :ok
  defp check_pin(%Profile{name: name}, %{name: name}), do: :ok

  defp check_pin(%Profile{name: name}, %{name: locked}) do
    {:error,
     [
       Refusal.new(
         :bad_lock,
         [],
         "the lock says the profile is named '#{locked}', but the commit holds '#{name}'; lock the set again."
       )
     ]}
  end
end
