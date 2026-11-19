defmodule SpriteProfiles.Host do
  @moduledoc """
  Where a name's refs and files come from, by host. Name resolution
  (`SpriteProfiles.Names`) and the fetch of a name's commit (`SpriteProfiles.Resolver`) go
  through here, so another host plugs in at these three functions.

  Only GitHub is served so far, through `SpriteProfiles.GitHub`: refs from `info/refs`,
  single files from `raw.githubusercontent.com`, a commit from the codeload tarball. A
  name on another host is refused before it gets here (`host_not_supported`).
  """

  alias SpriteProfiles.{Address, GitHub, Refusal}

  @github "github.com"

  @doc """
  Every ref of `owner/repo` on `host`, with `"HEAD"` for the default branch:
  `{:ok, %{ref_name => sha}}`, `{:error, :not_found, status}`, or `{:error, refusal}`.
  """
  @spec refs(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{optional(String.t()) => String.t()}}
          | {:error, :not_found, integer()}
          | {:error, Refusal.t()}
  def refs(@github, owner, repo, opts), do: GitHub.refs(owner, repo, opts)

  @doc """
  One file of `owner/repo` on `host` at commit `sha`: `{:ok, text}`, `:missing`, or
  `{:error, refusal}`.
  """
  @spec read_file(String.t(), String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, binary()} | :missing | {:error, Refusal.t()}
  def read_file(@github, owner, repo, sha, path, opts),
    do: GitHub.read_file(owner, repo, sha, path, opts)

  @doc "Makes sure the repository at `sha` is in the cache: `{:ok, dir}` or `{:error, refusal}`."
  @spec fetch(String.t(), Address.t(), String.t(), keyword()) ::
          {:ok, Path.t()} | {:error, Refusal.t()}
  def fetch(@github, %Address{} = address, sha, opts), do: GitHub.fetch(address, sha, opts)
end
