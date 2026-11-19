defmodule SpriteProfiles.Names do
  @moduledoc """
  Finds where a name pick (`@NS/NAME[@V]`) is published, and which commit its version is.
  Nothing is hosted: a published profile is a repository that follows a convention, and
  versions are its tags. For `@NS/NAME`, the first match wins:

    1. **its own repository**, `NS/sprite-profile-NAME`, with `profile.toml` at the root;
       versions are tags `vX.Y.Z`;
    2. **the owner's collection**, `NS/sprite-profiles`, with the profile in folder `NAME/`
       or `profiles/NAME/`; versions are tags `<folder>/vX.Y.Z`, or the collection's own
       `vX.Y.Z` when the folder has none. Both folders is `name_ambiguous`;
    3. **a pointer** in the collection's `links.toml`, read at its default branch:
       `NAME = "REPO/path"`, a folder in another repository of the same owner; versions are
       tags `<path>/vX.Y.Z` there, never its plain `v` tags.

  Nothing matching is `name_not_found`. A folder of the collection is its when, at the
  default branch, it holds a `profile.toml`, or when it has version tags.

  The version: `@1`, `@1.2` and `@1.2.3` are prefixes, choosing the newest matching
  version, pre-releases ignored (`version_not_found`); anything else after `@` is a ref (a
  branch, a tag or a 40-hex commit); no `@` is the newest version (`no_versions` when
  there is none).

  Resolution reads refs and single files only, never the hosting API and never an
  archive; `SpriteProfiles.Host` says where they come from.
  """

  alias SpriteProfiles.{Address, GitHub, Host, Pick, Refusal}

  @collection "sprite-profiles"

  @typedoc """
  Where a name resolved to: the address it stands for (`ref` is the tag of the version,
  or the ref as picked), the commit, how the ref resolved, and the version (nil for a ref
  pick).
  """
  @type resolved :: %{
          host: String.t(),
          address: Address.t(),
          sha: String.t(),
          kind: :tag | :branch | :commit,
          version: String.t() | nil
        }

  @doc "The repository a profile of its own lives in: `sprite-profile-NAME`."
  def own_repo(name), do: "sprite-profile-#{name}"

  @doc "The owner's collection repository: `sprite-profiles`."
  def collection, do: @collection

  @doc """
  Resolves a parsed name pick. `pick` is the pick as written, for sentences. Options are
  `SpriteProfiles.GitHub`'s; `:offline` refuses at once (`not_cached`).
  """
  @spec resolve(Pick.t(), String.t(), keyword()) :: {:ok, resolved()} | {:error, Refusal.t()}
  def resolve(%Pick{} = p, pick, opts \\ []) do
    opts = Keyword.put(opts, :pick, pick)

    cond do
      not Pick.supported?(p) ->
        {:error, host_not_supported(p, pick)}

      opts[:offline] ->
        {:error,
         refusal(
           :not_cached,
           pick,
           "is a name, and --offline forbids looking it up; lock the set first (mix profiles.lock) and plan from the lock."
         )}

      true ->
        # On GitHub the namespace is one owner.
        [ns] = p.ns

        case Host.refs(p.host, ns, own_repo(p.name), opts) do
          {:ok, refs} ->
            where = %{owner: ns, repo: own_repo(p.name), path: ""}
            choose(p, refs, versions(refs, ""), where, "tag vX.Y.Z", opts)

          {:error, :not_found, _} ->
            in_collection(p, ns, opts)

          {:error, %Refusal{} = r} ->
            {:error, r}
        end
    end
  end

  @doc "The refusal for a name on a host this version cannot fetch from."
  def host_not_supported(%Pick{host: host}, pick) do
    refusal(
      :host_not_supported,
      pick,
      "is on #{host}, and only names on GitHub can be resolved so far; pick it by address once other hosts are supported, or publish it on GitHub."
    )
  end

  ## the collection

  defp in_collection(p, ns, opts) do
    case Host.refs(p.host, ns, @collection, opts) do
      {:error, :not_found, _} ->
        {:error, not_found(p, ns, opts[:pick], false)}

      {:error, %Refusal{} = r} ->
        {:error, r}

      {:ok, refs} ->
        head = refs["HEAD"]

        with {:ok, folders} <- folders(p, ns, refs, head, opts) do
          case folders do
            [a, b] ->
              {:error,
               refusal(
                 :name_ambiguous,
                 opts[:pick],
                 "is in two folders of #{ns}/#{@collection}, #{a}/ and #{b}/, and a name must find one; ask the publisher to remove one, or pick it by address (#{ns}/#{@collection}/#{a}@REF)."
               )}

            [folder] ->
              where = %{owner: ns, repo: @collection, path: folder}

              {list, what} =
                case versions(refs, folder <> "/") do
                  [] -> {versions(refs, ""), "tag #{folder}/vX.Y.Z or vX.Y.Z"}
                  tagged -> {tagged, "tag #{folder}/vX.Y.Z"}
                end

              choose(p, refs, list, where, what, opts)

            [] ->
              linked(p, ns, head, opts)
          end
        end
    end
  end

  defp folders(p, ns, refs, head, opts) do
    Enum.reduce_while([p.name, "profiles/#{p.name}"], {:ok, []}, fn folder, {:ok, acc} ->
      cond do
        versions(refs, folder <> "/") != [] ->
          {:cont, {:ok, acc ++ [folder]}}

        head == nil ->
          {:cont, {:ok, acc}}

        true ->
          case Host.read_file(p.host, ns, @collection, head, folder <> "/profile.toml", opts) do
            {:ok, _} -> {:cont, {:ok, acc ++ [folder]}}
            :missing -> {:cont, {:ok, acc}}
            {:error, r} -> {:halt, {:error, r}}
          end
      end
    end)
  end

  ## links.toml

  defp linked(p, ns, head, opts) do
    text =
      if head,
        do: Host.read_file(p.host, ns, @collection, head, "links.toml", opts),
        else: :missing

    with {:ok, text} <- text,
         {:ok, target} <- link(text, p, ns, opts) do
      follow(p, ns, target, opts)
    else
      :missing -> {:error, not_found(p, ns, opts[:pick], true)}
      {:none} -> {:error, not_found(p, ns, opts[:pick], true)}
      {:error, %Refusal{} = r} -> {:error, r}
    end
  end

  defp link(text, p, ns, opts) do
    case TomlElixir.decode(text, spec: :"1.0.0") do
      {:ok, map} ->
        case map[p.name] do
          nil ->
            {:none}

          target when is_binary(target) ->
            case String.split(target, "/") do
              [repo | [_ | _] = path] ->
                if Enum.all?([repo | path], &good_segment?/1) and List.last(path) == p.name,
                  do: {:ok, {repo, Enum.join(path, "/")}},
                  else: {:error, bad_link(p, ns, target, opts)}

              _ ->
                {:error, bad_link(p, ns, target, opts)}
            end

          other ->
            {:error, bad_link(p, ns, inspect(other), opts)}
        end

      {:error, e} ->
        {:error,
         refusal(
           :bad_links,
           opts[:pick],
           "is looked up in #{ns}/#{@collection}'s links.toml, which is not valid TOML (#{Exception.message(e)}); ask the publisher to fix it."
         )}
    end
  end

  defp good_segment?(s), do: s not in ["", ".", ".."] and Regex.match?(~r/^[A-Za-z0-9._-]+$/, s)

  defp bad_link(p, ns, target, opts) do
    refusal(
      :bad_links,
      opts[:pick],
      "is pointed by #{ns}/#{@collection}'s links.toml at #{target}, which is not REPO/path ending in the folder #{p.name}; ask the publisher to fix it."
    )
  end

  defp follow(p, ns, {repo, path}, opts) do
    case Host.refs(p.host, ns, repo, opts) do
      {:ok, refs} ->
        where = %{owner: ns, repo: String.downcase(repo), path: path}
        choose(p, refs, versions(refs, path <> "/"), where, "tag #{path}/vX.Y.Z", opts)

      {:error, :not_found, status} ->
        address = %Address{owner: ns, repo: repo, path: path, ref: ""}
        {:error, GitHub.repo_not_found(address, status, opts)}

      {:error, %Refusal{} = r} ->
        {:error, r}
    end
  end

  ## versions

  @doc """
  The versions in `refs` tagged `<prefix>vX.Y.Z` (pre-releases ignored), newest first, each
  `%{version: "1.2.3", parts: [1, 2, 3], tag: tag, sha: commit}`; an annotated tag gives
  the commit it points at.
  """
  def versions(refs, prefix) do
    for {"refs/tags/" <> tag, sha} <- refs,
        not String.ends_with?(tag, "^{}"),
        String.starts_with?(tag, prefix <> "v"),
        version <- [String.replace_prefix(tag, prefix <> "v", "")],
        {:ok, parts} <- [Pick.semver(version)] do
      %{version: version, parts: parts, tag: tag, sha: refs["refs/tags/#{tag}^{}"] || sha}
    end
    |> Enum.sort_by(& &1.parts, :desc)
  end

  defp choose(p, refs, list, where, what, opts) do
    found = fn ref, sha, kind, version ->
      {:ok,
       %{
         host: p.host,
         address: %Address{owner: where.owner, repo: where.repo, path: where.path, ref: ref},
         sha: sha,
         kind: kind,
         version: version
       }}
    end

    slug = "#{where.owner}/#{where.repo}"

    case {p.version, list} do
      {{:ref, ref}, _} ->
        address = %Address{owner: where.owner, repo: where.repo, path: where.path, ref: ref}

        with {:ok, sha, kind} <- GitHub.find_ref(refs, ref, address, opts),
             do: found.(ref, sha, kind, nil)

      {nil, []} ->
        {:error,
         refusal(
           :no_versions,
           opts[:pick],
           "has no version: #{slug} has no #{what}; while it is in development, pick a branch, like #{Pick.base(p)}@main."
         )}

      {nil, [v | _]} ->
        found.(v.tag, v.sha, :tag, v.version)

      {{:prefix, prefix}, _} ->
        case Enum.find(list, &(Enum.take(&1.parts, length(prefix)) == prefix)) do
          nil ->
            {:error, version_not_found(p, slug, list, what, prefix, opts)}

          v ->
            found.(v.tag, v.sha, :tag, v.version)
        end
    end
  end

  defp version_not_found(p, slug, list, what, prefix, opts) do
    asked = Enum.join(prefix, ".")

    has =
      case Enum.map(list, & &1.version) do
        [] -> "#{slug} has no #{what} at all; pick a branch, like #{Pick.base(p)}@main"
        vs -> "#{slug} has #{Enum.join(Enum.take(vs, 5), ", ")}; pick one of those"
      end

    refusal(:version_not_found, opts[:pick], "asks for version #{asked}, and #{has}.")
  end

  defp not_found(p, ns, pick, collection?) do
    looked =
      if collection?,
        do:
          "no repository #{ns}/#{own_repo(p.name)}, no folder #{p.name}/ or profiles/#{p.name}/ in #{ns}/#{@collection}, and no #{p.name} in its links.toml",
        else: "no repository #{ns}/#{own_repo(p.name)} and no collection #{ns}/#{@collection}"

    refusal(
      :name_not_found,
      pick,
      "is not published: GitHub shows #{looked}; check the spelling. Only public repositories can be found."
    )
  end

  defp refusal(code, pick, rest), do: Refusal.new(code, [pick], "profile '#{pick}' #{rest}")
end
