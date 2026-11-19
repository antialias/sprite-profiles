defmodule SpriteProfiles.Resolver do
  @moduledoc """
  Turns a set's picks into profiles. A name is looked up on the search path
  (`SpriteProfiles.ProfilePath`); an address (`owner/repo[/path]@ref`) is resolved to a
  commit, fetched into the cache and read from there (`SpriteProfiles.GitHub`).

  A fetched profile's qualified name is `<owner>.<name>`; its pick is the address as
  written; its `source` holds the owner, repository, path, ref and commit.
  """

  alias SpriteProfiles.{Address, GitHub, Profile, ProfilePath, Refusal}

  @doc """
  Finds and loads each pick, in order. Returns `{:ok, profiles}` or `{:error, problems}`
  with every refusal and validation error found.

  Options: `:pins`, a map from pick to `%{sha: sha, name: name}` (from a lock: the ref is
  not resolved, and the profile must declare that name); `:offline`; and the
  `SpriteProfiles.GitHub` options (`:cache_dir`, `:req_options`, ...).
  """
  @spec find([String.t()], [Path.t()], keyword()) ::
          {:ok, [Profile.t()]} | {:error, [Refusal.t() | Profile.Error.t()]}
  def find(picks, dirs, opts \\ []) do
    local? = Enum.any?(picks, &(not Address.address?(&1)))
    missing = if local?, do: ProfilePath.missing_dirs(dirs), else: []

    results =
      Enum.map(picks, fn pick ->
        if Address.address?(pick),
          do: find_address(pick, opts),
          else: ProfilePath.find_one(pick, dirs)
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
      source = %{
        owner: address.owner,
        repo: address.repo,
        path: address.path,
        ref: address.ref,
        sha: sha,
        kind: kind
      }

      {:ok,
       %{
         profile
         | qualified: Address.qualified(address, profile.name),
           pick: pick,
           source: source
       }}
    end
  end

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

  defp load(address, root, sha, pick) do
    dir = if address.path == "", do: root, else: Path.join(root, address.path)

    if File.dir?(dir) do
      Profile.load(dir, name: Address.expected_name(address), display: pick)
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
