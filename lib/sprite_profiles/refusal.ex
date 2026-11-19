defmodule SpriteProfiles.Refusal do
  @moduledoc """
  Why a set of profiles will not be merged or launched: a stable `code` and a full sentence
  that names the profiles involved and says what to change.

  A profile that fails validation is reported with its own `SpriteProfiles.Profile.Error`
  codes instead.

  A fetched profile is named by its pick as written (`acme/profiles/linear@v1`,
  `@acme/linear@1`).

  Codes: `no_profiles`, `too_many_profiles`, `duplicate_pick`, `bad_name`, `bad_address`,
  `address_needs_ref`, `host_not_supported`, `profile_not_found`, `profile_ambiguous`,
  `profile_dir_missing`; names `name_not_found`, `name_ambiguous`, `bad_links`,
  `no_versions`, `version_not_found`; fetching `repo_not_found`, `ref_not_found`, `ref_ambiguous`, `fetch_failed`, `not_cached`,
  `archive_too_large`, `bad_archive`; `bad_lock`; `profile_collision`, `label_too_long`,
  `env_collision`, `service_collision`, `http_port_conflict`,
  `mcp_server_collision`, `mcp_needs_login`, `settings_collision`, `file_collision`,
  `connector_missing`, `not_for_agents`; inputs `input_collision`, `input_missing`,
  `input_invalid`, `input_unknown`; at launch also `secret_missing`, `bad_sprite_name`,
  `connector_not_admitted`, `connector_endpoints` and `connector_base_url`; from
  `mix profiles.connect`, `no_custom_connector` and `needs_terminal`.
  """

  @enforce_keys [:code, :message]
  defstruct [:code, :message, profiles: []]

  @type t :: %__MODULE__{code: atom(), message: String.t(), profiles: [String.t()]}

  @doc false
  def new(code, profiles, message),
    do: %__MODULE__{code: code, profiles: profiles, message: message}
end
