defmodule RavixWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use RavixWeb, :html

  embed_templates "error_html/*"

  attr :status, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  # Errors can happen before the browser pipeline establishes a session.
  # Keep this shell independent of session data and LiveView startup.
  def page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@title} · Ravix</title>
        <script src={~p"/theme.js"}>
        </script>
        <link rel="stylesheet" href={~p"/assets/js/app.css"} />
      </head>
      <body>
        <main class="centred">
          <div class="hero">
            <.wordmark />
            <h1>{@status} · {@title}</h1>
            <p class="hero-sub">{render_slot(@inner_block)}</p>
            <a href={~p"/home"}>Home</a>
          </div>
        </main>
      </body>
    </html>
    """
  end

  # Preserve Phoenix's status message for other HTTP errors.
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
