defmodule FMutate.Fwsc do
  @moduledoc """
  FM-1 update packages (`.fwsc`): enough of the format to tell one from any other file.

  The package is JieLi's UFW: the file starts with 20 blocks of 0x30 bytes whose first 0x2F bytes,
  concatenated, are the UFW header, scrambled with a CRC-16/CCITT keystream from 0xFFFF. Its first
  0x40 bytes, unscrambled, start with a CRC-16 of the 0x3E bytes after it (fm1-emu's `web/fwsc.js`).
  The package carries no name or version: those come from the catalogue or the file name.
  """

  import Bitwise

  @doc "Whether `bin` (the package, or at least its first 960 bytes) is an FM-1 update package."
  @spec valid?(binary) :: boolean
  def valid?(bin) when byte_size(bin) >= 20 * 0x30 do
    hdr = for i <- 0..19, into: <<>>, do: binary_part(bin, i * 0x30, 0x2F)
    <<crc::little-16, rest::binary-size(0x3E)>> = unmask(binary_part(hdr, 0, 0x40))
    crc16(rest) == crc
  end

  def valid?(_), do: false

  @doc "Whether the file at `path` is an FM-1 update package."
  @spec valid_file?(Path.t()) :: boolean
  def valid_file?(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 20 * 0x30)) do
      {:ok, bin} when is_binary(bin) -> valid?(bin)
      _ -> false
    end
  end

  defp unmask(bin), do: unmask(bin, 0xFFFF, [])

  defp unmask(<<b, rest::binary>>, key, acc),
    do: unmask(rest, next_key(key), [bxor(b, key &&& 0xFF) | acc])

  defp unmask(<<>>, _key, acc), do: acc |> Enum.reverse() |> :erlang.list_to_binary()

  defp next_key(key), do: bxor(key <<< 1, if((key &&& 0x8000) != 0, do: 0x1021, else: 0)) &&& 0xFFFF

  defp crc16(bin), do: for(<<b <- bin>>, reduce: 0, do: (crc -> crc_byte(bxor(crc, b <<< 8), 8)))

  defp crc_byte(crc, 0), do: crc
  defp crc_byte(crc, n), do: crc_byte(next_key(crc), n - 1)
end
