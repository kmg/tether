defmodule TetherWeb.AuthLive do
  use TetherWeb, :live_view

  alias Tether.Auth

  def mount(params, session, socket) do
    # If already authenticated via session cookie, redirect home
    if session["tether_authenticated"] do
      {:ok, push_navigate(socket, to: "/")}
    else
      # Auto-authenticate if token is in URL params
      socket =
        case params do
          %{"token" => token} when is_binary(token) ->
            if Auth.valid_token?(token) do
              assign(socket, :auto_token, token)
            else
              assign(socket, :auto_token, nil)
            end

          _ ->
            assign(socket, :auto_token, nil)
        end

      {:ok, assign(socket, form: to_form(%{"token" => ""}, as: :auth), error: nil)}
    end
  end

  def handle_params(%{"token" => token}, _uri, socket) when is_binary(token) do
    if Auth.valid_token?(token) do
      # Valid token in URL — redirect to controller to set session
      {:noreply, redirect(socket, to: "/auth/callback?token=#{token}")}
    else
      {:noreply, assign(socket, error: "Invalid token")}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("validate", %{"auth" => %{"token" => _token}}, socket) do
    {:noreply, socket}
  end

  def handle_event("authenticate", %{"auth" => %{"token" => token}}, socket) do
    if Auth.valid_token?(String.trim(token)) do
      {:noreply, redirect(socket, to: "/auth/callback?token=#{String.trim(token)}")}
    else
      {:noreply, assign(socket, error: "Invalid token. Check your terminal for the correct token.")}
    end
  end

  def render(assigns) do
    ~H"""
    <div style="min-height: 100vh; display: flex; align-items: center; justify-content: center; padding: 1rem;">
      <div style="width: 100%; max-width: 24rem;">
        <h1 style="font-size: 1.5rem; font-weight: 600; color: #e5e7eb; margin-bottom: 0.5rem;">
          Tether
        </h1>
        <p style="color: #6b7280; margin-bottom: 1.5rem; font-size: 0.875rem;">
          Enter the token from your terminal to continue.
        </p>

        <.form for={@form} id="auth-form" phx-change="validate" phx-submit="authenticate">
          <div style="margin-bottom: 1rem;">
            <input
              type="text"
              name="auth[token]"
              id="auth-token"
              value={@form[:token].value}
              placeholder="Paste token here"
              autocomplete="off"
              autofocus
              style="width: 100%; padding: 0.75rem; background: #1f2937; border: 1px solid #374151; border-radius: 0.5rem; color: #e5e7eb; font-family: ui-monospace, monospace; font-size: 0.875rem; outline: none;"
            />
          </div>

          <%= if @error do %>
            <p style="color: #ef4444; font-size: 0.875rem; margin-bottom: 1rem;">
              {@error}
            </p>
          <% end %>

          <button
            type="submit"
            style="width: 100%; padding: 0.75rem; background: #3b82f6; color: white; border: none; border-radius: 0.5rem; font-size: 0.875rem; cursor: pointer; font-family: ui-monospace, monospace;"
          >
            Connect
          </button>
        </.form>
      </div>
    </div>
    """
  end
end
