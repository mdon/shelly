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

  def request(base_options, source \\ %{}) do
    Req.request(Keyword.merge(base_options, options_from(source)))
  end

  defp options_from(source) do
    Keyword.merge(global_options(), per_call_options(source))
  end

  defp per_call_options(%Shelly.Client{req_options: options}), do: validate(options)
  defp per_call_options(%{req_options: options}), do: validate(options)
  defp per_call_options(_source), do: []

  defp validate(options) when is_list(options), do: options

  defp validate(invalid) do
    Logger.warning(
      "Shelly: :req_options on the client must be a keyword list, got: #{inspect(invalid)}"
    )

    []
  end

  defp global_options do
    case Application.get_env(:shelly, :req_options, []) do
      options when is_list(options) ->
        options

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
