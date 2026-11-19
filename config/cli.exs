import Config

# Runtime configuration of the `sprite-profiles` release (mix.exs, `releases/0`): the
# command-line tool. It replaces config/runtime.exs, which configures the web endpoint.
config :sprite_profiles, cli: true

config :logger, level: :warning
