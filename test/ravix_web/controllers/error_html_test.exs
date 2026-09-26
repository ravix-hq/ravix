defmodule RavixWeb.ErrorHTMLTest do
  use RavixWeb.ConnCase, async: true

  import Phoenix.Template, only: [render_to_string: 4]

  test "renders themed 404 and 500 pages without requiring a session" do
    for {status, title} <- [{"404", "Page not found"}, {"500", "Something went wrong"}] do
      html = render_to_string(RavixWeb.ErrorHTML, status, "html", [])
      document = LazyHTML.from_document(html)

      assert LazyHTML.text(LazyHTML.query(document, "h1")) == "#{status} · #{title}"
      assert LazyHTML.text(LazyHTML.query(document, "a[href='/home']")) == "Home"
      assert LazyHTML.query(document, "script") |> LazyHTML.attribute("src") == ["/theme.js"]

      assert LazyHTML.query(document, "link[rel='stylesheet']") |> LazyHTML.attribute("href") ==
               ["/assets/js/app.css"]
    end
  end

  test "an unknown route returns a 404 with a Home link", %{conn: conn} do
    body = conn |> get("/no-such-page") |> html_response(404)

    assert body
           |> LazyHTML.from_document()
           |> LazyHTML.query("a[href='/home']")
           |> LazyHTML.text() ==
             "Home"
  end

  test "other HTTP errors retain their status messages" do
    assert render_to_string(RavixWeb.ErrorHTML, "403", "html", []) == "Forbidden"
  end
end
