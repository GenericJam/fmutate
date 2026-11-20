defmodule FMutate.Dist.Requests do
  @moduledoc """
  Sibling apps that ask to connect (protocol.md §7 "Allow / Disconnect"). A sibling signed with FMutate's key
  registers its node name through the content provider before it connects:

      call(content://com.genericjam.fmutate.siblings, "register", "<name>@127.0.0.1")

  The provider (`FMutateSiblingProvider`, protected by Android's signature permission) validates the name,
  rate-limits the caller and writes an empty file named after it into `Paths.dist_dir()/requests`. `take/1`
  reads and deletes those files; `FMutate.Dist` lists the names as pending binaries for the player's Allow.

  OTP's handshake makes an atom of a connecting node's declared name unless the `net_kernel` allow list
  refuses it first. Pending provider registrations therefore stay binaries. Only a player's Allow tap turns
  one into an atom and adds it to the allow list.
  """

  # The same rules as FMutateSiblingProvider: a sibling's short name on this phone, not an FMutate instance's.
  @name ~r/\A[a-z][a-z0-9_]{0,63}@127\.0\.0\.1\z/
  @instance ~r/\Afmutate_[a-z]@/
  @max 16

  @doc "Whether `name` (a string) may be registered."
  @spec valid?(term()) :: boolean()
  def valid?(name), do: is_binary(name) and name =~ @name and not (name =~ @instance)

  @doc """
  The names registered in `dir` since the last call (at most 16, oldest first), each file deleted; files
  with any other name are deleted unread. Names stay strings: the caller makes the atoms.
  """
  @spec take(Path.t()) :: [String.t()]
  def take(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        {names, others} = Enum.split_with(files, &valid?/1)
        Enum.each(others, &File.rm_rf(Path.join(dir, &1)))

        names
        |> Enum.map(&{mtime(Path.join(dir, &1)), &1})
        |> Enum.sort()
        |> Enum.map(fn {_, name} -> name end)
        |> Enum.split(@max)
        |> then(fn {taken, dropped} ->
          Enum.each(taken ++ dropped, &File.rm(Path.join(dir, &1)))
          taken
        end)

      {:error, _} ->
        []
    end
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: t}} -> t
      _ -> 0
    end
  end
end
