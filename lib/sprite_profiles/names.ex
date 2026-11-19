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

  On GitHub `NS` is one owner; on another host (`@HOST/NS/NAME`) it may be several
  segments, a GitLab group and its subgroups. Every repository looked in is on the pick's
  host, in the same namespace.

  Resolution reads refs and single files only, never the hosting API and never an
  archive; `SpriteProfiles.Host` says where they come from (on GitHub, `info/refs` and
  `raw.githubusercontent.com`, or git for a private repository; elsewhere, git).
  """

  alias SpriteProfiles.{Address, GitHub, Host, Pick, Refusal}

  @github "github.com"

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
  `SpriteProfiles.GitHub`'s and `SpriteProfiles.Git`'s; `:offline` refuses at once
  (`not_cached`).
  """
  @spec resolve(Pick.t(), String.t(), keyword()) :: {:ok, resolved()} | {:error, Refusal.t()}
  def resolve(%Pick{} = p, pick, opts \\ []) do
    opts = Keyword.put(opts, :pick, pick)

    cond do
      opts[:offline] ->
        {:error,
         refusal(
           :not_cached,
           pick,
           "is a name, and --offline forbids looking it up; lock the set first (mix profiles.lock) and plan from the lock."
         )}

      true ->
        ns = Pick.ns(p)

        case Host.remote(p.host, ns, own_repo(p.name), opts) do
          {:ok, %{refs: refs}} ->
            where = %{owner: ns, repo: own_repo(p.name), path: ""}
            choose(p, refs, versions(refs, ""), where, "tag vX.Y.Z", opts)

          {:error, :not_found, _} ->
            in_collection(p, ns, opts)

          {:error, %Refusal{} = r} ->
            {:error, r}
        end
    end
  end

  ## the collection

  defp in_collection(p, ns, opts) do
    case Host.remote(p.host, ns, @collection, opts) do
      {:error, :not_found, _} ->
        {:error, not_found(p, ns, opts[:pick], false)}

      {:error, %Refusal{} = r} ->
        {:error, r}

      {:ok, %{refs: refs} = remote} ->
        head = refs["HEAD"]

        with {:ok, folders} <- folders(p, remote, head, opts) do
          case folders do
            [a, b] ->
              by_address =
                Address.to_string(%Address{
                  host: p.host,
                  owner: ns,
                  repo: @collection,
                  path: a,
                  ref: "REF"
                })

              {:error,
               refusal(
                 :name_ambiguous,
                 opts[:pick],
                 "is in two folders of #{slug(p, ns, @collection)}, #{a}/ and #{b}/, and a name must find one; ask the publisher to remove one, or pick it by address (#{by_address})."
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
              linked(p, remote, head, opts)
          end
        end
    end
  end

  # A folder is the collection's when it has version tags, or holds a profile.toml at the
  # default branch. The files are read together: on git, that is one fetch.
  defp folders(p, remote, head, opts) do
    candidates = [p.name, "profiles/#{p.name}"]
    tagged = Enum.filter(candidates, &(versions(remote.refs, &1 <> "/") != []))
    to_read = if head, do: Enum.map(candidates -- tagged, &(&1 <> "/profile.toml")), else: []

    read =
      if to_read == [],
        do: {:ok, %{}},
        else: Host.read_files(remote, head, to_read, opts)

    with {:ok, files} <- read do
      {:ok,
       Enum.filter(candidates, fn folder ->
         folder in tagged or match?({:ok, _}, files[folder <> "/profile.toml"])
       end)}
    end
  end

  ## links.toml

  defp linked(p, remote, head, opts) do
    ns = remote.ns

    text =
      if head do
        with {:ok, files} <- Host.read_files(remote, head, ["links.toml"], opts),
             do: files["links.toml"]
      else
        :missing
      end

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
           "is looked up in #{slug(p, ns, @collection)}'s links.toml, which is not valid TOML (#{Exception.message(e)}); ask the publisher to fix it."
         )}
    end
  end

  defp good_segment?(s), do: s not in ["", ".", ".."] and Regex.match?(~r/^[A-Za-z0-9._-]+$/, s)

  defp bad_link(p, ns, target, opts) do
    refusal(
      :bad_links,
      opts[:pick],
      "is pointed by #{slug(p, ns, @collection)}'s links.toml at #{target}, which is not REPO/path ending in the folder #{p.name}; ask the publisher to fix it."
    )
  end

  defp follow(p, ns, {repo, path}, opts) do
    case Host.remote(p.host, ns, String.downcase(repo), opts) do
      {:ok, %{refs: refs}} ->
        where = %{owner: ns, repo: String.downcase(repo), path: path}
        choose(p, refs, versions(refs, path <> "/"), where, "tag #{path}/vX.Y.Z", opts)

      {:error, :not_found, why} ->
        address = %Address{host: p.host, owner: ns, repo: repo, path: path, ref: ""}
        {:error, Host.repo_not_found(address, why, opts)}

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
    at = fn ref ->
      %Address{host: p.host, owner: where.owner, repo: where.repo, path: where.path, ref: ref}
    end

    found = fn ref, sha, kind, version ->
      {:ok,
       %{
         host: p.host,
         address: at.(ref),
         sha: sha,
         kind: kind,
         version: version
       }}
    end

    slug = slug(p, where.owner, where.repo)

    case {p.version, list} do
      {{:ref, ref}, _} ->
        with {:ok, sha, kind} <- GitHub.find_ref(refs, ref, at.(ref), opts),
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
    own = slug(p, ns, own_repo(p.name))
    coll = slug(p, ns, @collection)

    looked =
      if collection?,
        do:
          "no repository #{own}, no folder #{p.name}/ or profiles/#{p.name}/ in #{coll}, and no #{p.name} in its links.toml",
        else: "no repository #{own} and no collection #{coll}"

    who = if p.host == @github, do: "GitHub shows", else: "#{p.host} has"

    refusal(
      :name_not_found,
      pick,
      "is not published: #{who} #{looked}; check the spelling. A private repository is found through git's own credentials for #{p.host} (a credential helper): sprite-profiles never asks for them."
    )
  end

  # A repository as sentences name it: `ns/repo` on GitHub, `host/ns/repo` elsewhere.
  defp slug(%Pick{host: @github}, ns, repo), do: "#{ns}/#{repo}"
  defp slug(%Pick{host: host}, ns, repo), do: "#{host}/#{ns}/#{repo}"

  defp refusal(code, pick, rest), do: Refusal.new(code, [pick], "profile '#{pick}' #{rest}")
end
