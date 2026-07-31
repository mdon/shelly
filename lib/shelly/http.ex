defmodule Shelly.HTTP do
  @moduledoc false

  require Logger

  # One place where request options are assembled, so every client —
  # not just OAuth — can be pointed somewhere else.
  #
  # Options come from two sources: a `:req_options` key on the account
  # or conn map (per call, wins), and `config :shelly, :req_options`
  # (global fallback, mainly for tests). Without the per-call form a
  # library user cannot route Account/CloudV1/CloudV2 traffic through a
  # proxy, set their own timeouts, or stub them in tests — which is
  # exactly why those three modules had no HTTP-level test coverage.

  # Options the library computes from the request itself. A caller's
  # :req_options must not replace these: overriding :headers dropped the
  # Authorization header (documented as additive), and :url or :method
  # could redirect a control command to another host.
  # :auth is here because Req's auth step calls put_header/3, so it
  # replaces an Authorization header the library has already set — the
  # same failure as overriding :headers, by a different door.
  @reserved [:method, :url, :form, :json, :params, :auth]

  def request(base_options, source \\ %{}) do
    caller = options_from(source)
    {headers, caller} = Keyword.pop(caller, :headers, [])

    {conflicting, caller} = Keyword.split(caller, @reserved)

    if conflicting != [] do
      Logger.warning(
        "Shelly: ignoring :req_options #{inspect(Keyword.keys(conflicting))} — these describe " <>
          "the request itself and are set by the library"
      )
    end

    base_options
    |> Keyword.update(:headers, headers, &(&1 ++ headers))
    |> Keyword.merge(caller)
    |> Req.request()
  end

  defp options_from(source) do
    Keyword.merge(global_options(), per_call_options(source))
  end

  defp per_call_options(%Shelly.Client{req_options: options}), do: validate(options)
  defp per_call_options(%{req_options: options}), do: validate(options)
  defp per_call_options(_source), do: []

  defp validate(options) when is_list(options) do
    if Keyword.keyword?(options) do
      options
    else
      Logger.warning(
        "Shelly: :req_options must be a keyword list, got a list with non-option elements: " <>
          inspect(options)
      )

      []
    end
  end

  defp validate(invalid) do
    Logger.warning(
      "Shelly: :req_options on the client must be a keyword list, got: #{inspect(invalid)}"
    )

    []
  end

  defp global_options do
    case Application.get_env(:shelly, :req_options, []) do
      options when is_list(options) ->
        validate(options)

      invalid ->
        # Silently ignoring this makes a misconfigured proxy or timeout
        # look accepted.
        Logger.warning(
          "Shelly: config :shelly, :req_options must be a keyword list, got: #{inspect(invalid)}"
        )

        []
    end
  end
end
