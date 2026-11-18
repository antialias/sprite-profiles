defmodule SpriteProfiles.Profile.Error do
  @moduledoc """
  A validation error in one profile: a stable `code` for programs and a full-sentence
  `message` for people.

  Codes: `missing_profile_toml`, `bad_toml`, `missing_field`, `unknown_field`, `bad_field`,
  `bad_name`, `name_mismatch`, `secret_needs_privileged`, `privileged_checkpoint`,
  `env_connector_undeclared`, `reserved_env`, `reserved_label`, `duplicate_service`,
  `http_port_conflict`, `bad_skill`, `bad_file`, `unknown_entry`.
  """

  @enforce_keys [:code, :profile, :message]
  defstruct [:code, :profile, :message]

  @type t :: %__MODULE__{code: atom(), profile: String.t(), message: String.t()}

  @doc false
  def new(code, profile, message), do: %__MODULE__{code: code, profile: profile, message: message}
end
