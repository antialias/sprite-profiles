defmodule SpriteProfiles.Refusal do
  @moduledoc """
  Why a set of profiles will not be merged or launched: a stable `code` and a full sentence
  that names the profiles involved and says what to change.

  A profile that fails validation is reported with its own `SpriteProfiles.Profile.Error`
  codes instead.

  Codes: `no_profiles`, `too_many_profiles`, `duplicate_pick`, `bad_name`, `profile_not_found`,
  `env_collision`, `service_collision`, `http_port_conflict`,
  `mcp_server_collision`, `mcp_needs_login`, `settings_collision`, `file_collision`,
  `connector_missing`, `not_for_agents`; at launch also `secret_missing` and `bad_sprite_name`.
  """

  @enforce_keys [:code, :message]
  defstruct [:code, :message, profiles: []]

  @type t :: %__MODULE__{code: atom(), message: String.t(), profiles: [String.t()]}

  @doc false
  def new(code, profiles, message),
    do: %__MODULE__{code: code, profiles: profiles, message: message}
end
