defmodule DropDoctor.Themes do
  @moduledoc """
  Canonical list of selectable **colorways**, the single source of truth shared
  by the dashboard picker (`DropDoctorWeb.Layouts`) and the exported report
  (`DropDoctor.Report`).

  Theming has two independent dimensions:

    * **mode** — light / dark / system (stored in `localStorage["phx:theme"]`)
    * **colorway** — the palette identity (stored in `localStorage["tc:colorway"]`)

  The applied `data-theme` is the *combination*: a colorway named `winter` in
  dark mode resolves to `data-theme="winter-dark"`. The brand "default" colorway
  has no prefix — it stays the crafted `light` / `dark` themes.

  Each colorway therefore has a **light and a dark variant** authored in
  `assets/css/app.css` as `[data-theme="<name>-light"]` / `[data-theme="<name>-dark"]`.
  Here we keep only what code outside the stylesheet needs: the display label and
  each variant's primary accent (so the standalone report — which can't load
  daisyUI — can tint itself to match the dashboard). A test asserts these names
  stay in sync with the CSS.
  """

  @typedoc "A selectable colorway. `:name` is the CSS/storage key; `:label` is shown in the UI."
  @type t :: %{
          name: String.t(),
          label: String.t(),
          primary_light: String.t(),
          primary_dark: String.t()
        }

  # Ordered as shown in the picker. Hues sweep the wheel: cool → warm → vivid.
  # The `primary_*` values MUST equal the `--color-primary` authored for the
  # matching `-light` / `-dark` rule in app.css (the report mirrors them).
  @colorways [
    %{
      name: "winter",
      label: "Winter",
      primary_light: "oklch(57% 0.14 245)",
      primary_dark: "oklch(72% 0.15 245)"
    },
    %{
      name: "aqua",
      label: "Aqua",
      primary_light: "oklch(58% 0.12 195)",
      primary_dark: "oklch(74% 0.14 195)"
    },
    %{
      name: "forest",
      label: "Forest",
      primary_light: "oklch(52% 0.13 150)",
      primary_dark: "oklch(72% 0.15 150)"
    },
    %{
      name: "matrix",
      label: "Matrix",
      primary_light: "oklch(50% 0.19 142)",
      primary_dark: "oklch(84% 0.24 142)"
    },
    %{
      name: "mocha",
      label: "Mocha",
      primary_light: "oklch(52% 0.08 65)",
      primary_dark: "oklch(74% 0.08 65)"
    },
    %{
      name: "sunset",
      label: "Sunset",
      primary_light: "oklch(55% 0.17 45)",
      primary_dark: "oklch(75% 0.16 45)"
    },
    %{
      name: "rose",
      label: "Rose",
      primary_light: "oklch(56% 0.19 18)",
      primary_dark: "oklch(70% 0.19 18)"
    },
    %{
      name: "candy",
      label: "Candy",
      primary_light: "oklch(55% 0.17 350)",
      primary_dark: "oklch(76% 0.16 350)"
    },
    %{
      name: "grape",
      label: "Grape",
      primary_light: "oklch(54% 0.18 300)",
      primary_dark: "oklch(72% 0.18 300)"
    },
    %{
      name: "cyberpunk",
      label: "Cyberpunk",
      primary_light: "oklch(58% 0.22 330)",
      primary_dark: "oklch(74% 0.28 330)"
    }
  ]

  @doc "All selectable colorways, in picker order. Excludes the brand default."
  @spec colorways() :: [t()]
  def colorways, do: @colorways

  @doc "Just the colorway CSS/storage names (e.g. `[\"winter\", \"aqua\", ...]`)."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@colorways, & &1.name)
end
