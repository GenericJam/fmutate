defmodule FMutate.UpdatesScreen do
  @moduledoc """
  Updates (menu → Updates): this app's version and the Elixir code it runs, Check now, when it last
  checked, and a newer release's notes with Download & install. Everything comes from
  `FMutate.Updates`; nothing installs without the user tapping Install here and confirming Android's own
  dialog.
  """

  use Mob.Screen

  alias FMutate.Updates

  def mount(_params, _session, socket) do
    state =
      case GenServer.whereis(Updates) do
        nil -> nil
        _pid -> elem(Updates.subscribe(), 1)
      end

    {:ok, Mob.Socket.assign(socket, updates: state)}
  end

  def render(assigns) do
    back = {self(), :back}

    ~MOB"""
    <Scroll background={0xFF14121A}>
      <Column padding_left={16} padding_right={16} padding_top={12} padding_bottom={24} gap={12} background={0xFF14121A}>
        <Row gap={8} align={:center}>
          <Button text="‹" on_tap={back} background={0xFF14121A} text_color={0xFFF3EFF8} text_size={26} fill_width={false} padding={6} />
          <Text text="Updates" text_size={24} text_color={0xFFF3EFF8} font_weight="bold" />
        </Row>
        {body(assigns.updates)}
      </Column>
    </Scroll>
    """
  end

  defp body(nil), do: [text("Updates aren't running in this build.", :dim)]

  defp body(u) do
    [app_card(u), release_card(u), code_card(u)] |> Enum.reject(&is_nil/1)
  end

  ## The app (APK)

  defp app_card(u) do
    check = {self(), :check}
    checking = u.app == :checking or match?({:downloading, _, _}, u.app)

    card([
      label("APP"),
      text(version_line(u.installed), :mono),
      u.updated_from && text("Updated from version code #{u.updated_from}.", :good),
      text(status_line(u.app), status_tone(u.app)),
      text("Last checked: #{when_label(u.checked_at)}", :dim),
      ~MOB"""
      <Button text={if checking, do: "Checking…", else: "Check now"} on_tap={check} disabled={checking} background={0xFF221F2B} text_color={0xFFF3EFF8} text_size={14} corner_radius={12} />
      """
    ])
  end

  defp version_line(nil), do: "FMutate (version unknown off-device)"
  defp version_line(%{version_name: name, version_code: code}), do: "FMutate #{name} (#{code})"

  defp status_line(:idle), do: "Not checked yet this launch."
  defp status_line(:checking), do: "Checking GitHub for a newer release…"
  defp status_line(:up_to_date), do: "Up to date."
  defp status_line({:available, r}), do: "FMutate #{r.version_name} is available."
  defp status_line({:downloading, got, total}), do: "Downloading… #{progress(got, total)}"
  defp status_line({:confirm, r}), do: "Confirm the install of #{r.version_name} in Android's dialog."

  defp status_line({:needs_permission, _r}),
    do:
      "Android needs your OK once: tap Allow installs, turn on \"Allow from this source\" for FMutate, " <>
        "come back and tap Install again."

  defp status_line({:error, reason}), do: "Couldn't update: " <> error_label(reason)

  defp status_tone({:error, _}), do: :bad
  defp status_tone({:available, _}), do: :good
  defp status_tone(_), do: :normal

  defp progress(got, total) when is_integer(total) and total > 0,
    do: "#{div(got * 100, total)}% of #{mb(total)}"

  defp progress(got, _total), do: mb(got)

  defp mb(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp error_label({:transport, _}), do: "no connection to GitHub."
  defp error_label({:rate_limited, _reset}), do: "GitHub's rate limit; try again in an hour."
  defp error_label({:sha256_mismatch, _, _}), do: "the download was damaged (checksum mismatch); try again."
  defp error_label({:size_mismatch, _, _}), do: "the download was cut short; try again."
  defp error_label({:signature_mismatch, _, _}), do: "that APK isn't signed with FMutate's key; not installed."
  defp error_label({:not_an_update, _, _}), do: "that APK isn't newer than this one."
  defp error_label({:install_failed, _status, message}), do: "Android didn't install it (#{message})."
  defp error_label(reason) when reason in [:no_release, :no_update_metadata],
    do: "the latest release has no update information."

  defp error_label(reason), do: inspect(reason)

  ## A newer release: notes and Install

  defp release_card(%{app: app, release: %{} = r}) when elem(app, 0) in [:available, :needs_permission, :confirm, :error] do
    install = {self(), :install}
    settings = {self(), :settings}
    needs_permission = match?({:needs_permission, _}, app)

    card([
      label("FMUTATE #{String.upcase(r.version_name)}"),
      text("#{mb(r.apk.size)} · #{date_label(r.published_at)}", :dim),
      text(notes(r.notes), :normal),
      needs_permission &&
        ~MOB"""
        <Button text="Allow installs" on_tap={settings} background={0xFF221F2B} text_color={0xFFC6F24E} text_size={14} corner_radius={12} />
        """,
      ~MOB"""
      <Button text="Download & install" on_tap={install} background={0xFF5B3FD6} text_color={0xFFF3EFF8} text_size={14} font_weight="bold" corner_radius={12} />
      """,
      text("Android shows its own dialog before installing. Your layouts and saves stay.", :dim)
    ])
  end

  defp release_card(_u), do: nil

  defp notes(nil), do: "No release notes."
  defp notes(""), do: "No release notes."

  # release bodies are Markdown; shown as plain text, without the heading/emphasis marks
  defp notes(markdown) do
    markdown
    |> String.replace(~r/^#+\s*/m, "")
    |> String.replace(~r/\*\*|__|`/, "")
    |> String.trim()
  end

  ## The code (OTA)

  defp code_card(%{code: code}) do
    state = code.state

    card([
      label("CODE"),
      text(active_line(state), :mono),
      text("Channel: #{code.channel || "not configured"}", :dim),
      state && state.disabled && text("Code updates are off: #{inspect(state.disabled)}", :bad),
      state && state.rollback_notice && text("The last code update failed and was rolled back.", :bad),
      state && state.restart_required && text("A code update is installed: it applies when FMutate restarts.", :good),
      text("Last code check: #{code_check_label(state)}", :dim)
    ])
  end

  defp active_line(%{active: %{id: id, issued_at: at}}),
    do: "Delivered code #{String.slice(id, 0, 8)} (published #{date_label(at)})"

  defp active_line(_state), do: "The code this app was built with."

  defp code_check_label(%{last_check: %{result: result, at: at}}), do: "#{when_label(at)}: #{code_result(result)}"
  defp code_check_label(_state), do: "not yet"

  defp code_result({:ok, :installed}), do: "installed, applies at the next start"
  defp code_result({:ok, :current}), do: "up to date"
  defp code_result({:ok, outcome}), do: to_string(outcome)
  defp code_result({:error, {:downgrade, _}}), do: "the server still had an older copy"
  defp code_result({:error, {:http_status, 404}}), do: "nothing published for this version"
  defp code_result({:error, reason}), do: "error #{inspect(reason)}"
  defp code_result(other), do: inspect(other)

  ## Pieces

  defp when_label(nil), do: "never"
  defp when_label(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  defp date_label(nil), do: "—"
  defp date_label(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d")

  defp label(text) do
    ~MOB"""
    <Text text={text} text_size={11} text_color={0xFFA9A3B8} font="monospace" font_weight="bold" />
    """
  end

  defp text(text, :mono) do
    ~MOB"""
    <Text text={text} text_size={13} text_color={0xFFF3EFF8} font="monospace" />
    """
  end

  defp text(text, tone) do
    color =
      case tone do
        :dim -> 0xFFA9A3B8
        :good -> 0xFFC6F24E
        :bad -> 0xFFFFB4A3
        _ -> 0xFFF3EFF8
      end

    ~MOB"""
    <Text text={text} text_size={13} text_color={color} />
    """
  end

  defp card(children) do
    children = Enum.reject(children, &(&1 in [nil, false]))

    ~MOB"""
    <Column background={0xFF1C1925} corner_radius={16} padding_left={14} padding_right={14} padding_top={12} padding_bottom={12} gap={10}>
      {children}
    </Column>
    """
  end

  ## Events

  def handle_info({:updates, state}, socket), do: {:noreply, Mob.Socket.assign(socket, :updates, state)}
  def handle_info({:tap, :back}, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}

  def handle_info({:tap, :check}, socket) do
    Updates.check()
    {:noreply, socket}
  end

  def handle_info({:tap, :install}, socket) do
    Updates.install()
    {:noreply, socket}
  end

  def handle_info({:tap, :settings}, socket) do
    Updates.open_install_settings()
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
