defmodule FMutate.IOTest do
  # FMutate.IO on top of mob_midi's messages: what the I/O screen lists, and which devices come back
  # opened. The test process stands in for the bridge (it sends the {:midi, ...} messages) and for the
  # player (FMutate.MIDI of instance "a", which gets {:open_device, id, ports} casts).
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "fmutate_io_test_#{System.unique_integer([:positive])}")
    previous = Application.get_env(:fmutate_app, :data_dir)
    Application.put_env(:fmutate_app, :data_dir, dir)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fmutate_app, :data_dir, previous),
        else: Application.delete_env(:fmutate_app, :data_dir)

      File.rm_rf!(dir)
    end)

    start_supervised!(FMutate.IO)
    :ok = FMutate.IO.attach_player(self())
    :ok
  end

  defp devices(list) do
    json =
      JSON.encode!(
        for {id, name, opts} <- list do
          %{
            id: id,
            name: name,
            direction: "input",
            manufacturer: "Maker",
            type: Keyword.get(opts, :type, "usb"),
            input_ports: Keyword.get(opts, :ports, 1),
            output_ports: 0,
            own: Keyword.get(opts, :own, false)
          }
        end
      )

    send(FMutate.IO, {:midi, :devices, json})
    FMutate.IO.state()
  end

  test "lists other devices, not the app's own virtual port" do
    io = devices([{5, "Oxygen 49", ports: 2}, {6, "FMutate A", type: "virtual", own: true}])

    assert [%{id: 5, name: "Oxygen 49", type: :usb, outputs: 2, inputs: 0, open: false}] = io.midi
  end

  test "opening asks the player for every output port; the device shows open once the player has it" do
    devices([{5, "Oxygen 49", ports: 2}])
    assert :ok = FMutate.IO.open(5)
    assert_receive {:"$gen_cast", {:open_device, 5, 2}}
    refute hd(FMutate.IO.state().midi).open

    send(FMutate.IO, {:device_opened, 5})
    assert [%{id: 5, open: true}] = FMutate.IO.state().midi
  end

  test "a device opened before comes back opened when it is plugged in again, under a new id" do
    devices([{5, "Oxygen 49", []}])
    :ok = FMutate.IO.open(5)
    assert_receive {:"$gen_cast", {:open_device, 5, 1}}
    send(FMutate.IO, {:device_opened, 5})

    assert devices([]).midi == []
    assert [%{id: 9, open: false}] = devices([{9, "Oxygen 49", []}]).midi
    assert_receive {:"$gen_cast", {:open_device, 9, 1}}
  end

  test "a closed device is forgotten: plugged in again, it stays closed" do
    devices([{5, "Oxygen 49", []}])
    :ok = FMutate.IO.open(5)
    assert_receive {:"$gen_cast", {:open_device, 5, 1}}
    send(FMutate.IO, {:device_opened, 5})
    :ok = FMutate.IO.close(5)
    assert [%{open: false}] = FMutate.IO.state().midi

    devices([])
    devices([{9, "Oxygen 49", []}])
    refute_receive {:"$gen_cast", {:open_device, _, _}}
  end

  test "opening an unknown device is an error and asks nobody" do
    devices([{5, "Oxygen 49", []}])
    assert {:error, :no_such_device} = FMutate.IO.open(77)
    refute_receive {:"$gen_cast", {:open_device, _, _}}
  end

  test "the Bluetooth scan: devices found while scanning are listed once each" do
    send(FMutate.IO, {:midi, :bluetooth_scan, :started})
    send(FMutate.IO, {:midi, :bluetooth_device, %{address: "AA", name: "WIDI"}})
    send(FMutate.IO, {:midi, :bluetooth_device, %{address: "AA", name: "WIDI"}})
    assert %{scanning: true, found: [%{address: "AA"}]} = FMutate.IO.state().bluetooth

    send(FMutate.IO, {:midi, :bluetooth_scan, :stopped})
    assert %{scanning: false, found: [_]} = FMutate.IO.state().bluetooth
  end

  test "the instances' virtual ports report who has them open" do
    FMutate.IO.virtual_status(0, "FMutate A", 1, 2)

    assert [%{instance: 0, name: "FMutate A", senders: 1, listeners: 2}] =
             FMutate.IO.state().virtual
  end
end
