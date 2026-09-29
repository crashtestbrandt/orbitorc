import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

config :orbitorc_web, OrbitorcWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :orbitorc_web, OrbitorcWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/orbitorc_web/router\.ex$",
        ~r"lib/orbitorc_web/(controllers|live|components)/.*\.(ex|heex)$"
      ]
    ]
end

# Agent tokens arrive as ORBITORC_AGENT_TOKENS, a comma-separated list of name=token pairs. One per
# box, so every action is attributable to a machine and one box can be revoked without rotating the
# fleet.
if tokens = System.get_env("ORBITORC_AGENT_TOKENS") do
  config :orbitorc_web,
    agent_tokens:
      tokens
      |> String.split(",", trim: true)
      |> Map.new(fn pair ->
        case String.split(pair, "=", parts: 2) do
          [name, token] ->
            {String.trim(name), String.trim(token)}

          [name] ->
            raise "ORBITORC_AGENT_TOKENS entry #{inspect(name)} has no token; use name=token"
        end
      end)
end

# The prod block below configures the CONTROL PLANE: a database path and a secret key. The agent
# release carries neither a database nor an endpoint, and a box must not fail to start for want of a
# secret it has no use for -- so the block runs only for the control plane's release (or outside a
# release entirely, as `mix phx.server` does).
control_plane? = System.get_env("RELEASE_NAME") in [nil, "orbitorc"]

if config_env() == :prod and control_plane? do
  # A release serves HTTP by itself; there is no `mix phx.server` in front of it to say so.
  config :orbitorc_web, OrbitorcWeb.Endpoint, server: true

  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/orbitorc/orbitorc.db
      """

  config :orbitorc, Orbitorc.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  config :orbitorc_web, OrbitorcWeb.Endpoint,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## Using releases
  #
  # If you are doing OTP releases, you need to instruct Phoenix
  # to start each relevant endpoint:
  #
  #     config :orbitorc_web, OrbitorcWeb.Endpoint, server: true
  #
  # Then you can assemble a release by calling `mix release`.
  # See `mix help release` for more information.

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :orbitorc_web, OrbitorcWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :orbitorc_web, OrbitorcWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  config :orbitorc, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
end
