defmodule Ravix.VitalsTest do
  use Ravix.DataCase, async: true

  import Mimic

  alias Ravix.Vitals
  alias Ravix.Vitals.{Readings, Report}

  # What the probe prints on a cgroup v2 container with a two-core quota.
  @cgroup_v2 Enum.join(
               [
                 "t0=1200.50",
                 "cg0=4000000",
                 "st0=900000 700000",
                 "t1=1200.80",
                 # 300ms elapsed, 300ms of CPU burned: one core of the two, so 50%.
                 "cg1=4300000",
                 "st1=900300 700200",
                 "nproc=8",
                 "cpumax=200000 100000",
                 "memcur=1073741824",
                 "memmax=4294967296",
                 "meminfo=16384000 12288000 ",
                 "df=52428800 10485760 /"
               ],
               "\n"
             )

  describe "parse_vitals/1" do
    test "a cgroup v2 box reports its quota, not the cores it can see" do
      v = Vitals.parse_vitals(@cgroup_v2)
      assert v.cpu_cores == 2
      assert_in_delta v.cpu_busy, 0.5, 1.0e-5
    end

    test "memory is the cgroup's own pair when the cgroup has a limit" do
      # Not `/proc/meminfo`'s 16 GB: the container may have 4, and the number
      # that decides whether the next `bun install` is killed is the container's.
      v = Vitals.parse_vitals(@cgroup_v2)
      assert v.mem_used_bytes == 1024 * 1024 * 1024
      assert v.mem_total_bytes == 4 * 1024 * 1024 * 1024
    end

    test "disk comes back with the mount point it was actually measured on" do
      v = Vitals.parse_vitals(@cgroup_v2)
      assert v.disk_total_bytes == 52_428_800 * 1024
      assert v.disk_used_bytes == 10_485_760 * 1024
      assert v.disk_mount == "/"
    end

    test "no quota falls through to every core the box can see" do
      v =
        Vitals.parse_vitals("nproc=4\ncpumax=max 100000\nt0=10.00\nt1=10.50\ncg0=0\ncg1=1000000")

      assert v.cpu_cores == 4
      # One core-second of CPU in half a second is two cores of four: 50%.
      assert_in_delta v.cpu_busy, 0.5, 1.0e-5
    end

    test "uncapped memory uses /proc/meminfo's pair rather than mixing the two" do
      v = Vitals.parse_vitals("memcur=1073741824\nmemmax=max\nmeminfo=8192000 6144000 ")
      assert v.mem_total_bytes == 8_192_000 * 1024
      assert v.mem_used_bytes == 2_048_000 * 1024
    end

    test "without cgroup cpu accounting it falls back to /proc/stat" do
      # 1000 ticks passed, 250 of them idle.
      v = Vitals.parse_vitals("t0=1.00\nt1=1.30\nst0=10000 8000\nst1=11000 8250\nnproc=2")
      assert_in_delta v.cpu_busy, 0.75, 1.0e-5
    end

    test "a figure that could not be read is absent, never zero" do
      # The kernel has no cgroup files and `df` was refused. Saying 0% CPU and
      # an empty disk here would be a confident lie about a machine that is fine.
      v = Vitals.parse_vitals("nproc=4\ncpumax=\nmemcur=\nmemmax=\nmeminfo=\ndf=")
      assert v.cpu_cores == 4
      assert is_nil(v.cpu_busy)
      assert is_nil(v.mem_total_bytes)
      assert is_nil(v.mem_used_bytes)
      assert is_nil(v.disk_total_bytes)
      assert is_nil(v.disk_mount)
    end

    test "nothing legible at all is nil, not a reading full of holes" do
      assert is_nil(Vitals.parse_vitals(""))
      assert is_nil(Vitals.parse_vitals("sh: 1: nproc: not found\n"))
    end

    test "a counter that went backwards is dropped rather than read as a spike" do
      # The box restarted between samples: `/proc/uptime` and the cgroup
      # counters both reset, and the difference is negative rather than enormous.
      v = Vitals.parse_vitals("nproc=2\nt0=900.00\nt1=1.00\ncg0=5000000\ncg1=10")
      assert is_nil(v.cpu_busy)
    end

    test "a busybox clock that prints something other than a number is not a division" do
      v = Vitals.parse_vitals("nproc=2\nt0=\nt1=\ncg0=0\ncg1=600000")
      assert is_nil(v.cpu_busy)
    end

    test "a CPU reading past its allowance is clamped rather than shown above 100%" do
      # Both samples are rounded to a hundredth of a second, so a genuinely
      # saturated box lands slightly over one every few reads.
      v =
        Vitals.parse_vitals("nproc=1\ncpumax=100000 100000\nt0=1.00\nt1=1.30\ncg0=0\ncg1=310000")

      assert v.cpu_busy == 1
    end
  end

  describe "quota_cores/1" do
    test "cpu.max reads as cores, and 'max' is no quota rather than none" do
      assert Vitals.quota_cores("200000 100000") == 2
      assert Vitals.quota_cores("50000 100000") == 0.5
      assert is_nil(Vitals.quota_cores("max 100000"))
      assert is_nil(Vitals.quota_cores(""))
      assert is_nil(Vitals.quota_cores(nil))
    end
  end

  describe "probe/1" do
    test "the workdir reaches df quoted, so a path cannot become a command" do
      # Slugs are validated long before here, but this string is interpolated
      # into a shell script that runs on the machine and the quoting is the
      # only thing between the two.
      script = Vitals.probe("/home/sprite/work/x'; touch /tmp/pwned; '")
      assert script =~ ~S|df -kP '/home/sprite/work/x'\''; touch /tmp/pwned; '\'''|
      refute script =~ "; touch /tmp/pwned; '\n"
    end

    test "the probe runs on this machine and parses into numbers" do
      # The vectors above are kernels this suite cannot run. This is the
      # opposite check, and the only one that would catch a typo in the awk: a
      # real box has to come back legible and quiet. `df` is the assertion
      # because it is the one figure POSIX guarantees; the rest are Linux.
      {stdout, 0} = System.cmd("sh", ["-lc", Vitals.probe(File.cwd!())], stderr_to_stdout: false)
      v = Vitals.parse_vitals(stdout)
      assert v
      assert v.disk_total_bytes > 0
      assert v.disk_used_bytes > 0
      if match?({:unix, :linux}, :os.type()), do: assert(v.cpu_cores > 0)
    end
  end

  describe "report/2" do
    test "no Sprites token is its own answer, and needs no machine" do
      stub(Ravix.Config, :sprites, fn -> nil end)
      owner = insert_user()
      track = insert_track(project: insert_project(user: owner))

      assert {:ok, %Report{available: false, why: :no_token, readings: nil}} =
               Vitals.report(owner, track.id)
    end

    test "provider reads distinguish missing machines, unsupported hosts, and transport failures" do
      owner = insert_user()
      track = insert_track(project: insert_project(user: owner))
      stub(Ravix.Config, :sprites, fn -> %{token: "test", base_url: "http://sprites.test"} end)
      stub(Ravix.Tracks, :machine_of, fn _ -> {:ok, nil} end)
      assert {:ok, %Report{available: false, why: :no_machine}} = Vitals.report(owner, track.id)
      stub(Ravix.Tracks, :machine_of, fn _ -> {:ok, %{sandbox_id: "box"}} end)
      stub(Ravix.Tracks, :sprite_for, fn "box" -> nil end)
      assert {:ok, %Report{available: false, why: :no_sprite}} = Vitals.report(owner, track.id)
      stub(Ravix.Tracks, :sprite_for, fn "box" -> "sprite" end)
      stub(Ravix.Sprites, :exec, fn _, "sprite", _, _ -> {:error, :unreachable} end)
      assert {:ok, %Report{available: false, why: :unreachable}} = Vitals.report(owner, track.id)

      expect(Ravix.Sprites, :exec, fn _, "sprite", ["sh", "-lc", script], 15 ->
        assert script =~ Ravix.Sprites.shq(track.workdir)
        {:ok, %{stdout: "nproc=2\nmeminfo=1024"}}
      end)

      assert {:ok,
              %Report{
                available: true,
                readings: %Readings{
                  cpu_cores: 2,
                  mem_total_bytes: 1_048_576,
                  mem_used_bytes: nil
                }
              }} = Vitals.report(owner, track.id)
    end

    test "a stranger is told the track does not exist" do
      stub(Ravix.Config, :sprites, fn -> nil end)
      track = insert_track()
      assert {:error, :not_found} = Vitals.report(insert_user(), track.id)
    end
  end
end
