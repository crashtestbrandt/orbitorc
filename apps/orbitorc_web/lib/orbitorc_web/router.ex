defmodule OrbitorcWeb.Router do
  use OrbitorcWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {OrbitorcWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", OrbitorcWeb do
    pipe_through :browser

    live "/", FleetLive, :index
    live "/box/:name", BoxLive, :show
    live "/runs", RunsLive, :index
    live "/run/:id", RunLive, :show
  end

  # Read verbs are GET; anything that changes a box is POST. That split is not decoration — it keeps a
  # mutation out of a link, a browser prefetch and a shell history.
  scope "/api", OrbitorcWeb do
    pipe_through :api

    get "/fleet", ApiController, :fleet
    get "/box/:box/doctor", ApiController, :doctor
    get "/box/:box/status", ApiController, :status
    get "/box/:box/jobs/:id/logs", ApiController, :logs
    get "/box/:box/jobs/:id/pull", ApiController, :pull
    get "/box/:box/jobs/:id/verdict", ApiController, :verdict
    get "/run/:id", ApiController, :run_status
    get "/runs", ApiController, :runs

    post "/box/:box/lease", ApiController, :lease
    post "/box/:box/launch", ApiController, :launch

    # A dry run changes nothing on the box; it is POST only because it carries the same body a launch does.
    post "/box/:box/dry-run", ApiController, :dry_run
    post "/box/:box/stop", ApiController, :stop
    post "/box/:box/build", ApiController, :build
    post "/box/:box/jobs/:id/shot", ApiController, :shot
    post "/sync", ApiController, :sync
    post "/run", ApiController, :run
  end

  if Application.compile_env(:orbitorc_web, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: OrbitorcWeb.Telemetry
    end
  end
end
