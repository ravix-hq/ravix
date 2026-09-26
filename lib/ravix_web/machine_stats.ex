defmodule RavixWeb.MachineStats do
  @moduledoc "Display values for the machine dock; missing readings stay absent."
  alias Ravix.Vitals.Readings

  @doc "Byte counts in base-1024 units, with one decimal above bytes."
  def bytes(value) when is_number(value) and value >= 0,
    do: scale(value, ["B", "KB", "MB", "GB", "TB"])

  defp scale(value, [_unit | rest]) when value >= 1024 and rest != [],
    do: scale(value / 1024, rest)

  defp scale(value, ["B" | _]), do: "#{round(value)} B"

  defp scale(value, [unit | _]),
    do: "#{:erlang.float_to_binary(value * 1.0, decimals: 1)} #{unit}"

  @doc "A fraction as a rounded percentage."
  def percent(value), do: "#{round(value * 100)}%"

  @doc "Label, formatted value and optional usage fraction for each visible row."
  def rows(%Readings{} = readings) do
    [
      {"Processors", cores(readings.cpu_cores), nil},
      {"CPU in use", if(readings.cpu_busy, do: percent(readings.cpu_busy)), readings.cpu_busy},
      capacity("Memory", readings.mem_used_bytes, readings.mem_total_bytes),
      capacity("Disk", readings.disk_used_bytes, readings.disk_total_bytes),
      {"Disk mount", readings.disk_mount, nil}
    ]
    |> Enum.reject(fn {_, value, _} -> is_nil(value) end)
  end

  defp cores(nil), do: nil
  defp cores(value) when value == trunc(value), do: to_string(trunc(value))
  defp cores(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  defp capacity(label, nil, nil), do: {label, nil, nil}
  defp capacity(label, used, nil), do: {label <> " used", bytes(used), nil}
  defp capacity(label, nil, total), do: {label <> " total", bytes(total), nil}

  defp capacity(label, used, total) do
    fraction = if total > 0, do: (used / total) |> min(1) |> max(0)
    {label, "#{bytes(used)} of #{bytes(total)}", fraction}
  end
end
