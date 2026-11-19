defmodule SpriteProfiles.Host do
  @moduledoc """
  Where a profile's refs, files and commits come from, by host. Name resolution
  (`SpriteProfiles.Names`) and the fetch of an address or a name's commit
  (`SpriteProfiles.Resolver`) go through here.

    * **GitHub, public:** `SpriteProfiles.GitHub`, with no `git`: refs from `info/refs`,
      single files from `raw.githubusercontent.com`, a commit from the codeload tarball.
    * **GitHub, otherwise:** when `info/refs` does not show a repository, its refs come from
      `git ls-remote` (a private repository the user's git can reach), and its files from
      git too. When codeload answers 404, or its archive is over 32 MB or holds a symlink,
      the commit is fetched with git.
    * **Any other host:** `SpriteProfiles.Git` for everything.

  A repository's git URL is `https://HOST/NS…/REPO.git`. The application env
  `config :sprite_profiles, :git_hosts, %{"git.example.com" => "file:///…"}` (or the
  `:git_hosts` option, merged over it) replaces the `https://HOST` part for a host; tests
  use it to serve hosts from `file://` repositories.
  """

  alias SpriteProfiles.{Address, Git, GitHub, Refusal}

  @github "github.com"

  @typedoc """
  A repository whose refs were read: `via` says where its files come from (`:github` for
  raw.githubusercontent.com, `:git` otherwise).
  """
  @type remote :: %{
          host: String.t(),
          ns: String.t(),
          repo: String.t(),
          via: :github | :git,
          refs: %{optional(String.t()) => String.t()}
        }

  @doc """
  The git URL of `ns/repo` on `host` (see the moduledoc).

      iex> SpriteProfiles.Host.url("git.example.com", "group/sub", "tools", git_hosts: %{"git.example.com" => "https://git.example.com"})
      "https://git.example.com/group/sub/tools.git"
  """
  @spec url(String.t(), String.t(), String.t(), keyword()) :: String.t()
  def url(host, ns, repo, opts \\ []) do
    hosts =
      Map.merge(Application.get_env(:sprite_profiles, :git_hosts, %{}), opts[:git_hosts] || %{})

    base = hosts[host] || "https://#{host}"
    "#{String.trim_trailing(base, "/")}/#{ns}/#{repo}.git"
  end

  @doc "The git URL of an address's repository."
  def address_url(%Address{} = a, opts), do: url(a.host, a.owner, a.repo, opts)

  @doc """
  Reads every ref of `ns/repo` on `host`, with `"HEAD"` for the default branch:
  `{:ok, remote}`, `{:error, :not_found, why}` when the host does not show the repository
  (`why` is GitHub's status, or git's refusal), or `{:error, refusal}`.
  """
  @spec remote(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, remote()}
          | {:error, :not_found, integer() | Refusal.t()}
          | {:error, Refusal.t()}
  def remote(@github = host, ns, repo, opts) do
    case GitHub.refs(ns, repo, opts) do
      {:ok, refs} ->
        {:ok, %{host: host, ns: ns, repo: repo, via: :github, refs: refs}}

      {:error, :not_found, status} ->
        # Not public; the user's git may still reach it.
        case Git.ls_remote(url(host, ns, repo, opts), opts) do
          {:ok, refs} -> {:ok, %{host: host, ns: ns, repo: repo, via: :git, refs: refs}}
          {:error, _} -> {:error, :not_found, status}
        end

      {:error, %Refusal{}} = error ->
        error
    end
  end

  def remote(host, ns, repo, opts) do
    case Git.ls_remote(url(host, ns, repo, opts), opts) do
      {:ok, refs} -> {:ok, %{host: host, ns: ns, repo: repo, via: :git, refs: refs}}
      {:error, %Refusal{code: :repo_not_found} = r} -> {:error, :not_found, r}
      {:error, %Refusal{}} = error -> error
    end
  end

  @doc """
  Reads files of a remote at commit `sha`: `{:ok, %{path => {:ok, text} | :missing}}` or
  `{:error, refusal}`. On git, all of them come from one blob-less fetch.
  """
  @spec read_files(remote(), String.t(), [String.t()], keyword()) ::
          {:ok, %{optional(String.t()) => {:ok, binary()} | :missing}} | {:error, Refusal.t()}
  def read_files(%{via: :github} = r, sha, paths, opts) do
    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, acc} ->
      case GitHub.read_file(r.ns, r.repo, sha, path, opts) do
        {:error, %Refusal{}} = error -> {:halt, error}
        result -> {:cont, {:ok, Map.put(acc, path, result)}}
      end
    end)
  end

  def read_files(%{via: :git} = r, sha, paths, opts),
    do: Git.read_files(url(r.host, r.ns, r.repo, opts), sha, paths, opts)

  @doc """
  Resolves an address's ref to `{:ok, sha, kind}` (`:tag`, `:branch`, or `:commit` for a
  40-hex ref, which is not looked up), or `{:error, refusal}`.
  """
  @spec resolve(Address.t(), keyword()) :: {:ok, String.t(), atom()} | {:error, Refusal.t()}
  def resolve(%Address{ref: ref} = address, opts) do
    if Address.sha?(ref) or opts[:offline] do
      # Neither looks anything up, on any host.
      GitHub.resolve(address, opts)
    else
      case remote(address.host, address.owner, address.repo, opts) do
        {:ok, r} -> GitHub.find_ref(r.refs, ref, address, opts)
        {:error, :not_found, why} -> {:error, repo_not_found(address, why, opts)}
        {:error, %Refusal{}} = error -> error
      end
    end
  end

  @doc """
  The refusal for a repository the host does not show, from `remote/4`'s `why`: git's own
  refusal, or GitHub's status.
  """
  def repo_not_found(_address, %Refusal{} = git, _opts), do: git

  def repo_not_found(%Address{} = address, status, opts),
    do: GitHub.repo_not_found(address, status, opts)

  @doc """
  Makes sure the profile folder of `address` (its `path`) at `sha` is in the cache and
  returns `{:ok, dir}`, that folder. On GitHub's codeload path the folder may be missing
  from the commit, which the caller checks; git refuses it (`profile_not_found`).
  """
  @spec fetch(Address.t(), String.t(), keyword()) :: {:ok, Path.t()} | {:error, Refusal.t()}
  def fetch(%Address{host: @github} = address, sha, opts) do
    root = GitHub.cache_path(address, sha, opts)
    url = address_url(address, opts)

    cond do
      File.dir?(root) ->
        {:ok, folder(root, address.path)}

      Git.cached?(url, sha, address.path, opts) ->
        Git.cached_dir(url, sha, address.path, opts)

      true ->
        case GitHub.fetch(address, sha, Keyword.put(opts, :fallback, true)) do
          {:ok, root} ->
            {:ok, folder(root, address.path)}

          {:fallback, refusal} ->
            case Git.fetch_cached(url, sha, address.path, opts) do
              {:error, %Refusal{code: :git_missing}} -> {:error, refusal}
              result -> result
            end

          {:error, %Refusal{}} = error ->
            error
        end
    end
  end

  def fetch(%Address{} = address, sha, opts),
    do: Git.fetch_cached(address_url(address, opts), sha, address.path, opts)

  defp folder(root, ""), do: root
  defp folder(root, path), do: Path.join(root, path)
end
