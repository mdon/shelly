defmodule Shelly.ExhaustiveTest do
  @moduledoc """
  Two defect families kept recurring here, each time as "the guard was
  installed where the bug was seen, not at the type boundary": a
  credential check that covered `nil` but not `""`, an access chain
  hardened in one module and not its siblings.

  Reviewing for those is manual and keeps missing one. Enumerating them is
  not. These tests derive their cases rather than listing them, so a new
  entry point or a new payload shape is covered the day it is added.
  """

  use ExUnit.Case, async: true

  alias Shelly.{Client, Events, Status}

  describe "every credential-consuming entry point, for every non-credential" do
    # A request that reaches the network without a credential trips this.
    defp trap do
      [plug: fn _conn -> raise "a call left the process without a credential" end]
    end

    defp blank_clients(field) do
      for value <- [nil, "", "   ", "\t\n"] do
        {value,
         Client.new(
           [{:server, "https://s.shelly.cloud"}, {field, value}] ++ [req_options: trap()]
         )}
      end
    end

    test "no OAuth entry point calls out without a usable token" do
      calls = [
        {"Account.list_devices/1", &Shelly.Account.list_devices/1},
        {"Account.all_statuses/1", &Shelly.Account.all_statuses/1},
        {"Account.set_switch/4", &Shelly.Account.set_switch(&1, "abc", 0, true)},
        {"Events.start_link/2", &Events.start_link(&1, handler: fn _ -> :ok end)},
        {"OAuth.refresh/2", &Shelly.OAuth.refresh/1}
      ]

      for {label, call} <- calls, {value, client} <- blank_clients(:token) do
        assert call.(client) == {:error, :no_token},
               "#{label} accepted token #{inspect(value)}"
      end
    end

    test "no auth-key entry point calls out without a usable key" do
      calls = [
        {"CloudV2.get_statuses/2", &Shelly.CloudV2.get_statuses(&1, ["abc"])},
        {"CloudV2.set_switch/5", &Shelly.CloudV2.set_switch(&1, "abc", 0, true)},
        {"CloudV2.set_cover/5", &Shelly.CloudV2.set_cover(&1, "abc", 0, 50)},
        {"CloudV2.set_light/4", &Shelly.CloudV2.set_light(&1, "abc", 0, brightness: 1)},
        {"CloudV1.get_status/2", &Shelly.CloudV1.get_status(&1, "abc")},
        {"CloudV1.set_switch/4", &Shelly.CloudV1.set_switch(&1, "abc", 0, true)}
      ]

      for {label, call} <- calls, {value, client} <- blank_clients(:auth_key) do
        assert call.(client) == {:error, :no_auth_key},
               "#{label} accepted auth_key #{inspect(value)}"
      end
    end
  end

  describe "Status.parse/4 is total, whatever the payload holds" do
    # Realistic shapes; every nested position gets a scalar substituted in
    # turn, which is what a malformed or unexpected payload looks like.
    @shapes [
      %{
        "switch:0" => %{"output" => true, "apower" => 1.0, "aenergy" => %{"total" => 2.0}},
        "wifi" => %{"rssi" => -50},
        "input:0" => %{"state" => true},
        "devicepower:0" => %{"battery" => %{"percent" => 90}},
        "temperature:0" => %{"tC" => 20.0},
        "humidity:0" => %{"rh" => 40.0}
      },
      %{"cover:0" => %{"state" => "open", "current_pos" => 50, "temperature" => %{"tC" => 30.0}}},
      %{"em1:0" => %{"act_power" => 1.0}, "em1data:0" => %{"total_act_energy" => 5.0}},
      %{"relays" => [%{"ison" => true}], "meters" => [%{"power" => 1.0, "total" => 60}]},
      %{"rollers" => [%{"state" => "open", "current_pos" => 10}], "inputs" => [%{"input" => 1}]},
      %{"tmp" => %{"tC" => 20.0}, "hum" => %{"value" => 50.0}, "bat" => %{"value" => 80}},
      %{"sensor" => %{"state" => "open"}, "bat" => %{"value" => 80}},
      %{"smoke:0" => %{"alarm" => true}},
      %{"emeters" => [%{"power" => 1.0, "total" => 2.0}]}
    ]

    @scalars [1, "text", true, nil, [], 1.5]

    test "no substitution of a scalar at any nesting level makes it raise" do
      for shape <- @shapes,
          {path, _} <- paths(shape),
          scalar <- @scalars,
          channel <- [0, 1] do
        payload = put_path(shape, path, scalar)

        parsed = Status.parse(payload, channel, true)

        assert is_map(parsed),
               "parse/4 did not return a status for #{inspect(payload)} on channel #{channel}"

        assert Map.has_key?(parsed, :component)

        # The documented guard must agree with what parse can do.
        assert is_boolean(Status.has_component?(payload, channel))
        component = Status.component_of(payload, channel)
        assert is_nil(component) or is_binary(component)
      end
    end

    test "the same holds for payloads that aren't maps at all" do
      for payload <- @scalars ++ [%{}, [%{"a" => 1}]] do
        assert %{component: _} = Status.parse(payload, 0, true)
        refute Status.has_component?(payload, 0)
        assert Status.component_of(payload, 0) == nil
      end
    end

    # Every {path, value} in a nested map, paths as key lists.
    defp paths(map, prefix \\ []) do
      Enum.flat_map(map, fn {key, value} ->
        here = [{prefix ++ [key], value}]

        case value do
          %{} = nested -> here ++ paths(nested, prefix ++ [key])
          _ -> here
        end
      end)
    end

    defp put_path(map, [key], value), do: Map.put(map, key, value)

    defp put_path(map, [key | rest], value) do
      case Map.get(map, key) do
        %{} = nested -> Map.put(map, key, put_path(nested, rest, value))
        _ -> map
      end
    end
  end

  describe "event dispatch survives whatever arrives on the socket" do
    test "no frame shape kills the process or reaches a handler with a bad id" do
      parent = self()
      state = %{handler: fn e -> send(parent, e) end, label: "t", attempt: 0, connected_at: nil}

      ids = [nil, "", "   ", 12_345, %{}, [], "b923fa", "79530338915136", %{"id" => "x"}]
      devices = [nil, "scalar", 1, %{"id" => "485519999340"}, %{"online" => true}, []]

      for event <- ["Shelly:StatusOnChange", "Shelly:Online", "Shelly:Unknown"],
          device <- devices,
          id <- ids do
        frame =
          Jason.encode!(%{
            "event" => event,
            "device" => device,
            "deviceId" => id,
            "online" => 1,
            "status" => %{"switch:0" => %{"output" => true}}
          })

        assert {:ok, _state} = Events.handle_frame({:text, frame}, state)
      end

      # Nothing may have been delivered under an unusable id.
      receive_all()
      |> Enum.each(fn
        {:status, id, _} -> assert is_binary(id) and id != ""
        {:online, id, _} -> assert is_binary(id) and id != ""
        _other -> :ok
      end)
    end

    defp receive_all(acc \\ []) do
      receive do
        message -> receive_all([message | acc])
      after
        0 -> acc
      end
    end
  end
end
