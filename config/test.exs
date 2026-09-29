import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :orbitorc, Orbitorc.Repo,
  database: Path.expand("../orbitorc_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :orbitorc_web, OrbitorcWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "rYSWQiCIBIee6xmP8PsuUivNby7hNvwwfKRmVy7Vwgo9T2ATEKBjuvjrT21SRBhJ",
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

# A fixed token for the channel tests. Nothing real is reachable in the test environment.
config :orbitorc_web, agent_tokens: %{"testbox" => "test-token"}

# The agent starts idle under test. Every test that needs a job registry starts its own.
config :orbitorc_agent, autostart: false
