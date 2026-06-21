defmodule DropDoctorWeb.AssetsPipelineTest do
  @moduledoc """
  Guards the JS asset pipeline against the two regressions that have silently
  broken the dashboard in a *prod* build (and that `mix test` otherwise can't
  see, since it never bundles):

    1. **Hook registration vanishes from the bundle.** Every interactive piece
       of the UI (the timeline chart pan, flash auto-dismiss) is a colocated
       LiveView hook. esbuild only picks them up from the
       `phoenix-colocated/drop_doctor` extraction that `compile` produces — so if
       a hook is declared in a template but never lands in that extraction, it's
       dead in prod with no error. We assert every declared colocated hook is
       actually registered in the built manifest.

    2. **esbuild runs before compile in `assets.deploy`.** Then the extraction
       above is stale/empty when esbuild bundles, dropping *all* hooks. We assert
       the alias compiles before it bundles.
  """
  use ExUnit.Case, async: true

  @colocated_index Path.join([
                     Mix.Project.build_path(),
                     "phoenix-colocated",
                     "drop_doctor",
                     "index.js"
                   ])

  describe "colocated hook registration" do
    test "every hook declared in a template is registered in the built manifest" do
      declared = declared_hook_names()

      assert declared != [],
             "expected to find ColocatedHook declarations in lib/ — did the attr syntax change?"

      manifest =
        case File.read(@colocated_index) do
          {:ok, contents} ->
            contents

          {:error, _} ->
            flunk("""
            colocated hook manifest missing at #{@colocated_index}.
            It is produced by `mix compile`; run the suite via mix so compilation runs first.
            """)
        end

      for name <- declared do
        assert String.contains?(manifest, name),
               """
               colocated hook #{inspect(name)} is declared in a template but absent from the
               built manifest (#{@colocated_index}). It would be dead in a prod bundle.
               """
      end
    end
  end

  describe "assets.deploy ordering" do
    test "compiles before it bundles, so hook extraction is fresh" do
      steps = Mix.Project.config()[:aliases][:"assets.deploy"]
      assert is_list(steps), "expected an assets.deploy alias list"

      compile_at = Enum.find_index(steps, &(&1 == "compile"))
      esbuild_at = Enum.find_index(steps, &String.starts_with?(&1, "esbuild"))

      assert compile_at,
             ~s(assets.deploy must run "compile" so colocated hooks are extracted before bundling)

      assert esbuild_at, "expected an esbuild step in assets.deploy"

      assert compile_at < esbuild_at,
             ~s("compile" must run before "esbuild" in assets.deploy, or hook extraction is stale and every hook drops from the prod bundle)
    end
  end

  describe "colorway theme sync" do
    # A colorway (DropDoctor.Themes) is wired across spots that CSS/HEEx can't
    # cross-check at compile time: the light/dark palette rules and the active-ring
    # selector in app.css, plus the report's mirrored accent. Drift is silent — a
    # swatch with no palette, no ring, or a report that doesn't match — so we
    # assert they all agree here. The canonical source is DropDoctor.Themes.
    @app_css "assets/css/app.css"

    test "every colorway has light and dark palette rules in app.css" do
      css = File.read!(@app_css)

      for cw <- DropDoctor.Themes.colorways(), variant <- ~w(light dark) do
        selector = ~s([data-theme="#{cw.name}-#{variant}"])

        assert String.contains?(css, selector),
               "colorway #{inspect(cw.name)} is missing its #{variant} palette #{selector} in #{@app_css}"
      end
    end

    test "every colorway and the default have an active-ring selector" do
      css = File.read!(@app_css)

      for name <- ["default" | DropDoctor.Themes.names()] do
        selector = ~s([data-colorway="#{name}"] .tc-swatch[data-colorway="#{name}"])

        assert String.contains?(css, selector),
               "colorway #{inspect(name)} has no active-ring selector in #{@app_css}. Add: #{selector}"
      end
    end

    test "report accents match each colorway's own primary block in app.css" do
      # The report (DropDoctor.Themes.primary_*) retints itself per colorway. Each
      # value must equal the --color-primary inside *that colorway's own*
      # `[data-theme="<name>-<variant>"]` block — checking the scoped block (not
      # just presence anywhere) also catches two colorways being swapped.
      css = File.read!(@app_css)

      for cw <- DropDoctor.Themes.colorways(),
          {variant, expected} <- [{"light", cw.primary_light}, {"dark", cw.primary_dark}] do
        block = theme_block(css, "#{cw.name}-#{variant}")

        assert block,
               "no [data-theme=\"#{cw.name}-#{variant}\"] block found in #{@app_css}"

        assert String.contains?(block, "--color-primary: #{expected};"),
               "#{cw.name}-#{variant} block does not set --color-primary: #{expected}; (the report would mis-tint). Block: #{inspect(block)}"
      end
    end
  end

  # Body of the rule `[data-theme="<theme>"] { ... }` (these palette rules are
  # flat — no nested braces), or nil if absent.
  defp theme_block(css, theme) do
    case Regex.run(~r/\[data-theme="#{Regex.escape(theme)}"\]\s*\{([^}]*)\}/, css,
           capture: :all_but_first
         ) do
      [body] -> body
      _ -> nil
    end
  end

  # Pull the hook names out of `<script :type={Phoenix.LiveView.ColocatedHook}
  # name=".Foo">` declarations across the web layer, stripping the leading dot
  # (the "current module" marker) so they match the fully-qualified manifest key.
  defp declared_hook_names do
    Path.wildcard("lib/drop_doctor_web/**/*.ex")
    |> Enum.flat_map(fn file ->
      Regex.scan(~r/ColocatedHook}\s+name="\.?([A-Za-z0-9_]+)"/, File.read!(file),
        capture: :all_but_first
      )
    end)
    |> List.flatten()
    |> Enum.uniq()
  end
end
