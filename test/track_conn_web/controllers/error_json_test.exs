defmodule TrackConnWeb.ErrorJSONTest do
  use TrackConnWeb.ConnCase, async: true

  test "renders 404" do
    assert TrackConnWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert TrackConnWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
