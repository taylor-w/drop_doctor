defmodule DropDoctorWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use DropDoctorWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8">
      <div class="flex-1"></div>
      <div class="flex-none flex items-center gap-2">
        <.tour_button />
        <.view_controls />
        <.theme_menu />
      </div>
    </header>

    <main class="px-4 py-6 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-6xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} autohide />
      <.flash kind={:error} flash={@flash} autohide />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  The "take a tour" trigger: a single icon button that opens the in-app guided
  walkthrough. Like the privacy/theme controls, the tour is a purely client-side
  affordance — clicking this button is picked up by event delegation in
  `assets/js/tour.js` (via the `data-tour-start` hook), so it survives LiveView
  patches and never round-trips to the server. The walkthrough's steps anchor to
  the `data-tour="<key>"` markers placed on the live dashboard elements.
  """
  def tour_button(assigns) do
    ~H"""
    <button
      type="button"
      class="tc-seg-btn"
      data-tour-start
      aria-label="Take a guided tour of DropDoctor"
      title="Take a guided tour"
    >
      <%!-- Lucide "compass" (inlined; the app ships Heroicons, no Lucide dep). --%>
      <svg
        class="size-4"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
        aria-hidden="true"
        focusable="false"
      >
        <path d="m16.24 7.76-1.804 5.411a2 2 0 0 1-1.265 1.265L7.76 16.24l1.804-5.411a2 2 0 0 1 1.265-1.265z" />
        <circle cx="12" cy="12" r="10" />
      </svg>
    </button>
    """
  end

  @doc """
  Stream-safe privacy control + timezone toggle. State lives in a `data-privacy`
  / `data-tz` attribute on `<html>` (managed by the inline script in root.html),
  so it persists, applies before paint, and is never re-rendered by LiveView.
  """
  def view_controls(assigns) do
    ~H"""
    <div
      class="tc-seg"
      role="group"
      aria-label="Stream-safe privacy"
      data-tour="privacy"
      title="Stream-safe: hide IPs, hostnames & times so you can screen-share. Blur = hover to peek; lock = fully redact."
    >
      <button
        type="button"
        data-privacy-set="off"
        title="Show all values"
        aria-label="Show all values"
      >
        <.icon name="hero-eye-micro" class="size-4" />
      </button>
      <button
        type="button"
        data-privacy-set="blur"
        title="Stream-safe: blur IPs, hostnames & times (hover to peek)"
        aria-label="Stream-safe: blur IPs, hostnames and times (hover to peek)"
      >
        <.icon name="hero-eye-slash-micro" class="size-4" />
      </button>
      <button
        type="button"
        data-privacy-set="strict"
        title="Strict: redact IPs, hostnames & times (no peek)"
        aria-label="Strict: redact IPs, hostnames and times (no peek)"
      >
        <.icon name="hero-lock-closed-micro" class="size-4" />
      </button>
    </div>
    <button
      type="button"
      class="tc-seg-btn"
      data-tz-toggle
      title="Switch displayed times between your local time and UTC"
    >
      <.icon name="hero-clock-micro" class="size-4" />
      <span class="tc-tz-local">Local</span><span class="tc-tz-utc">UTC</span>
    </button>
    """
  end

  @doc """
  The color-theme picker: a native `<details>` disclosure with two independent
  controls — a system / light / dark **mode** segment and a grid of **colorways**
  (incl. the brand "Default"). Mode and colorway compose: pick Winter, then Dark,
  and the page becomes `winter-dark`.

  Mode buttons dispatch `phx:set-theme`; colorway swatches dispatch
  `phx:set-colorway`. Both are handled by the inline script in root.html.heex,
  which persists each to its own `localStorage` key and resolves the combined
  `<html data-theme>` before paint (never re-rendered by LiveView, so it can't
  flicker on a sweep update). The exported report reads the same keys and follows
  along. The mode pill and the active-swatch ring are pure CSS off the
  `data-mode` / `data-colorway` attributes the script mirrors onto `<html>`.
  """
  def theme_menu(assigns) do
    assigns = assign(assigns, :colorways, DropDoctor.Themes.colorways())

    ~H"""
    <details class="dropdown dropdown-end" id="theme-menu">
      <summary
        class="tc-seg-btn list-none [&::-webkit-details-marker]:hidden"
        aria-label="Choose a color theme"
        data-tour="theme"
        title="Choose a color theme"
      >
        <%!-- Lucide "palette" (inlined; the app ships Heroicons, no Lucide dep). --%>
        <svg
          class="size-4"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
          focusable="false"
        >
          <path d="M12 22a1 1 0 0 1 0-20 10 9 0 0 1 10 9 5 5 0 0 1-5 5h-2.25a1.75 1.75 0 0 0-1.4 2.8l.3.4a1.75 1.75 0 0 1-1.4 2.8z" />
          <circle cx="13.5" cy="6.5" r=".5" fill="currentColor" />
          <circle cx="17.5" cy="10.5" r=".5" fill="currentColor" />
          <circle cx="6.5" cy="12.5" r=".5" fill="currentColor" />
          <circle cx="8.5" cy="7.5" r=".5" fill="currentColor" />
        </svg>
      </summary>

      <div class="dropdown-content tc-panel z-50 mt-2 w-72 rounded-box border border-base-300 bg-base-200 p-3 shadow-lg">
        <p class="mb-2 text-xs font-semibold uppercase tracking-wide opacity-60">Mode</p>

        <div
          class="card relative flex w-full flex-row items-center rounded-full border-2 border-base-300 bg-base-300"
          role="group"
          aria-label="Light or dark mode"
        >
          <div class="tc-mode-pill absolute left-0 h-full w-1/3 translate-x-0 rounded-full border-1 border-base-200 bg-base-100 brightness-200 transition-transform [[data-mode=light]_&]:translate-x-full [[data-mode=dark]_&]:translate-x-[200%]" />
          <button
            type="button"
            class="flex w-1/3 cursor-pointer justify-center p-2"
            phx-click={pick("phx:set-theme")}
            data-phx-theme="system"
            aria-label="Match system mode"
            title="Match system mode"
          >
            <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
          </button>
          <button
            type="button"
            class="flex w-1/3 cursor-pointer justify-center p-2"
            phx-click={pick("phx:set-theme")}
            data-phx-theme="light"
            aria-label="Light mode"
            title="Light mode"
          >
            <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
          </button>
          <button
            type="button"
            class="flex w-1/3 cursor-pointer justify-center p-2"
            phx-click={pick("phx:set-theme")}
            data-phx-theme="dark"
            aria-label="Dark mode"
            title="Dark mode"
          >
            <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
          </button>
        </div>

        <p class="mt-3 mb-2 text-xs font-semibold uppercase tracking-wide opacity-60">Colorway</p>
        <div class="grid grid-cols-2 gap-2">
          <button
            type="button"
            class="tc-swatch"
            phx-click={pick("phx:set-colorway")}
            data-colorway="default"
            aria-label="Default colorway"
            title="Default"
          >
            <span class="tc-swatch-colors" data-theme="light" aria-hidden="true">
              <span class="bg-base-100"></span>
              <span class="bg-primary"></span>
              <span class="bg-secondary"></span>
              <span class="bg-accent"></span>
            </span>
            <span class="tc-swatch-label">Default</span>
          </button>
          <button
            :for={cw <- @colorways}
            type="button"
            class="tc-swatch"
            phx-click={pick("phx:set-colorway")}
            data-colorway={cw.name}
            aria-label={cw.label <> " colorway"}
            title={cw.label}
          >
            <span class="tc-swatch-colors" data-theme={cw.name <> "-light"} aria-hidden="true">
              <span class="bg-base-100"></span>
              <span class="bg-primary"></span>
              <span class="bg-secondary"></span>
              <span class="bg-accent"></span>
            </span>
            <span class="tc-swatch-label">{cw.label}</span>
          </button>
        </div>
      </div>
    </details>
    """
  end

  # Dispatch the clicked option's set-theme/set-colorway event (the handler reads
  # the bound button's data-* attribute). The picker stays open on purpose so you
  # can try modes/colorways one after another; it closes only on a click outside
  # it or on another control (see the click-away handler in assets/js/app.js).
  defp pick(event, js \\ %JS{}) do
    JS.dispatch(js, event)
  end
end
