defmodule SpriteProfiles.GitHub do
  @moduledoc """
  Fetches profiles from public GitHub repositories, with no token and no git binary.

    * `resolve/2` turns a ref into a commit with one request to
      `github.com/<owner>/<repo>.git/info/refs?service=git-upload-pack`, the list
      `git ls-remote` reads. It is served by github.com, not the REST API, so the REST
      API's unauthenticated rate limit does not apply.
    * `fetch/2` downloads `codeload.github.com/<owner>/<repo>/tar.gz/<sha>`, checks every
      entry, and extracts it into the cache, where it stays: a commit never changes, so an
      entry is never invalidated.

  The cache is `<root>/github/<owner>/<repo>/<sha>/`, holding the whole repository at that
  commit. The root is `SPRITE_PROFILES_CACHE`, else `$XDG_CACHE_HOME/sprite-profiles`, else
  `~/.cache/sprite-profiles`. A partial download never lands there.

  Options for both: `:pick` (the pick as written, for sentences), `:offline` (refuse
  anything that would call out, `not_cached`), `:cache_dir` (the root), `:req_options`
  (merged into the `Req` request; tests pass a `Req.Test` plug), `:github_url` and
  `:codeload_url`. The application env `config :sprite_profiles, SpriteProfiles.GitHub,
  req_options: [...]` is merged first.
  """

  alias SpriteProfiles.{Address, Refusal}

  @github_url "https://github.com"
  @codeload_url "https://codeload.github.com"
  @max_archive 32 * 1024 * 1024

  @doc "The largest archive accepted, in bytes (compressed)."
  def max_archive, do: @max_archive

  @doc "The cache root (see the moduledoc)."
  def cache_root(opts \\ []) do
    cond do
      opts[:cache_dir] ->
        Path.expand(opts[:cache_dir])

      (dir = System.get_env("SPRITE_PROFILES_CACHE")) not in [nil, ""] ->
        Path.expand(dir)

      (xdg = System.get_env("XDG_CACHE_HOME")) not in [nil, ""] ->
        Path.join(xdg, "sprite-profiles")

      true ->
        Path.expand("~/.cache/sprite-profiles")
    end
  end

  @doc "Where the repository of `address` at `sha` is (or would be) cached."
  def cache_path(%Address{owner: o, repo: r}, sha, opts \\ []),
    do: Path.join([cache_root(opts), "github", o, r, sha])

  @doc "True when the repository of `address` at `sha` is in the cache."
  def cached?(%Address{} = address, sha, opts \\ []),
    do: File.dir?(cache_path(address, sha, opts))

  ## resolve

  @doc """
  Resolves the address's ref to `{:ok, sha, kind}`, `kind` being `:tag`, `:branch` or
  `:commit` (a 40-hex ref, which is not looked up). An annotated tag gives the commit it
  points at. A name that is both a tag and a branch is refused (`ref_ambiguous`).
  """
  @spec resolve(Address.t(), keyword()) :: {:ok, String.t(), atom()} | {:error, Refusal.t()}
  def resolve(%Address{ref: ref} = address, opts \\ []) do
    cond do
      Address.sha?(ref) ->
        {:ok, String.downcase(ref), :commit}

      opts[:offline] ->
        {:error,
         refusal(
           :not_cached,
           address,
           opts,
           "is not pinned to a commit, and --offline forbids looking up #{ref}; lock the set first (mix profiles.lock) and plan from the lock."
         )}

      true ->
        url =
          "#{opts[:github_url] || @github_url}/#{Address.repo_slug(address)}.git/info/refs?service=git-upload-pack"

        case get(url, opts) do
          {:ok, %{status: 200, body: body}} ->
            body |> parse_refs() |> pick_ref(ref, address, opts)

          {:ok, %{status: status}} when status in [401, 404] ->
            {:error,
             refusal(
               :repo_not_found,
               address,
               opts,
               "names the repository #{Address.repo_slug(address)}, which GitHub does not show (#{status}); check the owner and name. Only public repositories can be fetched, and a private one looks the same."
             )}

          other ->
            {:error, fetch_failed(address, url, other, opts)}
        end
    end
  end

  @doc """
  Parses a smart-HTTP ref advertisement (pkt-lines) into `%{ref_name => sha}`. The service
  line, flush packets and capabilities (after a NUL) are dropped.
  """
  @spec parse_refs(binary()) :: %{optional(String.t()) => String.t()}
  def parse_refs(body), do: parse_pkts(body, %{})

  defp parse_pkts(<<"0000", rest::binary>>, acc), do: parse_pkts(rest, acc)

  defp parse_pkts(<<len_hex::binary-size(4), rest::binary>>, acc) do
    with {len, ""} when len > 4 <- Integer.parse(len_hex, 16),
         size = len - 4,
         <<line::binary-size(^size), rest::binary>> <- rest do
      line = line |> String.split(<<0>>, parts: 2) |> hd() |> String.trim_trailing("\n")

      case String.split(line, " ", parts: 2) do
        [sha, name] when byte_size(sha) == 40 -> parse_pkts(rest, Map.put(acc, name, sha))
        _ -> parse_pkts(rest, acc)
      end
    else
      _ -> acc
    end
  end

  defp parse_pkts(_, acc), do: acc

  defp pick_ref(refs, ref, address, opts) do
    peeled = refs["refs/tags/#{ref}^{}"]
    tag = refs["refs/tags/#{ref}"]
    branch = refs["refs/heads/#{ref}"]

    cond do
      tag && branch ->
        {:error,
         refusal(
           :ref_ambiguous,
           address,
           opts,
           "asks for #{ref}, which in #{Address.repo_slug(address)} is both a tag and a branch; pick one by its commit, or ask the publisher to rename one."
         )}

      tag ->
        {:ok, peeled || tag, :tag}

      branch ->
        {:ok, branch, :branch}

      true ->
        {:error,
         refusal(
           :ref_not_found,
           address,
           opts,
           "asks for #{ref}, which is no tag or branch of #{Address.repo_slug(address)}; check the ref (a commit must be written in full, 40 hex digits)."
         )}
    end
  end

  ## fetch

  @doc """
  Makes sure the repository of `address` at `sha` is in the cache, and returns
  `{:ok, dir}`. A cached commit makes no request.
  """
  @spec fetch(Address.t(), String.t(), keyword()) :: {:ok, Path.t()} | {:error, Refusal.t()}
  def fetch(%Address{} = address, sha, opts \\ []) do
    dest = cache_path(address, sha, opts)

    cond do
      File.dir?(dest) ->
        {:ok, dest}

      opts[:offline] ->
        {:error,
         refusal(
           :not_cached,
           address,
           opts,
           "is pinned to #{short(sha)}, which is not in the cache (#{dest}), and --offline forbids fetching it; run once without --offline."
         )}

      true ->
        download(address, sha, dest, opts)
    end
  end

  defp download(address, sha, dest, opts) do
    url = "#{opts[:codeload_url] || @codeload_url}/#{Address.repo_slug(address)}/tar.gz/#{sha}"

    case get(url, opts) do
      {:ok, %{status: 200, body: body}} when byte_size(body) > @max_archive ->
        {:error, too_large(address, byte_size(body), opts)}

      {:ok, %{status: 200, body: body}} ->
        with :ok <- check_archive(body, address, opts) do
          extract(body, address, dest, opts)
        end

      {:ok, %{status: 404}} ->
        {:error,
         refusal(
           :ref_not_found,
           address,
           opts,
           "is pinned to commit #{sha}, which #{Address.repo_slug(address)} does not have; check the commit."
         )}

      other ->
        {:error, fetch_failed(address, url, other, opts)}
    end
  end

  defp too_large(address, size, opts) do
    refusal(
      :archive_too_large,
      address,
      opts,
      "comes from #{Address.repo_slug(address)}, whose archive is #{div(size, 1024 * 1024)} MB; the most fetched is #{div(@max_archive, 1024 * 1024)} MB, so keep profiles in a small repository."
    )
  end

  @doc """
  Checks a `.tar.gz` before extracting it: one top-level folder; regular files and folders
  only (GitHub's `pax_global_header` is allowed and skipped); no absolute path and no `..`.
  Returns `:ok` or `{:error, refusal}`.
  """
  def check_archive(body, address, opts \\ []) do
    case :erl_tar.table({:binary, body}, [:compressed, :verbose]) do
      {:ok, entries} ->
        entries = Enum.reject(entries, &(elem(&1, 0) == ~c"pax_global_header"))

        bad =
          Enum.find_value(entries, fn entry ->
            name = entry |> elem(0) |> List.to_string()
            type = elem(entry, 1)
            parts = String.split(name, "/", trim: true)

            cond do
              String.starts_with?(name, "/") -> "the absolute path #{name}"
              ".." in parts -> "the path #{name}, which climbs out with .."
              type not in [:regular, :directory] -> "#{name}, a #{type} rather than a file"
              true -> nil
            end
          end)

        tops =
          entries
          |> Enum.map(&(&1 |> elem(0) |> List.to_string() |> String.split("/") |> hd()))
          |> Enum.uniq()

        cond do
          bad ->
            {:error, bad_archive(address, "holds #{bad}", opts)}

          length(tops) != 1 ->
            {:error,
             bad_archive(address, "has #{length(tops)} top-level entries instead of one", opts)}

          true ->
            :ok
        end

      {:error, reason} ->
        {:error, bad_archive(address, "could not be read (#{inspect(reason)})", opts)}
    end
  end

  defp bad_archive(address, what, opts) do
    refusal(
      :bad_archive,
      address,
      opts,
      "comes from #{Address.repo_slug(address)}, whose archive #{what}; nothing was extracted."
    )
  end

  defp extract(body, address, dest, opts) do
    parent = Path.dirname(dest)
    File.mkdir_p!(parent)
    tmp = Path.join(parent, ".tmp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    try do
      with :ok <-
             :erl_tar.extract({:binary, body}, [:compressed, {:cwd, String.to_charlist(tmp)}]),
           [top] <- File.ls!(tmp) do
        case File.rename(Path.join(tmp, top), dest) do
          :ok ->
            {:ok, dest}

          {:error, _} ->
            # Another run got there first; a commit's contents are the same either way.
            if File.dir?(dest),
              do: {:ok, dest},
              else: {:error, bad_archive(address, "could not be moved into #{dest}", opts)}
        end
      else
        {:error, reason} ->
          {:error, bad_archive(address, "could not be extracted (#{inspect(reason)})", opts)}

        _ ->
          {:error, bad_archive(address, "did not extract to one folder", opts)}
      end
    after
      File.rm_rf(tmp)
    end
  end

  ## helpers

  defp get(url, opts) do
    app = Application.get_env(:sprite_profiles, __MODULE__, [])[:req_options] || []

    [url: url, decode_body: false, retry: false, receive_timeout: 60_000]
    |> Keyword.merge(app)
    |> Keyword.merge(opts[:req_options] || [])
    |> Req.new()
    |> Req.request()
  end

  defp fetch_failed(address, url, result, opts) do
    why =
      case result do
        {:ok, %{status: status}} -> "answered #{status}"
        {:error, e} when is_exception(e) -> "failed: #{Exception.message(e)}"
        {:error, e} -> "failed: #{inspect(e)}"
      end

    refusal(
      :fetch_failed,
      address,
      opts,
      "could not be fetched: #{url} #{why}; try again, or check the network."
    )
  end

  defp refusal(code, address, opts, rest) do
    pick = opts[:pick] || Address.to_string(address)
    Refusal.new(code, [pick], "profile '#{pick}' #{rest}")
  end

  defp short(sha), do: String.slice(sha, 0, 8)
end
