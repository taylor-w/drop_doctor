defmodule DropDoctorWeb.Router do
  use DropDoctorWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DropDoctorWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Server-Sent Events feed for the live report. Deliberately *not* the :browser
  # pipeline: an EventSource sends `Accept: text/event-stream`, which an
  # html-only `:accepts` negotiation would reject with 406. We still send the
  # same security headers the rest of the app does.
  pipeline :sse do
    plug :put_secure_browser_headers
  end

  scope "/", DropDoctorWeb do
    pipe_through :browser

    live "/", DashboardLive

    get "/report", ReportController, :show
    get "/report.csv", ReportController, :csv
    get "/spikes.csv", ReportController, :spikes_csv
    get "/speeds.csv", ReportController, :speeds_csv
  end

  scope "/", DropDoctorWeb do
    pipe_through :sse

    get "/report/live", ReportController, :live
  end

  # Other scopes may use custom stacks.
  # scope "/api", DropDoctorWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:drop_doctor, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DropDoctorWeb.Telemetry
    end
  end
end
