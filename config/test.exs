import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :sprite_profiles, SpriteProfilesWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "IoXguqrnEmAXlvbj3KC852DamGF03ob3+Amq0bPEMneoXo+7mbPhvYncJT09ndh/",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Profiles by address: every GitHub request in a test goes to a Req.Test stub, never out.
config :sprite_profiles, SpriteProfiles.GitHub,
  req_options: [plug: {Req.Test, SpriteProfiles.GitHub}]

# Git hosts: no test reaches a real one. GitHub's git fallback (a private repository) and
# the example host go to folders that do not exist unless a test points them elsewhere.
config :sprite_profiles, :git_hosts, %{
  "github.com" => "file:///nonexistent/sprite-profiles-test/github.com",
  "git.example.com" => "file:///nonexistent/sprite-profiles-test/git.example.com"
}
