defmodule FMutate.Style do
  @moduledoc """
  Design tokens for FMutate (flat skin). Dark, stage-readable.

  Units are points (pt / dp). Colours are hex strings.
  Lime (`:fm`) means "you touched it / it's live" and nothing else.
  Amber (`:led`) belongs to the firmware: key and button LEDs only.
  Violet (`:agent`) is reserved for anything driven by another app.
  """

  # ── Colour ────────────────────────────────────────────────────────────
  @colors %{
    bg: "#14121A",          # app background
    bg_deep: "#0E0D12",     # edit-mode background, code wells
    surface: "#1C1925",     # cards, sheets
    raised: "#221F2B",      # buttons, pads, slider tracks
    raised_hi: "#2A2636",   # chips, secondary buttons
    selected: "#34304A",    # selected segment, active knob cap
    line: "#34304A",        # 1 pt borders
    line_soft: "#2E2A3B",   # knob tracks, grid cells
    text: "#F3EFF8",
    text_2: "#C9C3D6",      # secondary text
    muted: "#A9A3B8",       # captions, labels (passes 4.5:1 on bg)
    faint: "#6B6580",       # key names on white keys, disabled
    key_white: "#ECE7F2",
    key_black: "#2A2633",
    key_label_on_black: "#B9B2C8",
    led_off: "#3A3548",
    led_off_on_white: "#D3CCDD",

    fm: "#C6F24E",          # live / pressed / primary action
    fm_dim: "#7FA62A",      # LED dot on a pressed key
    fm_tint: "#4C5A2A",     # slider fill when active
    led: "#FF9F2E",         # firmware LEDs
    agent: "#A98BFF",       # externally driven, sibling apps
    agent_bg: "#2A2240",
    slider_fill: "#3A3450",
    danger: "#FF9A7A",      # REC, overlap in edit mode, crash
    danger_bg: "#4A1F1A",
    danger_text: "#FFB4A3",
    warn: "#FFB547",        # "doesn't run here yet", tight keys
    warn_line: "#7A5A22",
    info: "#8FD8FF",        # MIDI chips

    # pad family colours (drum pads, chips)
    pad_coral: "#FF9A7A",
    pad_amber: "#FFB547",
    pad_sky: "#8FD8FF",
    pad_violet: "#B9A2FF",

    # light surfaces (toasts, edit pill, popovers)
    paper: "#F3EFF8",
    paper_2: "#E2DCEB",
    ink: "#14121A",
    ink_2: "#5E5870",
    brand_violet: "#7B5CF0", # icon background
    brand_violet_text: "#5B3FD6" # "FM" in the wordmark on light backgrounds
  }

  # ── Spacing, size, radius ─────────────────────────────────────────────
  @space %{xs: 4, s: 8, m: 12, l: 16, xl: 20, xxl: 28}
  @edge_gutter 28        # left/right on every instrument screen (back gesture)
  @top_bottom_inset 12
  @touch 48              # minimum target
  @grid %{min_cell: 48, gap: 8}

  @radius %{
    key_white_top: 3, key_white_bottom: 9,
    key_black_top: 2, key_black_bottom: 7,
    button: 10, pad: 12, slider: 14, card: 18, sheet: 24,
    chip: 999, pill: 999
  }

  @screen_bezel 6
  @press_offset 2        # pressed controls move down 2 pt

  # ── Type ──────────────────────────────────────────────────────────────
  # Display: Bricolage Grotesque 800. UI: Inter. Control labels and numbers: JetBrains Mono.
  @fonts %{display: "Bricolage Grotesque", ui: "Inter", mono: "JetBrains Mono"}

  @type_scale %{
    display: %{font: :display, size: 32, weight: 800, line: 1.0},
    title: %{font: :display, size: 22, weight: 800, line: 1.1},
    body: %{font: :ui, size: 15, weight: 400, line: 1.4},
    body_strong: %{font: :ui, size: 15, weight: 600, line: 1.4},
    small: %{font: :ui, size: 13, weight: 400, line: 1.4},
    caption: %{font: :ui, size: 12, weight: 400, line: 1.45},
    # fixed size on the instrument, never scaled by dynamic type:
    control_label: %{font: :mono, size: 10, weight: 600, line: 1.0, tracking: 0.04},
    button_label: %{font: :ui, size: 11, weight: 600, line: 1.1},
    section_label: %{font: :mono, size: 11, weight: 600, line: 1.0, tracking: 0.08, upper: true}
  }

  # ── Motion ────────────────────────────────────────────────────────────
  @motion %{
    press_ms: 0,            # paint on touch-down, no animation
    fine_hold_ms: 400,
    edit_hold_ms: 600,
    edge_move_ms: 500,
    rail_follow_ms: 150,
    toast_ms: 4000
  }

  # ── Controls ──────────────────────────────────────────────────────────
  @knob %{
    size: 56, cap_r: 15, track_r: 22, track_w: 4,
    pot_sweep_deg: 270, pot_full_range_pt: 200,
    encoder_ticks: 16, encoder_tick_r: 1.7, encoder_pt_per_click: 6,
    fine_factor: 0.25
  }

  def colors, do: @colors
  def color(name), do: Map.fetch!(@colors, name)

  # Mob's Android renderer takes node colours (`background`, `text_color`, …) as ARGB integers or theme atoms;
  # "#RRGGBB" strings are dropped. Canvas ops still take hex.

  @doc "A colour token (`:fm`) or `\"#RRGGBB\"` as the ARGB integer Mob's nodes take."
  def argb(name) when is_atom(name), do: argb(color(name))
  def argb("#" <> hex) when byte_size(hex) == 6, do: 0xFF000000 + String.to_integer(hex, 16)

  @color_props Mob.Renderer.color_props()

  @doc "Convert every `\"#RRGGBB\"` colour prop in a rendered `~MOB` tree to ARGB (templates keep the boards' hex)."
  def native_colors(%{props: props, children: children} = node) do
    props =
      Map.new(props, fn
        {k, "#" <> hex = v} when k in @color_props and byte_size(hex) == 6 -> {k, argb(v)}
        kv -> kv
      end)

    %{node | props: props, children: Enum.map(children, &native_colors/1)}
  end

  def native_colors(list) when is_list(list), do: Enum.map(list, &native_colors/1)
  def native_colors(other), do: other
  def space(name), do: Map.fetch!(@space, name)
  def edge_gutter, do: @edge_gutter
  def top_bottom_inset, do: @top_bottom_inset
  def touch, do: @touch
  def grid, do: @grid
  def radius(name), do: Map.fetch!(@radius, name)
  def screen_bezel, do: @screen_bezel
  def press_offset, do: @press_offset
  def fonts, do: @fonts
  def type(name), do: Map.fetch!(@type_scale, name)
  def motion, do: @motion
  def knob, do: @knob

  @doc """
  Grid for a usable instrument area of `w` × `h` pt (screen minus gutters/insets).
  Returns cols, rows and the cell size that fills the area.
  """
  def grid_for(w, h) do
    %{min_cell: min, gap: gap} = @grid
    cols = max(1, div(trunc(w + gap), min + gap))
    rows = max(1, div(trunc(h + gap), min + gap))
    %{
      cols: cols,
      rows: rows,
      cell_w: (w - (cols - 1) * gap) / cols,
      cell_h: (h - (rows - 1) * gap) / rows,
      gap: gap
    }
  end

  @doc """
  The 88-key colour for a MIDI note (21 = A0 … 108 = C8): hue 0° (red) to 300° (violet).
  Used for key caps, the voice/side-keyboard rail and note blocks. Black keys use lightness 45–50.
  Returns {h, s, l} so callers can convert to their colour type.
  """
  def pitch_color(midi, lightness \\ 62) when midi in 21..108 do
    {round((midi - 21) / 87 * 300), 72, lightness}
  end
end
