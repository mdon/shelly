defmodule Shelly.AccountTest do
  @moduledoc """
  The account API's response handling had no test at all, which is where
  two protocol bugs lived: keying statuses by a field Shelly documents as
  unreliable, and reading online state from a component that only mains-
  powered Gen2 hardware has.
  """

  use ExUnit.Case, async: false

  setup do
    on_exit(fn -> Application.delete_env(:shelly, :req_options) end)
    :ok
  end

  defp stub(fun), do: Application.put_env(:shelly, :req_options, plug: fun)

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  @account %{server: "https://shelly-74-eu.shelly.cloud", token: "tok"}

  describe "all_statuses/1" do
    test "keys by _dev_info.id, which is the id devices are addressed by" do
      # Shelly documents the outer keys of devices_status as inconsistent
      # ("should be ignored"), notably for virtual/thermostat devices.
      stub(fn conn ->
        json(conn, %{
          "isok" => true,
          "data" => %{
            "devices_status" => %{
              "some-inconsistent-key" => %{
                "_dev_info" => %{"id" => "485519999340", "online" => true},
                "switch:0" => %{"output" => true}
              }
            }
          }
        })
      end)

      assert {:ok, statuses} = Shelly.Account.all_statuses(@account)
      assert Map.has_key?(statuses, "485519999340")
      refute Map.has_key?(statuses, "some-inconsistent-key")
    end

    test "falls back to the outer key when an entry carries no _dev_info" do
      stub(fn conn ->
        json(conn, %{
          "isok" => true,
          "data" => %{"devices_status" => %{"0CDC7EF76644" => %{"switch:0" => %{}}}}
        })
      end)

      assert {:ok, statuses} = Shelly.Account.all_statuses(@account)
      assert Map.has_key?(statuses, "0cdc7ef76644")
    end

    test "an error response is an error, not an empty map" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"isok" => false}))
      end)

      assert {:error, {:shelly_http, 401, _}} = Shelly.Account.all_statuses(@account)
    end
  end

  describe "parse_status/2" do
    test "reads online from _dev_info, which every device has" do
      # A battery or Gen1 device carries no `cloud` component, so reading
      # cloud.connected reported all of them offline.
      battery_device = %{
        "_dev_info" => %{"id" => "b923fa", "online" => true},
        "flood:0" => %{"alarm" => false}
      }

      assert Shelly.Account.parse_status(battery_device, 0).online
    end

    test "an explicit offline in _dev_info is honoured" do
      status = %{"_dev_info" => %{"online" => false}, "switch:0" => %{"output" => true}}
      refute Shelly.Account.parse_status(status, 0).online
    end

    test "falls back to cloud.connected when _dev_info is absent" do
      assert Shelly.Account.parse_status(%{"cloud" => %{"connected" => true}}, 0).online
      refute Shelly.Account.parse_status(%{"cloud" => %{"connected" => false}}, 0).online
    end
  end

  describe "expand_channels/1" do
    test "a string channel count does not crash the listing" do
      devices = %{"485519999340" => %{"name" => "Boiler", "channels_count" => "2"}}

      assert [ch0, ch1] = Shelly.Account.expand_channels(devices)
      assert ch0.channel == 0
      assert ch1.channel == 1
      assert ch0.name == "Boiler · ch0"
    end

    test "a nonsense channel count degrades to one channel" do
      devices = %{"485519999340" => %{"name" => "Boiler", "channels_count" => "many"}}

      assert [only] = Shelly.Account.expand_channels(devices)
      assert only.channel == 0
      assert only.name == "Boiler"
    end
  end
end
