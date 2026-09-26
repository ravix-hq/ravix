defmodule RavixWeb.MachineStatsTest do
  use ExUnit.Case, async: true
  alias Ravix.Vitals.Readings
  alias RavixWeb.MachineStats

  test "bytes cover zero, bytes, KB, MB, GB and TB with rounded human units" do
    for {bytes, expected} <- [
          {0, "0 B"},
          {512, "512 B"},
          {1023, "1023 B"},
          {1024, "1.0 KB"},
          {1536, "1.5 KB"},
          {1_048_576, "1.0 MB"},
          {33_554_432, "32.0 MB"},
          {1_108_246_528, "1.0 GB"},
          {8_589_934_592, "8.0 GB"},
          {1_099_511_627_776, "1.0 TB"}
        ] do
      assert MachineStats.bytes(bytes) == expected
    end
  end

  test "CPU fractions become rounded percentages, including idle and full" do
    assert MachineStats.percent(0) == "0%"
    assert MachineStats.percent(0.15091693548367616) == "15%"
    assert MachineStats.percent(0.999) == "100%"
    assert MachineStats.percent(1) == "100%"
  end

  test "rows combine used and total, retain processor counts and mount, and supply meters" do
    readings =
      readings(
        cpu_cores: 2.0,
        cpu_busy: 0.15,
        mem_used_bytes: 1_073_741_824,
        mem_total_bytes: 8_589_934_592,
        disk_used_bytes: 512,
        disk_total_bytes: 1024,
        disk_mount: "/"
      )

    assert MachineStats.rows(readings) == [
             {"Processors", "2", nil},
             {"CPU in use", "15%", 0.15},
             {"Memory", "1.0 GB of 8.0 GB", 0.125},
             {"Disk", "512 B of 1.0 KB", 0.5},
             {"Disk mount", "/", nil}
           ]
  end

  test "missing measurements are omitted and zero totals never produce a meter" do
    assert MachineStats.rows(readings()) == []

    assert MachineStats.rows(
             readings(cpu_cores: 0.125, cpu_busy: 0, mem_used_bytes: 0, disk_total_bytes: 1024)
           ) == [
             {"Processors", "0.13", nil},
             {"CPU in use", "0%", 0},
             {"Memory used", "0 B", nil},
             {"Disk total", "1.0 KB", nil}
           ]

    assert MachineStats.rows(readings(mem_used_bytes: 0, mem_total_bytes: 0)) ==
             [{"Memory", "0 B of 0 B", nil}]

    assert MachineStats.rows(readings(disk_used_bytes: 2048, disk_total_bytes: 1024)) ==
             [{"Disk", "2.0 KB of 1.0 KB", 1}]
  end

  defp readings(values \\ []) do
    struct!(
      Readings,
      Keyword.merge(
        [
          cpu_cores: nil,
          cpu_busy: nil,
          mem_used_bytes: nil,
          mem_total_bytes: nil,
          disk_used_bytes: nil,
          disk_total_bytes: nil,
          disk_mount: nil
        ],
        values
      )
    )
  end
end
