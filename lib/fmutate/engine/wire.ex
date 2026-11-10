defmodule FMutate.Engine.Wire do
  @moduledoc """
  Binary codec for the engine port protocol (`docs/engine_protocol.md`). Port messages are framed by
  `{:packet, 2}`; this module deals with the payload: one opcode byte and big-endian fields.
  """

  @type cmd ::
          {:key, 0..26, boolean}
          | {:button, 0..13, boolean}
          | {:enc, 0..6, integer}
          | {:midi, 0..255, 0..255, 0..255}
          | {:master, 0..1024}
          | {:midi_at, non_neg_integer, 0..255, 0..255, 0..255}
          | :crash
          | :hang

  @spec encode(cmd) :: binary
  def encode({:key, key, down}) when key in 0..26, do: <<0x01, key, bool(down)>>
  def encode({:button, b, down}) when b in 0..13, do: <<0x02, b, bool(down)>>

  def encode({:enc, e, clicks}) when e in 0..6 and is_integer(clicks),
    do: <<0x03, e, clamp(clicks, -128, 127)::signed-8>>

  def encode({:midi, st, d1, d2}) when st in 0..255 and d1 in 0..255 and d2 in 0..255,
    do: <<0x04, st, d1, d2>>

  def encode({:master, v}) when is_integer(v), do: <<0x05, clamp(v, 0, 1024)::16>>

  def encode({:midi_at, frame, st, d1, d2})
      when is_integer(frame) and frame >= 0 and st in 0..255 and d1 in 0..255 and d2 in 0..255,
      do: <<0x06, frame::64, st, d1, d2>>

  def encode(:crash), do: <<0x10>>
  def encode(:hang), do: <<0x11>>

  @type status :: %{
          ms: non_neg_integer,
          fill: non_neg_integer,
          fb_seq: non_neg_integer,
          led_buttons: non_neg_integer,
          led_keys: non_neg_integer,
          glow_keys: non_neg_integer
        }

  @type event :: {:ready, non_neg_integer} | {:status, status} | {:flash_saved, non_neg_integer}

  @spec decode(binary) :: {:ok, event} | {:error, binary}
  def decode(<<0x81, ms::32>>), do: {:ok, {:ready, ms}}

  def decode(<<0x82, ms::32, fill::32, fb_seq::32, lb::32, lk::32, gk::32>>),
    do:
      {:ok,
       {:status, %{ms: ms, fill: fill, fb_seq: fb_seq, led_buttons: lb, led_keys: lk, glow_keys: gk}}}

  def decode(<<0x84, bytes::32>>), do: {:ok, {:flash_saved, bytes}}
  def decode(other), do: {:error, other}

  @doc "The engine side of `decode/1`, for fakes in tests."
  @spec encode_event(event) :: binary
  def encode_event({:ready, ms}), do: <<0x81, ms::32>>

  def encode_event({:status, s}),
    do: <<0x82, s.ms::32, s.fill::32, s.fb_seq::32, s.led_buttons::32, s.led_keys::32, s.glow_keys::32>>

  def encode_event({:flash_saved, bytes}), do: <<0x84, bytes::32>>

  defp bool(true), do: 1
  defp bool(false), do: 0
  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)
end
