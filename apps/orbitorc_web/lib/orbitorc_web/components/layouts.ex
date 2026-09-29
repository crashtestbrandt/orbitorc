defmodule OrbitorcWeb.Layouts do
  @moduledoc """
  The dashboard's frame: navigation, the name the browser acts as, and flash.

  The name is a form that posts to `/identity` and comes back to the page it left. It is the one thing
  the API has that a browser does not by itself, and every mutating verb a page runs carries it.
  """
  use OrbitorcWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :caller, :string, default: nil, doc: "the name this browser acts as, or nil"
  attr :path, :string, default: "/", doc: "where the identity form returns to"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="border-b border-zinc-200 bg-white">
      <div class="mx-auto flex max-w-5xl flex-wrap items-center justify-between gap-3 px-6 py-3">
        <nav class="flex items-baseline gap-5 text-sm">
          <.link navigate={~p"/"} class="text-base font-semibold">OrbitOrc</.link>
          <.link navigate={~p"/"} class="text-zinc-600 hover:underline">Fleet</.link>
          <.link navigate={~p"/runs"} class="text-zinc-600 hover:underline">Runs</.link>
        </nav>
        <form action={~p"/identity"} method="post" class="flex items-center gap-2 text-sm">
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <input type="hidden" name="return_to" value={@path} />
          <label for="identity-caller" class="text-zinc-500">acting as</label>
          <input
            id="identity-caller"
            name="caller"
            value={@caller}
            placeholder="your name"
            class="w-40 rounded border border-zinc-300 px-2 py-1 font-mono text-sm"
          />
          <button class="rounded border border-zinc-300 px-2 py-1 hover:bg-zinc-50">Set</button>
        </form>
      </div>
    </header>

    <main class="mx-auto max-w-5xl space-y-6 p-6">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc "A line every page shows while the browser has no name: the mutating verbs are closed until it has one."
  attr :caller, :string, default: nil

  def identity_notice(assigns) do
    ~H"""
    <p
      :if={is_nil(@caller)}
      class="rounded border border-zinc-300 bg-zinc-50 p-3 text-sm text-zinc-700"
    >
      Set a name above to launch, stop, sync, build or take a lease. The lease arbitrates between names,
      and the audit log attributes to them.
    </p>
    """
  end

  @doc "Shows the flash group with standard titles and content."
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="Disconnected"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Reconnecting <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="The control plane is unreachable"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Reconnecting <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
